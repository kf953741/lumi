import Foundation
import SQLite3

final class SQLiteReader {
    private var db: OpaquePointer?

    init?(path: String) {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        // IMPORTANT: WAL-mode SQLite databases (like Antigravity's conversation_summaries.db and
        // Codex's state_5.sqlite) frequently remove -wal/-shm when their writer checkpoints/closes.
        // Opening such a DB with SQLITE_OPEN_READONLY fails with SQLITE_CANTOPEN (14) on every SELECT
        // because SQLite cannot initialize the shared-memory WAL index without write access.
        // Opening READWRITE (never CREATE) + PRAGMA query_only = ON guarantees zero mutations and
        // zero checkpoint contention while reading WAL databases reliably whether -wal exists or not.
        let rwFlags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX
        if sqlite3_open_v2(path, &db, rwFlags, nil) == SQLITE_OK, let db {
            sqlite3_busy_timeout(db, 300)
            sqlite3_exec(db, "PRAGMA query_only = ON;", nil, nil, nil)
            return
        }
        if let db {
            sqlite3_close(db)
            self.db = nil
        }

        // Fallback for genuinely read-only files/directories
        let roFlags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        if sqlite3_open_v2(path, &db, roFlags, nil) != SQLITE_OK {
            if let db { sqlite3_close(db) }
            return nil
        }
        sqlite3_busy_timeout(db, 300)
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    @discardableResult
    func query(_ sql: String, rowHandler: (OpaquePointer) -> Void) -> Bool {
        guard let db else { return false }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return false }
        defer { sqlite3_finalize(stmt) }
        var rc = sqlite3_step(stmt)
        while rc == SQLITE_ROW {
            rowHandler(stmt)
            rc = sqlite3_step(stmt)
        }
        return rc == SQLITE_DONE
    }

    static func string(_ stmt: OpaquePointer, _ col: Int32) -> String {
        guard let cStr = sqlite3_column_text(stmt, col) else { return "" }
        return String(cString: cStr)
    }

    static func int(_ stmt: OpaquePointer, _ col: Int32) -> Int {
        Int(sqlite3_column_int64(stmt, col))
    }

    static func int64(_ stmt: OpaquePointer, _ col: Int32) -> Int64 {
        sqlite3_column_int64(stmt, col)
    }
}

struct LiveHookRecord {
    let agent: String
    let sessionId: String
    let event: String
    let state: String
    let action: String
    let lastToolLabel: String
    let title: String
    let lastUserInput: String
    let firstUserInput: String
    let cwd: String
    let workspacePaths: [String]
    let terminationReason: String
    let error: String
    let updatedAt: Date
    let turnStartedAt: Date?
    let completedAt: Date?
    let durationSec: TimeInterval?

    static func loadAll(forAgent agentFilter: String? = nil) -> [String: LiveHookRecord] {
        let dir = "\(NSHomeDirectory())/.lumi/live"
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { return [:] }
        let now = Date()
        var out: [String: LiveHookRecord] = [:]

        for file in entries where file.hasSuffix(".json") {
            if let filter = agentFilter, !file.hasPrefix("\(filter)__") { continue }
            let full = (dir as NSString).appendingPathComponent(file)
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: full)),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let sid = obj["sessionId"] as? String, !sid.isEmpty else { continue }

            let updatedAt = Date(timeIntervalSince1970: obj["updatedAt"] as? Double ?? 0)
            if now.timeIntervalSince(updatedAt) > 172_800 {
                try? fm.removeItem(atPath: full)
                continue
            }

            let agent = (obj["agent"] as? String ?? "").lowercased()
            let turnStart = obj["turnStartedAt"] as? Double ?? 0
            let completed = obj["completedAt"] as? Double ?? 0
            let key = agentFilter != nil ? sid : "\(agent):\(sid)"

            out[key] = LiveHookRecord(
                agent: agent,
                sessionId: sid,
                event: obj["event"] as? String ?? "",
                state: obj["state"] as? String ?? "",
                action: obj["action"] as? String ?? "",
                lastToolLabel: obj["lastToolLabel"] as? String ?? "",
                title: obj["title"] as? String ?? "",
                lastUserInput: obj["lastUserInput"] as? String ?? "",
                firstUserInput: obj["firstUserInput"] as? String ?? "",
                cwd: obj["cwd"] as? String ?? "",
                workspacePaths: obj["workspacePaths"] as? [String] ?? [],
                terminationReason: obj["terminationReason"] as? String ?? "",
                error: obj["error"] as? String ?? "",
                updatedAt: updatedAt,
                turnStartedAt: turnStart > 0 ? Date(timeIntervalSince1970: turnStart) : nil,
                completedAt: completed > 0 ? Date(timeIntervalSince1970: completed) : nil,
                durationSec: obj["durationSec"] as? Double
            )
        }
        return out
    }
}
