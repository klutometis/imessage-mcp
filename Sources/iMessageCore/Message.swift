import Foundation

/// A file attachment on an iMessage (voice memo, image, video, etc.).
///
/// Paths are stored in the Messages database with a `~` prefix
/// (e.g. `~/Library/Messages/Attachments/XX/XX/GUID/filename.ext`).
/// The `filename` field here is the **expanded** absolute path — tilde
/// expansion is performed in `DatabaseMonitor.fetchAttachments()`.
public struct Attachment: Codable, Sendable {
    public init(filename: String, mimeType: String?, uti: String?, totalBytes: Int64) {
        self.filename = filename
        self.mimeType = mimeType
        self.uti = uti
        self.totalBytes = totalBytes
    }

    /// Absolute filesystem path (tilde-expanded) to the attachment file.
    public let filename: String
    /// MIME type from the `attachment` table, e.g. `"audio/x-caf"`, `"image/jpeg"`.
    public let mimeType: String?
    /// Uniform Type Identifier, e.g. `"com.apple.coreaudio-format"`.
    public let uti: String?
    /// File size in bytes. May be 0 if the database row hasn't been fully populated yet.
    public let totalBytes: Int64
}

/// An iMessage read from `chat.db`.
///
/// Produced by `DatabaseReader` SQL queries; consumed by `iMessageMCP` tool handlers.
public struct Message: Codable, Sendable {
    public init(rowid: Int64, handleID: Int64, senderPhone: String, text: String?, timestamp: Date, isFromMe: Bool, attachments: [Attachment], cacheHasAttachments: Bool) {
        self.rowid = rowid
        self.handleID = handleID
        self.senderPhone = senderPhone
        self.text = text
        self.timestamp = timestamp
        self.isFromMe = isFromMe
        self.attachments = attachments
        self.cacheHasAttachments = cacheHasAttachments
    }

    public let rowid: Int64

    /// Foreign key into the `handle` table. Used for deferred phone number resolution:
    /// iMessage may commit the message row before the handle row in a separate transaction,
    /// leaving `senderPhone` as `"unknown"`. `DatabaseMonitor` uses this ID to re-query
    /// in a fresh read transaction.
    public let handleID: Int64

    public let senderPhone: String
    public let text: String?
    public let timestamp: Date
    public let isFromMe: Bool
    public let attachments: [Attachment]

    /// Raw `cache_has_attachments` flag from the database. **Unreliable** for detecting
    /// whether a message actually has attachments — iMessage sets this to `0` initially
    /// and updates it in a later transaction. Callers reading message rows
    /// shouldn't trust this flag; check `attachments.isEmpty` instead.
    public let cacheHasAttachments: Bool
    
    /// The message text content
    public var content: String {
        text ?? ""
    }
    
    /// Whether this message has file attachments
    public var hasAttachments: Bool {
        !attachments.isEmpty
    }
}

extension Message: CustomStringConvertible {
    public var description: String {
        var desc = """
        Message Detected:
           Row ID: \(rowid)
           From: \(senderPhone)
           Content: "\(content)"
           Timestamp: \(timestamp)
           Is From Me: \(isFromMe)
        """
        if hasAttachments {
            desc += "\n   Attachments: \(attachments.count)"
            for (i, att) in attachments.enumerated() {
                desc += "\n     [\(i)] \(att.filename) (\(att.mimeType ?? "unknown") \(att.totalBytes) bytes)"
            }
        }
        return desc
    }
}
