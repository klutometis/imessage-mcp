import Foundation
import Logging

/// Sends iMessages through Messages.app by executing AppleScript via `/usr/bin/osascript`.
///
/// Supports both text messages and native file attachments (images, audio, video).
/// Files are sent using AppleScript's `send (POSIX file "/path") to theBuddy` syntax,
/// which renders them as inline attachments in the conversation — not as links.
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
    public init() {}

    private let logger = Logger(label: "imessage-mcp.sender")
    
    // Rate limiting: 1 message per second
    private let minInterval: TimeInterval = 1.0
    private var lastSendTime: Date = .distantPast
    
    /// Send an iMessage to a phone number
    public func send(to phoneNumber: String, message: String) async throws {
        // Rate limiting
        let now = Date()
        let timeSinceLastSend = now.timeIntervalSince(lastSendTime)
        if timeSinceLastSend < minInterval {
            let waitTime = minInterval - timeSinceLastSend
            logger.debug("⏱️ Rate limiting: waiting \(String(format: "%.2f", waitTime))s")
            try await Task.sleep(for: .seconds(waitTime))
        }
        
        // Ensure Messages.app is running
        try await ensureMessagesIsRunning()
        
        logger.info("📤 Sending message to \(phoneNumber)")
        
        // Escape special characters in message for AppleScript
        let escapedMessage = escapeForAppleScript(message)
        
        // Build AppleScript - use participant approach for modern macOS
        let script = """
        tell application "Messages"
            set targetService to id of 1st account whose service type = iMessage
            set theBuddy to participant "\(phoneNumber)" of account id targetService
            send "\(escapedMessage)" to theBuddy
        end tell
        """
        
        // Execute AppleScript
        try await executeAppleScript(script)
        
        lastSendTime = Date()
        logger.info("✅ Message sent successfully")
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
        
        // Send file as native iMessage attachment via AppleScript
        let filePath = tempPath.path
        let script = """
        tell application "Messages"
            set targetService to id of 1st account whose service type = iMessage
            set theBuddy to participant "\(phoneNumber)" of account id targetService
            send (POSIX file "\(filePath)") to theBuddy
        end tell
        """
        
        logger.info("   Sending file attachment...")
        try await executeAppleScript(script)
        
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
    
    /// Execute AppleScript via osascript
    private func executeAppleScript(_ script: String) async throws {
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
        
        public var description: String {
            switch self {
            case .appleScriptFailed(let message):
                return "AppleScript execution failed: \(message)"
            }
        }
    }
}
