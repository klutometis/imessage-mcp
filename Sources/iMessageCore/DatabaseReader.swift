import Foundation
import GRDB
import Logging

/// Read-only query interface over `~/Library/Messages/chat.db`.
///
/// Forked from `imessage-gemini`'s `DatabaseMonitor` (which is event-stream
/// shaped: it watches WAL for new rows). This is request-shaped: one-shot
/// SQL queries triggered by MCP tool calls. The event-stream variant lives
/// in imessage-gemini's DatabaseMonitor (kept there for the legacy webhook
/// delivery use case). This reader is for one-shot SQL queries only.
///
/// All methods are safe to call concurrently — uses GRDB's `DatabasePool`
/// (multiple concurrent readers). Opens the database read-only so we never
/// fight Messages.app for the write lock.
public final class DatabaseReader: @unchecked Sendable {
    private let logger = Logger(label: "imessage-mcp.db")
    private let dbPool: DatabasePool

    /// Apple epoch: 2001-01-01 00:00:00 UTC, in seconds since Unix epoch.
    /// chat.db stores `date` columns as nanoseconds since this epoch.
    public static let appleEpoch: TimeInterval = 978307200

    public init(dbPath: String = "~/Library/Messages/chat.db") throws {
        let expandedPath = NSString(string: dbPath).expandingTildeInPath
        var config = Configuration()
        config.readonly = true
        self.dbPool = try DatabasePool(path: expandedPath, configuration: config)
        logger.info("opened chat.db read-only at \(expandedPath)")
    }

    /// Smoke method: returns the highest message ROWID in the database.
    public func maxMessageRowID() throws -> Int64 {
        try dbPool.read { db in
            try Int64.fetchOne(db, sql: "SELECT MAX(ROWID) FROM message") ?? 0
        }
    }

    // MARK: - Conversions

    /// Apple epoch nanoseconds -> Swift `Date`.
    public static func dateFromApple(_ ns: Int64) -> Date {
        Date(timeIntervalSince1970: TimeInterval(ns) / 1_000_000_000 + appleEpoch)
    }

    /// Swift `Date` -> Apple epoch nanoseconds (for query bindings).
    public static func appleFromDate(_ d: Date) -> Int64 {
        Int64((d.timeIntervalSince1970 - appleEpoch) * 1_000_000_000)
    }

    // MARK: - Search

