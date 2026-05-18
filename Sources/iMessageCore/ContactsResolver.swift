import Foundation
import GRDB

/// Resolves chat.db handles (phone numbers / iCloud emails) to display
/// names by reading macOS's AddressBook sqlite stores.
///
/// macOS keeps one sqlite per account source under
///   ~/Library/Application Support/AddressBook/Sources/<UUID>/
///         AddressBook-v22.abcddb
/// We scan all of them, aggregate into in-memory dicts, and serve
/// lookups offline. Reload via `refresh()`.
///
/// Reuses the existing Full Disk Access grant — no extra TCC prompt.
///
/// Thread-safe via an internal lock. Load-on-first-use, then
/// read-only. Call `refresh()` to re-scan after contact changes.
public final class ContactsResolver: @unchecked Sendable {
    /// Last-10-digits-of-phone -> "First Last" (US numbers).
    private var phoneIndex: [String: String] = [:]
    /// Lowercased email -> "First Last".
    private var emailIndex: [String: String] = [:]
    /// Set once `loadSync()` completes; false while still loading or on error.
    private var loaded = false
    private let lock = NSLock()

    private let sourcesRoot: URL

    public init(
        sourcesRoot: URL = URL(fileURLWithPath:
            NSString(string: "~/Library/Application Support/AddressBook/Sources")
                .expandingTildeInPath)
    ) {
        self.sourcesRoot = sourcesRoot
    }

    /// Look up a display name for a chat.db handle. Returns nil if no
    /// match. Loads the AddressBook on first call (best-effort).
    public func resolve(handle: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        if !loaded {
            try? loadSyncLocked()
        }
        if handle.contains("@") {
            return emailIndex[handle.lowercased()]
        }
        let digits = Self.lastTenDigits(handle)
        return digits.map { phoneIndex[$0] } ?? nil
    }

    /// Force a re-scan of the AddressBook stores.
    public func refresh() throws {
        lock.lock()
        defer { lock.unlock() }
        try loadSyncLocked()
    }
}

// MARK: - Loading
extension ContactsResolver {
    /// Walk every source under `sourcesRoot` and merge contacts.
    /// Caller must hold `lock`.
    fileprivate func loadSyncLocked() throws {
        var phones: [String: String] = [:]
        var emails: [String: String] = [:]

        let fm = FileManager.default
        let sources = (try? fm.contentsOfDirectory(at: sourcesRoot,
            includingPropertiesForKeys: nil)) ?? []
        for sourceDir in sources {
            let db = sourceDir.appendingPathComponent("AddressBook-v22.abcddb")
            guard fm.fileExists(atPath: db.path) else { continue }
            try loadOne(dbPath: db.path, into: &phones, intoEmails: &emails)
        }

        self.phoneIndex = phones
        self.emailIndex = emails
        self.loaded = true
    }

    private func loadOne(
        dbPath: String,
        into phones: inout [String: String],
        intoEmails emails: inout [String: String]
    ) throws {
        // Read-only; copy-then-open in case AB has an active writer.
        var cfg = Configuration()
        cfg.readonly = true
        let queue = try DatabaseQueue(path: dbPath, configuration: cfg)
        try queue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT r.Z_PK         AS pk,
                       r.ZFIRSTNAME   AS first,
                       r.ZLASTNAME    AS last,
                       r.ZNICKNAME    AS nick,
                       r.ZORGANIZATION AS org
                FROM ZABCDRECORD r
            """)
            for r in rows {
                let pk: Int64 = r["pk"] ?? 0
                let first: String? = r["first"]
                let last: String? = r["last"]
                let nick: String? = r["nick"]
                let org: String? = r["org"]
                let name = Self.formatName(
                    first: first, last: last, nick: nick, org: org)
                guard let name else { continue }

                // Phones
                let pRows = try Row.fetchAll(db, sql: """
                    SELECT ZFULLNUMBER AS num FROM ZABCDPHONENUMBER
                    WHERE ZOWNER = ?
                """, arguments: [pk])
                for pr in pRows {
                    if let num: String = pr["num"],
                       let digits = Self.lastTenDigits(num) {
                        phones[digits] = name
                    }
                }
                // Emails
                let eRows = try Row.fetchAll(db, sql: """
                    SELECT ZADDRESS AS addr FROM ZABCDEMAILADDRESS
                    WHERE ZOWNER = ?
                """, arguments: [pk])
                for er in eRows {
                    if let addr: String = er["addr"], !addr.isEmpty {
                        emails[addr.lowercased()] = name
                    }
                }
            }
        }
    }

    /// "Russell Foltz-Smith", "Apple Inc.", or nil if empty.
    fileprivate static func formatName(
        first: String?, last: String?, nick: String?, org: String?
    ) -> String? {
        let parts = [first, last].compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if !parts.isEmpty { return parts.joined(separator: " ") }
        if let nick, !nick.isEmpty { return nick }
        if let org, !org.isEmpty { return org }
        return nil
    }

    /// Last 10 digits of a phone string, for normalization-free matching
    /// of US-style numbers across "(310) 555-1234", "+13105551234", etc.
    /// Returns nil for shorter strings (likely short codes or invalid).
    public static func lastTenDigits(_ s: String) -> String? {
        let digits = s.unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) }
            .map { String($0) }.joined()
        guard digits.count >= 10 else { return nil }
        return String(digits.suffix(10))
    }
}
