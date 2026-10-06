// imessage-mcp: stdio MCP server for iMessage on macOS.
//
// Tools:
//   send_imessage(recipient, message)            — send via Messages.app
//   search_imessages(text, sender, chat, since, until, has_attachment, from_me, limit)
//                                                — read messages (full text inline,
//                                                  small image attachments base64-inlined)
//   list_imessage_chats(limit)                   — recent conversations w/ last message
//   get_imessage_attachment(message_rowid, attachment_index, max_inline_bytes)
//                                                — fetch attachment bytes
//
// Transport: stdio. Designed to be wrapped by ~/prg/wss-bridge for remote use
// via the gateway's wss-inbound transport.

import Foundation
import Logging
import MCP
import iMessageCore

// Log to stderr (stdout is reserved for JSON-RPC frames).
LoggingSystem.bootstrap { label in
    var handler = StreamLogHandler.standardError(label: label)
    handler.logLevel = .info
    return handler
}
let log = Logger(label: "imessage-mcp.main")

// Contacts resolver runs on the same FDA grant as chat.db; it lazy-loads on
// first lookup. Pass into DatabaseReader so search/listChats populate
// senderName / participantNames.
let contacts = ContactsResolver()
let reader: DatabaseReader
do {
    reader = try DatabaseReader(contacts: contacts)
    let max = try reader.maxMessageRowID()
    log.info("chat.db opened; max message rowid = \(max)")
} catch {
    log.error("failed to open chat.db: \(error)")
    exit(1)
}
// The sender reads chat.db to resolve group chats and to confirm each send
// actually produced an outgoing message.
let sender = MessageSender(db: reader)

// ───────────────────────────── helpers ─────────────────────────────

/// Parse a string into a Date. Accepts ISO8601 with or without time:
///   "2025-05-17"  -> midnight local time on that date
///   "2025-05-17T14:32:00"  -> exact moment, local
///   "2025-05-17T14:32:00Z" -> exact UTC
func parseDate(_ s: String) -> Date? {
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = iso.date(from: s) { return d }
    iso.formatOptions = [.withInternetDateTime]
    if let d = iso.date(from: s) { return d }
    let dateOnly = DateFormatter()
    dateOnly.dateFormat = "yyyy-MM-dd"
    if let d = dateOnly.date(from: s) { return d }
    return nil
}

/// Attachment-inlining policy. Per plans/mcp-over-wss.md §"attachment policy":
/// images under 1MB get base64'd inline; others get metadata only.
let inlineImageByteCap: Int64 = 1_000_000

func inlineAttachmentsIfSmall(_ atts: [Attachment]) -> [Attachment] {
    atts.map { att in
        guard let mime = att.mimeType,
              mime.hasPrefix("image/"),
              att.totalBytes > 0,
              att.totalBytes < inlineImageByteCap,
              let data = try? Data(contentsOf: URL(fileURLWithPath: att.filename))
        else { return att }
        return Attachment(
            rowid: att.rowid,
            filename: att.filename,
            mimeType: att.mimeType,
            uti: att.uti,
            totalBytes: att.totalBytes,
            isSticker: att.isSticker,
            contentBase64: data.base64EncodedString()
        )
    }
}

func messageWithInlinedAttachments(_ m: iMessageCore.Message) -> iMessageCore.Message {
    Message(
        rowid: m.rowid, handleID: m.handleID, senderPhone: m.senderPhone,
        senderName: m.senderName,
        text: m.text, timestamp: m.timestamp, isFromMe: m.isFromMe, isRead: m.isRead,
        attachments: inlineAttachmentsIfSmall(m.attachments),
        chatID: m.chatID, chatName: m.chatName, service: m.service,
        editedAt: m.editedAt, retractedAt: m.retractedAt
    )
}

/// Encode any Codable as a JSON string for MCP text content.
let jsonEncoder: JSONEncoder = {
    let enc = JSONEncoder()
    enc.dateEncodingStrategy = .iso8601
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    return enc
}()

func toJSONText<T: Encodable>(_ value: T) -> String {
    (try? String(data: jsonEncoder.encode(value), encoding: .utf8)) ?? "null"
}

// ───────────────────────────── server ─────────────────────────────

let server = Server(
    name: "imessage-mcp",
    version: "0.2.0",
    capabilities: .init(tools: .init(listChanged: false))
)

