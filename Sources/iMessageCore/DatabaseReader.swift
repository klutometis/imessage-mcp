import Foundation
import GRDB
import Logging

/// Read-only query interface over `~/Library/Messages/chat.db`.
///
/// Forked from `imessage-gemini`'s `DatabaseMonitor` (which is event-stream
/// shaped: it monitors WAL for new rows). This is request-shaped: one-shot
/// SQL queries triggered by MCP tool calls. The event-stream variant lives
/// in imessage-gemini's DatabaseMonitor (kept there for the legacy webhook
/// delivery use case). This reader is for one-shot SQL queries only.
///
/// All methods are safe to call concurrently — uses GRDB's `DatabasePool`
/// (multiple concurrent readers). Opens the database read-only so we never
/// fight Messages.app for the write lock.
public final class DatabaseReader {
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
    /// Used by `iMessageMCP` startup to confirm the DB is accessible
    /// before the server announces ready on stdio.
    public func maxMessageRowID() throws -> Int64 {
        try dbPool.read { db in
            try Int64.fetchOne(db, sql: "SELECT MAX(ROWID) FROM message") ?? 0
        }
    }

    // TODO post-Monday:
    //   - search(text, sender, chat, since, until, hasAttachment, fromMe, limit) -> [Message]
    //   - listChats(limit) -> [Chat]
    //   - getAttachment(messageRowid, index) -> (path, mime, bytes)
    // Each is straightforward GRDB. Scoped out for tonight because send is
    // the only demo-required verb; read/search are great-to-have.
}
