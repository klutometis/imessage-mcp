// imessage-mcp: stdio MCP server for iMessage on macOS.
//
// Tools (Monday-demo scope):
//   send_imessage(recipient, message) — uses MessageSender (modern AppleScript)
//
// Tools planned for post-Monday (TODO in DatabaseReader):
//   search_imessages, list_imessage_chats, get_imessage_attachment
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

// Sender (actor — thread-safe), Reader (smoke; full query API post-Monday).
let sender = MessageSender()
let reader: DatabaseReader
do {
    reader = try DatabaseReader()
    let max = try reader.maxMessageRowID()
    log.info("chat.db opened; max message rowid = \(max)")
} catch {
    log.error("failed to open chat.db: \(error)")
    exit(1)
}

let server = Server(
    name: "imessage-mcp",
    version: "0.1.0",
    capabilities: .init(tools: .init(listChanged: false))
)

// tools/list
await server.withMethodHandler(ListTools.self) { _ in
    .init(tools: [
        Tool(
            name: "send_imessage",
            description:
                "Send an iMessage from Peter's Mac via Messages.app. " +
                "`recipient` is a phone number (e.g. '+16505551234') or iCloud email. " +
                "`message` is the body text.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "recipient": .object([
                        "type": .string("string"),
                        "description": .string("Phone (e.g. +16505551234) or iCloud email of the recipient.")
                    ]),
                    "message": .object([
                        "type": .string("string"),
                        "description": .string("Message body to send.")
                    ])
                ]),
                "required": .array([.string("recipient"), .string("message")])
            ])
        )
    ])
}

// tools/call
await server.withMethodHandler(CallTool.self) { params in
    switch params.name {
    case "send_imessage":
        guard let recipient = params.arguments?["recipient"]?.stringValue,
              let message = params.arguments?["message"]?.stringValue,
              !recipient.isEmpty, !message.isEmpty else {
            return .init(
                content: [.text("send_imessage requires non-empty `recipient` and `message`.")],
                isError: true
            )
        }
        do {
            try await sender.send(to: recipient, message: message)
            log.info("sent iMessage to \(recipient) (\(message.count) chars)")
            return .init(content: [.text("Sent iMessage to \(recipient).")], isError: false)
        } catch {
            log.error("send failed: \(error)")
            return .init(content: [.text("Failed to send: \(error)")], isError: true)
        }
    default:
        return .init(content: [.text("Unknown tool: '\(params.name)'")], isError: true)
    }
}

// Stdio transport — speaks JSON-RPC on stdin/stdout.
log.info("starting stdio MCP server")
let transport = StdioTransport(logger: log)
try await server.start(transport: transport)
await server.waitUntilCompleted()
