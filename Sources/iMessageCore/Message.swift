import Foundation

/// A file attachment on an iMessage (voice memo, image, video, sticker, etc.).
///
/// Paths in chat.db are stored with a `~` prefix; `DatabaseReader` expands
/// them at fetch time so callers see absolute paths.
public struct Attachment: Codable, Sendable {
    public let rowid: Int64
    public let filename: String
    public let mimeType: String?
    public let uti: String?
    public let totalBytes: Int64
    public let isSticker: Bool
    /// Optional inline content (base64-encoded). Populated by the MCP layer
    /// for small images so the LLM can see them without an extra fetch.
    /// `DatabaseReader` always leaves this nil; the populating happens in
    /// `iMessageMCP/main.swift` based on policy (mime + size).
    public let contentBase64: String?

    public init(
        rowid: Int64,
        filename: String,
        mimeType: String?,
        uti: String?,
        totalBytes: Int64,
        isSticker: Bool = false,
        contentBase64: String? = nil
    ) {
        self.rowid = rowid
        self.filename = filename
        self.mimeType = mimeType
        self.uti = uti
        self.totalBytes = totalBytes
        self.isSticker = isSticker
        self.contentBase64 = contentBase64
    }
}

/// An iMessage row from chat.db, materialized for MCP consumption.
///
/// Returned by `DatabaseReader.search()` and `.listChats()` (the latter
/// puts the most recent one inline as `Chat.lastMessage`).
public struct Message: Codable, Sendable {
    public let rowid: Int64
    /// `message.handle_id` FK; 0 for outgoing (no handle).
    public let handleID: Int64
    /// For incoming: handle.id (phone/email). For outgoing: "me".
    public let senderPhone: String
    /// Message body. Decoded from `text` column, or `attributedBody`
    /// via `MessageDecoder.decode()` when `text` is null.
    public let text: String?
    public let timestamp: Date
    public let isFromMe: Bool
    public let isRead: Bool
    public let attachments: [Attachment]

    // --- Optional, populated by search/listChats; nil from other code paths ---

    /// Foreign key into the `chat` table. Nil for orphan messages (rare).
    public let chatID: Int64?
    /// Convenience: the chat's display_name or chat_identifier, for inline
    /// display without a join lookup.
    public let chatName: String?
    /// Service the message used: "iMessage", "SMS", "RCS", etc.
    public let service: String?
    /// `message.date_edited`, if the user edited this message after sending.
    public let editedAt: Date?
    /// `message.date_retracted`, if the user "unsent" this message.
    public let retractedAt: Date?

    public init(
        rowid: Int64,
        handleID: Int64,
        senderPhone: String,
        text: String?,
        timestamp: Date,
        isFromMe: Bool,
        isRead: Bool,
        attachments: [Attachment],
        chatID: Int64? = nil,
        chatName: String? = nil,
        service: String? = nil,
        editedAt: Date? = nil,
        retractedAt: Date? = nil
    ) {
        self.rowid = rowid
        self.handleID = handleID
        self.senderPhone = senderPhone
        self.text = text
        self.timestamp = timestamp
        self.isFromMe = isFromMe
        self.isRead = isRead
        self.attachments = attachments
        self.chatID = chatID
        self.chatName = chatName
        self.service = service
        self.editedAt = editedAt
        self.retractedAt = retractedAt
    }

    /// Convenience: the message text content (empty string if null).
    public var content: String { text ?? "" }
    /// Convenience: any attachments at all.
    public var hasAttachments: Bool { !attachments.isEmpty }
}

extension Message: CustomStringConvertible {
    public var description: String {
        var desc = """
        Message(rowid=\(rowid), from=\(senderPhone), date=\(timestamp), text=\(text.map { "\"\($0)\"" } ?? "nil")
        """
        if hasAttachments {
            desc += " attachments=\(attachments.count)"
        }
        if let chatName = chatName {
            desc += " chat=\(chatName)"
        }
        return desc
    }
}