    /// Search messages with structured filters.
    ///
    /// Returns reverse chronological. Each Message includes its chat
    /// (via JOIN), the sender's handle, and any attachments. Text body
    /// falls back to `MessageDecoder.decode(attributedBody)` when the
    /// `text` column is null (modern macOS with rich-text messages).
    ///
    /// Filters are AND'd together. Empty/nil filters are not applied.
    public func search(
        text: String? = nil,
        sender: String? = nil,
        chat: String? = nil,
        since: Date? = nil,
        until: Date? = nil,
        hasAttachment: Bool = false,
        fromMe: Bool? = nil,
        limit: Int = 50
    ) throws -> [Message] {
        var where_: [String] = [
            "m.is_empty = 0",
            "m.item_type = 0",      // regular messages, not group action / system
            "m.associated_message_guid IS NULL",  // exclude tapbacks / reactions
        ]
        var args: [DatabaseValueConvertible?] = []

        if let text = text, !text.isEmpty {
            where_.append("m.text LIKE ?")
            args.append("%\(text)%")
        }
        if let sender = sender, !sender.isEmpty {
            // "me" matches outgoing; otherwise match handle.id (phone/email)
            if sender.lowercased() == "me" {
                where_.append("m.is_from_me = 1")
            } else {
                where_.append("h.id = ?")
                args.append(sender)
            }
        }
        if let chat = chat, !chat.isEmpty {
            // Match either chat.display_name (named groups) or chat_identifier (1:1 phone/email)
            where_.append("(c.display_name = ? OR c.chat_identifier = ?)")
            args.append(chat); args.append(chat)
        }
        if let since = since {
            where_.append("m.date >= ?")
            args.append(Self.appleFromDate(since))
        }
        if let until = until {
            where_.append("m.date <= ?")
            args.append(Self.appleFromDate(until))
        }
        if hasAttachment {
            where_.append("m.cache_has_attachments = 1")
        }
        if let fromMe = fromMe {
            where_.append("m.is_from_me = ?")
            args.append(fromMe ? 1 : 0)
        }

        let sql = """
        SELECT
            m.ROWID         AS rowid,
            m.handle_id     AS handle_id,
            m.text          AS text,
            m.attributedBody AS attributedBody,
            m.date          AS date,
            m.date_edited   AS date_edited,
            m.date_retracted AS date_retracted,
            m.is_from_me    AS is_from_me,
            m.is_read       AS is_read,
            m.service       AS service,
            h.id            AS sender_handle,
            c.ROWID         AS chat_id,
            c.display_name  AS chat_display_name,
            c.chat_identifier AS chat_identifier
        FROM message m
        LEFT JOIN handle h ON m.handle_id = h.ROWID
        LEFT JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
        LEFT JOIN chat c ON c.ROWID = cmj.chat_id
        WHERE \(where_.joined(separator: " AND "))
        ORDER BY m.date DESC
        LIMIT ?
        """
        args.append(limit)

        return try dbPool.read { db in
            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args.map { $0 ?? DatabaseValue.null })!)
            var messages: [Message] = []
            for row in rows {
                messages.append(try self.materialize(row: row, db: db))
            }
            return messages
        }
    }

    // MARK: - List chats

    /// List recent conversations, most-recently-active first.
    ///
    /// For each chat: includes its last message (text + attachments
    /// inline-metadata, per the verb's API contract).
    public func listChats(limit: Int = 20) throws -> [Chat] {
        let sql = """
        SELECT
            c.ROWID                AS rowid,
            c.chat_identifier      AS chat_identifier,
            c.display_name         AS display_name,
            c.style                AS style,
            c.service_name         AS service_name,
            c.last_read_message_timestamp AS last_read_ts,
            (SELECT MAX(cmj2.message_date)
               FROM chat_message_join cmj2
               WHERE cmj2.chat_id = c.ROWID) AS last_message_date
        FROM chat c
        WHERE c.is_archived = 0
          AND (c.is_filtered IS NULL OR c.is_filtered != 1)
        ORDER BY last_message_date DESC
        LIMIT ?
        """

        return try dbPool.read { db in
            let rows = try Row.fetchAll(db, sql: sql, arguments: [limit])
            var chats: [Chat] = []
            for row in rows {
                chats.append(try self.materializeChat(row: row, db: db))
            }
            return chats
        }
    }

    // MARK: - Attachment fetch

    /// Read raw bytes of one attachment of one message.
    ///
    /// Returns the (mimeType, totalBytes, fileURL) so the caller (MCP tool
    /// handler) can decide whether to inline the bytes or just return
    /// metadata. The caller is responsible for ALL size/policy decisions.
    public func attachmentInfo(messageRowid: Int64, index: Int = 0) throws -> (mimeType: String?, totalBytes: Int64, fileURL: URL)? {
        try dbPool.read { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT a.filename, a.mime_type, a.total_bytes
                FROM attachment a
                JOIN message_attachment_join maj ON maj.attachment_id = a.ROWID
                WHERE maj.message_id = ?
                ORDER BY a.ROWID
                LIMIT 1 OFFSET ?
                """, arguments: [messageRowid, index])
            guard let row = row,
                  let filename: String = row["filename"] else { return nil }
            let expanded = NSString(string: filename).expandingTildeInPath
            return (
                mimeType: row["mime_type"],
                totalBytes: row["total_bytes"] ?? 0,
                fileURL: URL(fileURLWithPath: expanded)
            )
        }
    }

    // MARK: - Materialization helpers

    private func materialize(row: Row, db: Database) throws -> Message {
        let rowid: Int64 = row["rowid"]
        let handleID: Int64 = row["handle_id"] ?? 0
        let isFromMe: Bool = (row["is_from_me"] as Int64? ?? 0) != 0
        let isRead: Bool = (row["is_read"] as Int64? ?? 0) != 0

        // Text: fall back to attributedBody decode if text column is null
        var text: String? = row["text"]
        if text == nil, let attributedBody: Data = row["attributedBody"] {
            text = MessageDecoder.decode(attributedBody: attributedBody)
        }

        // Sender display
        let senderPhone: String
        if isFromMe {
            senderPhone = "me"
        } else if let handle: String = row["sender_handle"] {
            senderPhone = handle
        } else {
            senderPhone = "unknown"
        }

        let timestamp = Self.dateFromApple(row["date"] ?? 0)
        let editedAt: Date? = {
            if let ns = row["date_edited"] as Int64?, ns > 0 { return Self.dateFromApple(ns) }
            return nil
        }()
        let retractedAt: Date? = {
            if let ns = row["date_retracted"] as Int64?, ns > 0 { return Self.dateFromApple(ns) }
            return nil
        }()

        // Attachments
        let attachments = try Row.fetchAll(db, sql: """
            SELECT a.ROWID, a.filename, a.mime_type, a.uti, a.total_bytes, a.is_sticker
            FROM attachment a
            JOIN message_attachment_join maj ON maj.attachment_id = a.ROWID
            WHERE maj.message_id = ?
            ORDER BY a.ROWID
            """, arguments: [rowid]).map { ar -> Attachment in
                let rawFilename: String = ar["filename"] ?? ""
                let expanded = NSString(string: rawFilename).expandingTildeInPath
                return Attachment(
                    rowid: ar["ROWID"] ?? 0,
                    filename: expanded,
                    mimeType: ar["mime_type"],
                    uti: ar["uti"],
                    totalBytes: ar["total_bytes"] ?? 0,
                    isSticker: (ar["is_sticker"] as Int64? ?? 0) != 0,
                    contentBase64: nil
                )
            }

        // Chat info
        let chatID: Int64? = row["chat_id"]
        let chatName: String? = {
            if let s: String = row["chat_display_name"], !s.isEmpty { return s }
            if let s: String = row["chat_identifier"], !s.isEmpty { return s }
            return nil
        }()
        let service: String? = row["service"]

        return Message(
            rowid: rowid,
            handleID: handleID,
            senderPhone: senderPhone,
            text: text,
            timestamp: timestamp,
            isFromMe: isFromMe,
            isRead: isRead,
            attachments: attachments,
            chatID: chatID,
            chatName: chatName,
            service: service,
            editedAt: editedAt,
            retractedAt: retractedAt
        )
    }

    private func materializeChat(row: Row, db: Database) throws -> Chat {
        let rowid: Int64 = row["rowid"]
        let identifier: String = row["chat_identifier"] ?? ""
        let displayName: String? = {
            let s: String? = row["display_name"]
            return (s?.isEmpty == false) ? s : nil
        }()
        let styleCode: Int64 = row["style"] ?? 0
        let style = (styleCode == 43) ? "group" : "1:1"
        let service: String? = row["service_name"]

        // Participants
        let participants = try String.fetchAll(db, sql: """
            SELECT h.id
            FROM chat_handle_join chj
            JOIN handle h ON h.ROWID = chj.handle_id
            WHERE chj.chat_id = ?
            ORDER BY h.id
            """, arguments: [rowid])

        // Unread count
        let unread = try Int.fetchOne(db, sql: """
            SELECT COUNT(*)
            FROM message m
            JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
            WHERE cmj.chat_id = ? AND m.is_read = 0 AND m.is_from_me = 0
              AND m.is_empty = 0 AND m.item_type = 0
            """, arguments: [rowid]) ?? 0

        let lastReadAt: Date? = {
            if let ns = row["last_read_ts"] as Int64?, ns > 0 { return Self.dateFromApple(ns) }
            return nil
        }()

        // Last message (most recent in this chat)
        let lastMsgRow = try Row.fetchOne(db, sql: """
            SELECT
                m.ROWID         AS rowid,
                m.handle_id     AS handle_id,
                m.text          AS text,
                m.attributedBody AS attributedBody,
                m.date          AS date,
                m.date_edited   AS date_edited,
                m.date_retracted AS date_retracted,
                m.is_from_me    AS is_from_me,
                m.is_read       AS is_read,
                m.service       AS service,
                h.id            AS sender_handle,
                ? AS chat_id,
                ? AS chat_display_name,
                ? AS chat_identifier
            FROM message m
            LEFT JOIN handle h ON m.handle_id = h.ROWID
            JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
            WHERE cmj.chat_id = ?
              AND m.is_empty = 0
              AND m.item_type = 0
              AND m.associated_message_guid IS NULL   -- exclude tapbacks/reactions
            ORDER BY m.date DESC
            LIMIT 1
            """, arguments: [rowid, displayName, identifier, rowid])
        let lastMessage = try lastMsgRow.map { try self.materialize(row: $0, db: db) }

        return Chat(
            rowid: rowid,
            identifier: identifier,
            displayName: displayName,
            style: style,
            service: service,
            participants: participants,
            lastMessage: lastMessage,
            unreadCount: unread,
            lastReadAt: lastReadAt
        )
    }
}
