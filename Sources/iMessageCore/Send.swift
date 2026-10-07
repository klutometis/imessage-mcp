import Foundation

/// An existing conversation a send can be addressed to.
public struct ChatRef: Codable, Sendable {
    /// `chat.guid`, e.g. `any;+;1150bd…` (group) or `any;-;+16505551234`
    /// (1:1) on macOS 26. This is the id AppleScript's `chat id` takes.
    public let guid: String
    /// `chat.chat_identifier` — what `list_imessage_chats` reports as
    /// `identifier`.
    public let identifier: String
    public let displayName: String?
    public let isGroup: Bool
    public let participants: [String]
    /// Contacts names, one per participant; nil where unmatched.
    public let participantNames: [String?]

    public init(guid: String, identifier: String, displayName: String?, isGroup: Bool,
                participants: [String], participantNames: [String?]) {
        self.guid = guid
        self.identifier = identifier
        self.displayName = displayName
        self.isGroup = isGroup
        self.participants = participants
        self.participantNames = participantNames
    }
}

/// The chat.db row Messages wrote for an outgoing message, as observed
/// after a send.
public struct OutgoingStatus: Codable, Sendable {
    public let rowid: Int64
    public let chatGUID: String?
    /// `message.is_sent`: Apple's servers accepted it.
    public let isSent: Bool
    /// `message.is_delivered`: a recipient device acknowledged it. Only
    /// ever set for 1:1 iMessage; group messages stay 0 even when they
    /// arrive.
    public let isDelivered: Bool
    /// `message.error`; 0 is success, anything else is "Not Delivered".
    public let error: Int

    public init(rowid: Int64, chatGUID: String?, isSent: Bool, isDelivered: Bool, error: Int) {
        self.rowid = rowid
        self.chatGUID = chatGUID
        self.isSent = isSent
        self.isDelivered = isDelivered
        self.error = error
    }
}

/// What `send_imessage` reports back: where the message went and how far
/// it got, read from chat.db rather than inferred from osascript's exit.
public struct SendReceipt: Codable, Sendable {
    /// `"sent"`, `"delivered"`, `"pending"` (Messages wrote the row but
    /// Apple's servers had not acknowledged it before we stopped watching),
    /// or `"unconfirmed"` (no chat.db to check against).
    public let status: String
    public let recipient: String
    /// `"chat"` (addressed by chat id — every group) or `"participant"`
    /// (a phone/email, addressed as a buddy).
    public let addressedAs: String
    public let chat: ChatRef?
    public let messageRowid: Int64?
    public let note: String?

    public init(status: String, recipient: String, addressedAs: String, chat: ChatRef?,
                messageRowid: Int64?, note: String? = nil) {
        self.status = status
        self.recipient = recipient
        self.addressedAs = addressedAs
        self.chat = chat
        self.messageRowid = messageRowid
        self.note = note
    }
}