// tools/list — all four verbs
await server.withMethodHandler(ListTools.self) { _ in
    .init(tools: [
        Tool(
            name: "send_imessage",
            description:
                "Send an iMessage from Peter's Mac via Messages.app, to a person or a group chat. " +
                "`recipient` is a phone (e.g. +16505551234), an iCloud email, or an existing chat: " +
                "a group's `identifier` from list_imessage_chats, its chat guid, or its display name. " +
                "Each send is confirmed from chat.db: the result is JSON with `status` " +
                "(`sent`, `delivered`, or `pending`) and the chat it landed in, including its " +
                "participants. It is an error, not a success, if Messages wrote no outgoing message " +
                "or marked it Not Delivered. `dry_run: true` resolves the recipient without sending.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "recipient": .object([
                        "type": .string("string"),
                        "description": .string("Phone (+16505551234), iCloud email, or a group chat's identifier / guid / display name.")
                    ]),
                    "message": .object([
                        "type": .string("string"),
                        "description": .string("Message body to send.")
                    ]),
                    "dry_run": .object([
                        "type": .string("boolean"),
                        "description": .string("If true, report where the message would go (chat and participants) without sending it.")
                    ])
                ]),
                "required": .array([.string("recipient"), .string("message")])
            ])
        ),

        Tool(
            name: "search_imessages",
            description:
                "Search Peter's iMessage history by text, sender, chat, date range, etc. " +
                "Returns messages reverse chronologically. Each message has full text + " +
                "attachment metadata; small images (<1MB) are base64-inlined as " +
                "`attachments[].contentBase64` so you can see them without a follow-up call.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "text":           .object(["type": .string("string"), "description": .string("Substring to match in message body (case-insensitive).")]),
                    "sender":         .object(["type": .string("string"), "description": .string("Phone/email of sender; pass 'me' for messages Peter sent.")]),
                    "chat":           .object(["type": .string("string"), "description": .string("Chat display name (groups) or chat_identifier (1:1 phone/email).")]),
                    "since":          .object(["type": .string("string"), "description": .string("ISO8601 date or datetime; only messages on/after this moment.")]),
                    "until":          .object(["type": .string("string"), "description": .string("ISO8601 date or datetime; only messages on/before this moment.")]),
                    "has_attachment": .object(["type": .string("boolean"), "description": .string("If true, only messages with attachments.")]),
                    "from_me":        .object(["type": .string("boolean"), "description": .string("If true, only messages Peter sent; if false, only ones he received; omit for both.")]),
                    "limit":          .object(["type": .string("integer"), "description": .string("Max results (default 50).")])
                ])
            ])
        ),

        Tool(
            name: "list_imessage_chats",
            description:
                "List Peter's recent iMessage conversations, most-recently-active first. " +
                "Each chat includes its last message (text + small images inline), " +
                "participants, unread count, and last-read timestamp.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "limit": .object(["type": .string("integer"), "description": .string("Max chats to return (default 20).")])
                ])
            ])
        ),

        Tool(
            name: "get_imessage_attachment",
            description:
                "Fetch a specific iMessage attachment by message rowid (and attachment index, " +
                "default 0). Returns metadata plus inline base64 content if the file is under " +
                "`max_inline_bytes` (default 5MB). Use this for attachments too big for the " +
                "automatic inlining in search/list (which caps at 1MB and images only).",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "message_rowid":    .object(["type": .string("integer"), "description": .string("`rowid` of the message owning the attachment.")]),
                    "attachment_index": .object(["type": .string("integer"), "description": .string("0-based index when a message has multiple attachments (default 0).")]),
                    "max_inline_bytes": .object(["type": .string("integer"), "description": .string("Skip inline content if file exceeds this. Default 5_000_000.")])
                ]),
                "required": .array([.string("message_rowid")])
            ])
        )
    ])
}

