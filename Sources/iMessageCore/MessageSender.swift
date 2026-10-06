import Foundation
import Logging

/// Sends iMessages through Messages.app by executing AppleScript via `/usr/bin/osascript`.
///
/// Supports both text messages and native file attachments (images, audio, video).
/// Files are sent using AppleScript's `send (POSIX file "/path") to theTarget` syntax,
/// which renders them as inline attachments in the conversation — not as links.
///
/// `theTarget` is a `chat id "<guid>"` for groups and a `participant` for a
/// phone/email; see `resolve(_:)`. With a `DatabaseReader`, text sends are
/// confirmed from chat.db (`confirm`), because osascript's exit status says
/// nothing about whether Messages sent anything.
///
/// ## Why `class` and not `actor`?
///
/// The deprecated `iMessageBridge` version used `actor MessageSender`, but that caused
/// unnecessary serialization of sends. AppleScript execution blocks the calling thread
/// via `process.waitUntilExit()`, which is fine in an async context (Swift suspends the
/// task). Using a plain `class` avoids actor-hop overhead. Rate limiting is handled
/// manually via `lastSendTime` — concurrent sends from different tasks would race on this,
/// but in practice we send sequentially (one MCP tool call at a time).
public actor MessageSender {
    /// chat.db, for resolving group chats and confirming sends. Without it
    /// the sender falls back to the old behaviour: participant addressing
    /// only, and "sent" means nothing more than "osascript exited 0".
    private let db: DatabaseReader?

    public init(db: DatabaseReader? = nil) {
        self.db = db
    }

    private let logger = Logger(label: "imessage-mcp.sender")
    
    // Rate limiting: 1 message per second
    private let minInterval: TimeInterval = 1.0
    private var lastSendTime: Date = .distantPast

    /// How long to watch chat.db for the outgoing row before giving up.
    private let confirmTimeout: TimeInterval = 15

    /// How a send is addressed in AppleScript.
    public enum Target: Sendable {
        /// `chat id "<guid>"` — every group, and any recipient given as a guid.
        case chat(ChatRef)
        /// `participant "<handle>"` — a phone/email. The chat, when one
        /// already exists, rides along for confirmation and the receipt.
        case participant(String, ChatRef?)

        var chat: ChatRef? {
            switch self {
            case .chat(let c): return c
            case .participant(_, let c): return c
            }
        }
        var addressedAs: String {
            switch self {
            case .chat: return "chat"
            case .participant: return "participant"
            }
        }
    }

    /// Decide how to address `recipient`: a chat guid, a group's
    /// `identifier` or display name, or a phone/email.
    ///
    /// The old sender addressed everything as a participant. Handed a group
    /// identifier, Messages resolved it to a buddy that does not exist,
    /// `send` did nothing, and osascript still exited 0 — so the tool
    /// reported "Sent" for a message that never left. Anything that is
    /// neither a known chat nor shaped like a phone/email is now refused
    /// before it reaches Messages.
    public func resolve(_ recipient: String) throws -> Target {
        guard let db = db else { return .participant(recipient, nil) }
        let chats = try db.findChats(recipient)
        if let exact = chats.first(where: { $0.guid == recipient }) {
            return .chat(exact)
        }
        let groups = chats.filter { $0.isGroup }
        let distinct = Dictionary(grouping: groups, by: { $0.identifier })
        if distinct.count > 1 {
            let options = distinct.values.compactMap { $0.first }.map {
                "\($0.identifier) (\(Self.describe($0)))"
            }.joined(separator: "; ")
            throw SenderError.ambiguous("\"\(recipient)\" matches \(distinct.count) group chats: \(options). Pass the identifier instead.")
        }
        if let group = groups.first {
            return .chat(group)  // most recently active row for that identifier
        }
        if Self.looksLikeHandle(recipient) {
            return .participant(recipient, chats.first)
        }
        throw SenderError.unknownRecipient(
            "\"\(recipient)\" is not a phone number, an email, or any chat in chat.db " +
            "(by guid, identifier, or group name). Nothing was sent.")
    }

    /// Send an iMessage to a phone/email or an existing chat, and confirm
    /// it from chat.db.
    ///
    /// Throws unless Messages wrote an outgoing row for it and did not mark
    /// that row failed. A row Apple's servers had not yet acknowledged when
    /// we stopped watching comes back as status `pending`, not an error.
    @discardableResult
    public func send(to recipient: String, message: String) async throws -> SendReceipt {
        // Rate limiting
        let now = Date()
        let timeSinceLastSend = now.timeIntervalSince(lastSendTime)
        if timeSinceLastSend < minInterval {
            let waitTime = minInterval - timeSinceLastSend
            logger.debug("⏱️ Rate limiting: waiting \(String(format: "%.2f", waitTime))s")
            try await Task.sleep(for: .seconds(waitTime))
        }

        let target = try resolve(recipient)

        // Ensure Messages.app is running
        try await ensureMessagesIsRunning()

        logger.info("📤 Sending message to \(recipient) as \(target.addressedAs)\(target.chat.map { " \($0.guid)" } ?? "")")

        let before = try db?.maxMessageRowID()
        let script = """
        tell application "Messages"
        \(targetScript(target))
            send "\(escapeForAppleScript(message))" to theTarget
        end tell
        """
        _ = try await executeAppleScript(script)
        lastSendTime = Date()

        guard let db = db, let before = before else {
            logger.info("✅ osascript exited 0 (unconfirmed: no chat.db)")
            return SendReceipt(status: "unconfirmed", recipient: recipient,
                               addressedAs: target.addressedAs, chat: target.chat,
                               messageRowid: nil,
                               note: "osascript exited 0; chat.db unavailable, so nothing confirms the message left.")
        }
        return try await confirm(recipient: recipient, message: message, target: target,
                                 afterRowID: before, db: db)
    }

    /// Resolve `recipient` and, for a chat, have Messages itself look the
    /// chat up — everything a send does except sending.
    public func dryRun(to recipient: String) async throws -> SendReceipt {
        let target = try resolve(recipient)
        var note: String
        switch target {
        case .chat:
            try await ensureMessagesIsRunning()
            let id = try await executeAppleScript("""
            tell application "Messages"
            \(targetScript(target))
                return id of theTarget
            end tell
            """).trimmingCharacters(in: .whitespacesAndNewlines)
            note = "Messages resolved the chat as \(id). Nothing was sent."
        case .participant(_, let chat):
            note = chat == nil
                ? "No existing conversation; Messages would start one with this handle. Nothing was sent."
                : "Would send to this handle's existing conversation. Nothing was sent."
        }
        return SendReceipt(status: "dry_run", recipient: recipient, addressedAs: target.addressedAs,
                           chat: target.chat, messageRowid: nil, note: note)
    }

    /// Watch chat.db for the row Messages writes for this send.
    private func confirm(recipient: String, message: String, target: Target,
                         afterRowID: Int64, db: DatabaseReader) async throws -> SendReceipt {
        let deadline = Date().addingTimeInterval(confirmTimeout)
        var seen: OutgoingStatus? = nil
        while true {
            seen = try db.findOutgoing(afterRowID: afterRowID, text: message, chatGUID: target.chat?.guid)
            if let s = seen, s.isSent || s.error != 0 { break }
            if Date() >= deadline { break }
            try await Task.sleep(for: .milliseconds(250))
        }
        guard let s = seen else {
            logger.error("❌ no outgoing row in chat.db after \(Int(confirmTimeout))s for \(recipient)")
            throw SenderError.notSent(
                "Messages accepted the AppleScript, but no outgoing message appeared in chat.db " +
                "within \(Int(confirmTimeout))s, so nothing was sent to \(recipient).")
        }
        let chat = target.chat ?? s.chatGUID.flatMap { try? db.findChats($0).first }
        if s.error != 0 {
            logger.error("❌ message rowid \(s.rowid) marked failed, error \(s.error)")
            throw SenderError.notDelivered(
                "Messages recorded the message (rowid \(s.rowid)\(chat.map { ", chat \($0.guid)" } ?? "")) " +
                "but marked it Not Delivered (error \(s.error)).")
        }
        let status = s.isDelivered ? "delivered" : (s.isSent ? "sent" : "pending")
        logger.info("✅ \(status): rowid \(s.rowid) in \(s.chatGUID ?? "?")")
        return SendReceipt(
            status: status, recipient: recipient, addressedAs: target.addressedAs,
            chat: chat, messageRowid: s.rowid,
            note: status == "pending"
                ? "Messages wrote the message but Apple's servers had not acknowledged it after \(Int(confirmTimeout))s."
                : (chat?.isGroup == true && status == "sent"
                    ? "Groups never report per-device delivery; sent is as far as chat.db goes."
                    : nil))
    }

    /// AppleScript lines that bind `theTarget` inside `tell application "Messages"`.
    ///
    /// For a chat, `chat id` is tried first; if that id form is not what
    /// this macOS calls the chat, fall back to scanning for a chat whose id
    /// ends in `;<identifier>` (the part every guid format has shared).
    private func targetScript(_ target: Target) -> String {
        switch target {
        case .chat(let c):
            let guid = escapeForAppleScript(c.guid)
            let suffix = escapeForAppleScript(";" + c.identifier)
            return """
                try
                    set theTarget to chat id "\(guid)"
                    get id of theTarget
                on error
                    set theTarget to missing value
                    repeat with aChat in chats
                        if ((id of aChat) as text) ends with "\(suffix)" then
                            set theTarget to contents of aChat
                            exit repeat
                        end if
                    end repeat
                    if theTarget is missing value then error "Messages has no chat \(guid)"
                end try
            """
        case .participant(let handle, _):
            return """
                set targetService to id of 1st account whose service type = iMessage
                set theTarget to participant "\(escapeForAppleScript(handle))" of account id targetService
            """
        }
    }

    static func looksLikeHandle(_ s: String) -> Bool {
        if s.contains("@") { return true }
        let digits = s.filter(\.isNumber)
        let allowed = CharacterSet(charactersIn: "+0123456789 ()-.")
        return digits.count >= 7 && s.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    static func describe(_ c: ChatRef) -> String {
        if let name = c.displayName { return name }
        return c.participants.enumerated().map { i, handle in
            (i < c.participantNames.count ? c.participantNames[i] : nil) ?? handle
        }.joined(separator: ", ")
    }
    
    /// Maximum file size for downloading attachments (25MB)
    private static let maxDownloadSize: Int64 = 25 * 1024 * 1024
    
    /// Send a message with a media attachment (image, audio, video).
    /// Downloads the file from `attachmentURL` to /tmp, sends text first if
    /// provided, then sends the file as a native iMessage attachment.
    /// - Parameters:
    ///   - phoneNumber: Recipient phone number
    ///   - message: Optional text to send before the attachment
    ///   - attachmentURL: URL to download the media file from
    public func sendWithAttachment(to phoneNumber: String, message: String?, attachmentURL: URL) async throws {
        // Rate limiting
        let now = Date()
        let timeSinceLastSend = now.timeIntervalSince(lastSendTime)
        if timeSinceLastSend < minInterval {
            let waitTime = minInterval - timeSinceLastSend
            logger.debug("⏱️ Rate limiting: waiting \(String(format: "%.2f", waitTime))s")
            try await Task.sleep(for: .seconds(waitTime))
        }
        
        try await ensureMessagesIsRunning()
        
        logger.info("📤 Sending attachment to \(phoneNumber)")
        logger.info("   URL: \(attachmentURL.absoluteString)")
        
        // Download file to /tmp
        let tempDir = FileManager.default.temporaryDirectory
        let filename = attachmentURL.lastPathComponent.isEmpty ? "attachment" : attachmentURL.lastPathComponent
        let tempPath = tempDir.appendingPathComponent(filename)
        
        defer {
            // Clean up temp file
            try? FileManager.default.removeItem(at: tempPath)
            logger.debug("🗑️ Cleaned up temp file: \(tempPath.path)")
        }
        
        // Download using our configured session
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        config.timeoutIntervalForResource = 60
        let downloadSession = URLSession(configuration: config)
        
        logger.info("   Downloading attachment...")
        let (downloadedURL, response) = try await downloadSession.download(from: attachmentURL)
        
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw SenderError.appleScriptFailed("Download failed with HTTP \(status)")
        }
        
        // Check file size
        let attrs = try FileManager.default.attributesOfItem(atPath: downloadedURL.path)
        let fileSize = attrs[.size] as? Int64 ?? 0
        if fileSize > Self.maxDownloadSize {
            throw SenderError.appleScriptFailed("Downloaded file too large: \(fileSize) bytes > \(Self.maxDownloadSize)")
        }
        
        // Move from temp download location to our temp path
        if FileManager.default.fileExists(atPath: tempPath.path) {
            try FileManager.default.removeItem(at: tempPath)
        }
        try FileManager.default.moveItem(at: downloadedURL, to: tempPath)
        
        logger.info("   Downloaded \(fileSize) bytes to \(tempPath.path)")
        
        // Send text first if provided
        if let text = message, !text.isEmpty {
            logger.info("   Sending text portion first...")
            try await send(to: phoneNumber, message: text)
            // Small delay between text and attachment
            try await Task.sleep(for: .milliseconds(500))
        }
        
        // Send file as native iMessage attachment via AppleScript.
        // Addressed like text (groups work), but not confirmed from chat.db.
        let filePath = tempPath.path
        let target = try resolve(phoneNumber)
        let script = """
        tell application "Messages"
        \(targetScript(target))
            send (POSIX file "\(escapeForAppleScript(filePath))") to theTarget
        end tell
        """
        
        logger.info("   Sending file attachment...")
        _ = try await executeAppleScript(script)
        
        lastSendTime = Date()
        logger.info("✅ Attachment sent successfully")
    }
    
    /// Send with retry logic
    public func sendWithRetry(to phoneNumber: String, message: String, maxRetries: Int = 3) async throws {
        for attempt in 1...maxRetries {
            do {
                try await send(to: phoneNumber, message: message)
                return
            } catch {
                logger.warning("⚠️ Send attempt \(attempt)/\(maxRetries) failed: \(error)")
                
                if attempt == maxRetries {
                    logger.error("❌ Failed to send message after \(maxRetries) attempts")
                    throw error
                }
                
                // Exponential backoff
                let backoffSeconds = Double(attempt) * 2.0
                try await Task.sleep(for: .seconds(backoffSeconds))
            }
        }
    }
    
    // MARK: - Private Helpers
    
    /// Ensure Messages.app is running
    private func ensureMessagesIsRunning() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-x", "Messages"]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        
        try process.run()
        process.waitUntilExit()
        
        // If Messages is not running (exit code != 0), launch it
        if process.terminationStatus != 0 {
            logger.info("📱 Messages.app not running, launching...")
            
            let openProcess = Process()
            openProcess.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            openProcess.arguments = ["-a", "Messages"]
            
            try openProcess.run()
            openProcess.waitUntilExit()
            
            // Wait a moment for Messages to start
            try await Task.sleep(for: .seconds(2))
            logger.info("✅ Messages.app launched")
        }
    }
    
    /// Execute AppleScript via osascript; returns its stdout.
    @discardableResult
    private func executeAppleScript(_ script: String) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        
        try process.run()
        process.waitUntilExit()
        
        // Check for errors
        if process.terminationStatus != 0 {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            throw SenderError.appleScriptFailed(errorMessage)
        }
        let out = outputPipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: out, encoding: .utf8) ?? ""
    }
    
    /// Escape special characters for AppleScript string literals
    private func escapeForAppleScript(_ string: String) -> String {
        return string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
    }
    
    public enum SenderError: Error, CustomStringConvertible {
        case appleScriptFailed(String)
        /// Neither a handle nor a known chat; refused before Messages saw it.
        case unknownRecipient(String)
        /// A group name that matches more than one chat.
        case ambiguous(String)
        /// osascript succeeded but Messages never wrote an outgoing row.
        case notSent(String)
        /// Messages wrote the row and then marked it failed.
        case notDelivered(String)
        
        public var description: String {
            switch self {
            case .appleScriptFailed(let message):
                return "AppleScript execution failed: \(message)"
            case .unknownRecipient(let m), .ambiguous(let m), .notSent(let m), .notDelivered(let m):
                return m
            }
        }
    }
}
