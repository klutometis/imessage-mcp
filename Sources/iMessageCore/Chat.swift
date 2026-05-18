import Foundation

/// A conversation thread from chat.db's `chat` table.
///
/// One row per 1:1 conversation or named group. The `participants` field
/// is materialized via `chat_handle_join` -> `handle.id` (phone or email).
public struct Chat: Codable, Sendable {
    public let rowid: Int64
    /// `chat_identifier` column. For 1:1, the participant's phone/email.
    /// For groups, an iMessage-generated GUID.
    public let identifier: String
    /// `display_name`. Null for unnamed chats — caller can synthesize from
    /// participants or just show the identifier.
    public let displayName: String?
    /// `"1:1"` or `"group"`. Derived from `chat.style` (45 / 43).
    public let style: String
    /// `service_name` column: `"iMessage"`, `"SMS"`, `"RCS"`, etc.
    public let service: String?
    public let participants: [String]
    /// Display names resolved from macOS Contacts, one per participant
    /// (same order as `participants`). Entries are nil for unmatched
    /// handles. Empty array when no resolver was passed in.
    public let participantNames: [String?]
    /// Most recent message in the chat. Nil for empty chats (rare).
    public let lastMessage: Message?
    /// Count of `is_read=0 AND is_from_me=0` messages in this chat.
    public let unreadCount: Int
    /// `last_read_message_timestamp`, converted from Apple epoch to Date.
    /// Nil if the chat has never been read.
    public let lastReadAt: Date?

    public init(
        rowid: Int64,
        identifier: String,
        displayName: String?,
        style: String,
        service: String?,
        participants: [String],
        participantNames: [String?] = [],
        lastMessage: Message?,
        unreadCount: Int,
        lastReadAt: Date?
    ) {
        self.rowid = rowid
        self.identifier = identifier
        self.displayName = displayName
        self.style = style
        self.service = service
        self.participants = participants
        self.participantNames = participantNames
        self.lastMessage = lastMessage
        self.unreadCount = unreadCount
        self.lastReadAt = lastReadAt
    }
}