// tools/call dispatcher
await server.withMethodHandler(CallTool.self) { params in
    switch params.name {

    case "send_imessage":
        guard let recipient = params.arguments?["recipient"]?.stringValue,
              let message = params.arguments?["message"]?.stringValue,
              !recipient.isEmpty, !message.isEmpty else {
            return .init(content: [.text("send_imessage requires non-empty `recipient` and `message`.")], isError: true)
        }
        let dryRun = params.arguments?["dry_run"]?.boolValue ?? false
        do {
            if dryRun {
                let receipt = try await sender.dryRun(to: recipient)
                return .init(content: [.text(toJSONText(receipt))], isError: false)
            }
            let receipt = try await sender.send(to: recipient, message: message)
            log.info("\(receipt.status) iMessage to \(recipient) (\(message.count) chars), rowid \(receipt.messageRowid.map(String.init) ?? "-")")
            return .init(content: [.text(toJSONText(receipt))], isError: false)
        } catch {
            log.error("send failed: \(error)")
            return .init(content: [.text("Failed to send: \(error)")], isError: true)
        }

    case "search_imessages":
        let a = params.arguments ?? [:]
        let text   = a["text"]?.stringValue
        let sender = a["sender"]?.stringValue
        let chat   = a["chat"]?.stringValue
        let since  = a["since"]?.stringValue.flatMap(parseDate)
        let until  = a["until"]?.stringValue.flatMap(parseDate)
        let hasAtt = a["has_attachment"]?.boolValue ?? false
        let fromMe = a["from_me"]?.boolValue
        let limit  = Int(a["limit"]?.intValue ?? 50)
        do {
            let raw = try reader.search(
                text: text, sender: sender, chat: chat,
                since: since, until: until,
                hasAttachment: hasAtt, fromMe: fromMe,
                limit: limit
            )
            let inlined = raw.map { messageWithInlinedAttachments($0) }
            return .init(content: [.text(toJSONText(inlined))], isError: false)
        } catch {
            log.error("search failed: \(error)")
            return .init(content: [.text("search_imessages failed: \(error)")], isError: true)
        }

    case "list_imessage_chats":
        let limit = Int(params.arguments?["limit"]?.intValue ?? 20)
        do {
            let raw = try reader.listChats(limit: limit)
            let inlined = raw.map { chat -> iMessageCore.Chat in
                guard let last = chat.lastMessage else { return chat }
                return Chat(
                    rowid: chat.rowid, identifier: chat.identifier,
                    displayName: chat.displayName, style: chat.style, service: chat.service,
                    participants: chat.participants,
                    lastMessage: messageWithInlinedAttachments(last),
                    unreadCount: chat.unreadCount, lastReadAt: chat.lastReadAt
                )
            }
            return .init(content: [.text(toJSONText(inlined))], isError: false)
        } catch {
            log.error("listChats failed: \(error)")
            return .init(content: [.text("list_imessage_chats failed: \(error)")], isError: true)
        }

    case "get_imessage_attachment":
        guard let rowid = params.arguments?["message_rowid"]?.intValue else {
            return .init(content: [.text("get_imessage_attachment requires `message_rowid` (integer).")], isError: true)
        }
        let index = Int(params.arguments?["attachment_index"]?.intValue ?? 0)
        let cap = Int64(params.arguments?["max_inline_bytes"]?.intValue ?? 5_000_000)
        do {
            guard let info = try reader.attachmentInfo(messageRowid: Int64(rowid), index: index) else {
                return .init(content: [.text("No attachment at message rowid \(rowid) index \(index).")], isError: true)
            }
            var resp: [String: Any] = [
                "filename": info.fileURL.path,
                "mime_type": info.mimeType ?? "application/octet-stream",
                "total_bytes": info.totalBytes,
            ]
            if info.totalBytes > 0 && info.totalBytes <= cap,
               let data = try? Data(contentsOf: info.fileURL) {
                resp["content_base64"] = data.base64EncodedString()
            } else {
                resp["content_base64"] = NSNull()
                resp["note"] = "file too large for inline (>\(cap) bytes); read from filename path"
            }
            let json = try JSONSerialization.data(withJSONObject: resp, options: [.prettyPrinted, .sortedKeys])
            return .init(content: [.text(String(data: json, encoding: .utf8) ?? "{}")], isError: false)
        } catch {
            log.error("attachment failed: \(error)")
            return .init(content: [.text("get_imessage_attachment failed: \(error)")], isError: true)
        }

    default:
        return .init(content: [.text("Unknown tool: '\(params.name)'")], isError: true)
    }
}

log.info("starting stdio MCP server")
let transport = StdioTransport(logger: log)
try await server.start(transport: transport)
await server.waitUntilCompleted()
