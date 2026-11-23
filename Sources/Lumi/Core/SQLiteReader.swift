import Foundation
import SQLite3

final class SQLiteReader {
    private var db: OpaquePointer?

    /// Exposes whether the underlying handle was opened strictly read-only (useful in tests).
    private(set) var openedReadOnly: Bool = false

    init?(path: String) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { return nil }

        // 1. Always open strictly read-only first. Works on all non-WAL DBs and all active WAL DBs
        //    with an initialized -shm index, guaranteeing zero mutations and zero close checkpoints.
        let roFlags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        if sqlite3_open_v2(path, &db, roFlags, nil) == SQLITE_OK, let handle = db {
            sqlite3_busy_timeout(handle, 300)
            if Self.canExecuteReadProbe(handle) {
                openedReadOnly = true
                return
            }
            sqlite3_close(handle)
            self.db = nil
        } else if let handle = db {
            sqlite3_close(handle)
            self.db = nil
        }

        // 2. When a WAL-mode database's writer cleanly exited and removed -wal/-shm (or left a 0-byte -wal),
        //    SQLite's normal READONLY fails with SQLITE_CANTOPEN because it cannot create -shm.
        //    Opening with URI `immutable=1` + SQLITE_OPEN_READONLY reads the checkpointed main DB file
        //    100% read-only WITHOUT ever creating -shm, opening a write handle, or checkpointing on close!
        //    If a non-empty -wal exists without -shm (transient writer handoff), return nil and let the
        //    scanner keep its last good snapshot until the next tick.
        let walSize: UInt64 = {
            guard let attrs = try? fm.attributesOfItem(atPath: path + "-wal"),
                  let n = attrs[.size] as? NSNumber else { return 0 }
            return n.uint64Value
        }()
        guard walSize == 0 else { return nil }

        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "?#")
        guard let encodedPath = path.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        let uri = "file:\(encodedPath)?immutable=1"
        let uriFlags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX | SQLITE_OPEN_URI
        if sqlite3_open_v2(uri, &db, uriFlags, nil) == SQLITE_OK, let handle = db {
            sqlite3_busy_timeout(handle, 300)
            if Self.canExecuteReadProbe(handle) {
                openedReadOnly = true
                return
            }
            sqlite3_close(handle)
            self.db = nil
        } else if let handle = db {
            sqlite3_close(handle)
            self.db = nil
        }
        return nil
    }

    private static func canExecuteReadProbe(_ handle: OpaquePointer) -> Bool {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "SELECT 1 FROM sqlite_master LIMIT 1;", -1, &stmt, nil) == SQLITE_OK,
              let stmt else {
            return false
        }
        defer { sqlite3_finalize(stmt) }
        let rc = sqlite3_step(stmt)
        return rc == SQLITE_ROW || rc == SQLITE_DONE
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    /// Runs multiple related SELECT statements inside a single consistent read-only snapshot.
    func withReadTransaction<T>(_ body: () -> T) -> T {
        guard let db else { return body() }
        let began = sqlite3_exec(db, "BEGIN DEFERRED;", nil, nil, nil) == SQLITE_OK
        defer {
            if began {
                sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
            }
        }
        return body()
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

    /// Returns true if a table exists in `sqlite_master` (distinguishes absent optional tables from transient SQLite busy/lock errors).
    func tableExists(_ name: String) -> Bool {
        let escaped = name.replacingOccurrences(of: "'", with: "''")
        var found = false
        let ok = query("SELECT 1 FROM sqlite_master WHERE type='table' AND name='\(escaped)' LIMIT 1;") { _ in
            found = true
        }
        return ok && found
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

    static func double(_ stmt: OpaquePointer, _ col: Int32) -> Double {
        sqlite3_column_double(stmt, col)
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

    /// Shared `$HOME`-first live directory resolver used identically by both `NativeHookRelay` and scanners.
    static var defaultLiveDir: String {
        if let envHome = ProcessInfo.processInfo.environment["HOME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !envHome.isEmpty {
            return "\(envHome)/.lumi/live"
        }
        return "\(NSHomeDirectory())/.lumi/live"
    }

    static func loadAllGrouped(dir: String = defaultLiveDir) -> [String: [String: LiveHookRecord]] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { return [:] }
        let now = Date()
        var grouped: [String: [String: LiveHookRecord]] = [:]

        for file in entries where file.hasSuffix(".json") && !file.hasPrefix(".") {
            let full = (dir as NSString).appendingPathComponent(file)
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: full)),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let sid = obj["sessionId"] as? String, !sid.isEmpty else { continue }

            let updatedAt = Date(timeIntervalSince1970: obj["updatedAt"] as? Double ?? 0)
            if now.timeIntervalSince(updatedAt) > 172_800 {
                // Coordinate expired-file cleanup with NativeHookRelay's per-session flock so we never
                // unlink a fresh replacement written concurrently at the same path.
                let baseName = String(file.dropLast(5)) // strip ".json"
                let lockPath = (dir as NSString).appendingPathComponent(".\(baseName).lock")
                let lockFD = open(lockPath, O_CREAT | O_RDWR, 0o600)
                if lockFD >= 0 {
                    if flock(lockFD, LOCK_EX | LOCK_NB) == 0 {
                        if let attrs = try? fm.attributesOfItem(atPath: full),
                           let mtime = attrs[.modificationDate] as? Date,
                           now.timeIntervalSince(mtime) > 172_800 {
                            try? fm.removeItem(atPath: full)
                        }
                        _ = flock(lockFD, LOCK_UN)
                    }
                    close(lockFD)
                }
                continue
            }

            let agent = (obj["agent"] as? String ?? "").lowercased()
            guard !agent.isEmpty else { continue }
            let turnStart = obj["turnStartedAt"] as? Double ?? 0
            let completed = obj["completedAt"] as? Double ?? 0

            let rec = LiveHookRecord(
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
            grouped[agent, default: [:]][sid] = rec
        }
        return grouped
    }

    static func loadAll(forAgent agentFilter: String? = nil, dir: String = defaultLiveDir) -> [String: LiveHookRecord] {
        let grouped = loadAllGrouped(dir: dir)
        if let filter = agentFilter?.lowercased() {
            return grouped[filter] ?? [:]
        }
        var flat: [String: LiveHookRecord] = [:]
        for (agent, map) in grouped {
            for (sid, rec) in map {
                flat["\(agent):\(sid)"] = rec
            }
        }
        return flat
    }
}

/// UTF-8-safe JSONL tail & head reader that aligns byte offsets to newline (`0x0A`) boundaries
/// BEFORE decoding, preventing multi-byte UTF-8 (Chinese/Emoji) boundary splits from breaking decoding.
enum FileTailReader {
    static func readTailLines(from fh: FileHandle, fileSize: UInt64, maxBytes: UInt64) -> [String]? {
        let offset = fileSize > maxBytes ? (fileSize - maxBytes) : 0
        do { try fh.seek(toOffset: offset) } catch { return nil }
        let raw = fh.readDataToEndOfFile()
        return splitCompleteLines(from: raw, dropLeadingPartial: offset > 0)
    }

    static func readHeadLines(from fh: FileHandle, maxBytes: Int) -> [String] {
        do { try fh.seek(toOffset: 0) } catch { return [] }
        let raw = fh.readData(ofLength: maxBytes)
        // Drop any truncated trailing line if we hit the head read cap mid-line (or mid-UTF-8 char).
        let slice: Data.SubSequence
        if raw.count >= maxBytes, let lastNL = raw.lastIndex(of: 0x0A) {
            slice = raw[..<lastNL]
        } else {
            slice = raw[...]
        }
        let text = String(decoding: slice, as: UTF8.self)
        return text.components(separatedBy: .newlines).filter { !$0.isEmpty }
    }

    static func splitCompleteLines(from data: Data, dropLeadingPartial: Bool) -> [String] {
        let slice: Data.SubSequence
        if dropLeadingPartial {
            guard let firstNL = data.firstIndex(of: 0x0A) else { return [] }
            let nextIdx = data.index(after: firstNL)
            guard nextIdx < data.endIndex else { return [] }
            slice = data[nextIdx...]
        } else {
            slice = data[...]
        }
        let text = String(decoding: slice, as: UTF8.self)
        return text.components(separatedBy: .newlines).filter { !$0.isEmpty }
    }
}

/// Strict, lock-free ASCII ISO-8601 parser with exact civil-calendar & timezone bounds validation.
enum FastISO8601Parser {
    private static let isoFracFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoBasicFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parse(_ raw: String, allowBareUTC: Bool = false) -> Date? {
        guard !raw.isEmpty else { return nil }
        let bytes = Array(raw.utf8)
        let n = bytes.count
        if n >= 19,
           bytes[4] == 45, bytes[7] == 45, (bytes[10] == 84 || bytes[10] == 32),
           bytes[13] == 58, bytes[16] == 58 {
            @inline(__always)
            func digits(_ i: Int, _ len: Int) -> Int? {
                guard i + len <= n else { return nil }
                var v = 0
                for k in 0..<len {
                    let c = Int(bytes[i + k]) - 48
                    if c < 0 || c > 9 { return nil }
                    v = v * 10 + c
                }
                return v
            }

            guard let year = digits(0, 4), year >= 1970, year <= 2999,
                  let month = digits(5, 2), month >= 1, month <= 12,
                  let day = digits(8, 2), day >= 1, day <= daysInMonth(year: year, month: month),
                  let hour = digits(11, 2), hour <= 23,
                  let minute = digits(14, 2), minute <= 59,
                  let second = digits(17, 2), second <= 60 else {
                return nil
            }

            var idx = 19
            var frac = 0.0
            if idx < n && bytes[idx] == 46 { // '.'
                idx += 1
                var fracDigits = 0
                var scale = 0.1
                while idx < n {
                    let c = Int(bytes[idx]) - 48
                    if c < 0 || c > 9 { break }
                    frac += Double(c) * scale
                    scale *= 0.1
                    fracDigits += 1
                    idx += 1
                }
                guard fracDigits > 0 else { return nil }
            }

            var tzOffsetSec = 0
            if idx == n {
                guard allowBareUTC else { return nil }
            } else if idx == n - 1 && (bytes[idx] == 90 || bytes[idx] == 122) { // 'Z' / 'z'
                tzOffsetSec = 0
            } else if bytes[idx] == 43 || bytes[idx] == 45 { // '+' or '-'
                let sign = bytes[idx] == 43 ? 1 : -1
                idx += 1
                let tzh: Int
                let tzm: Int
                if idx + 5 == n && bytes[idx + 2] == 58,
                   let h = digits(idx, 2), let m = digits(idx + 3, 2) {
                    tzh = h; tzm = m
                } else if idx + 4 == n,
                          let h = digits(idx, 2), let m = digits(idx + 2, 2) {
                    tzh = h; tzm = m
                } else {
                    return nil
                }
                guard tzh <= 23, tzm <= 59 else { return nil }
                tzOffsetSec = sign * (tzh * 3600 + tzm * 60)
            } else {
                return nil
            }

            // Howard Hinnant's civil-to-days algorithm (days since 1970-01-01)
            let y = month <= 2 ? year - 1 : year
            let era = (y >= 0 ? y : y - 399) / 400
            let yoe = y - era * 400
            let mAdj = month + (month > 2 ? -3 : 9)
            let doy = (153 * mAdj + 2) / 5 + day - 1
            let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
            let days = era * 146097 + doe - 719468
            let clampedSec = min(second, 59)
            let secs = Double(days * 86400 + hour * 3600 + minute * 60 + clampedSec - tzOffsetSec) + frac
            return Date(timeIntervalSince1970: secs)
        }
        let normalized = raw.replacingOccurrences(of: " ", with: "T")
        if let d = isoFracFormatter.date(from: normalized) { return d }
        return isoBasicFormatter.date(from: normalized)
    }

    private static func daysInMonth(year: Int, month: Int) -> Int {
        switch month {
        case 1, 3, 5, 7, 8, 10, 12: return 31
        case 4, 6, 9, 11: return 30
        case 2:
            let leap = (year % 4 == 0 && year % 100 != 0) || (year % 400 == 0)
            return leap ? 29 : 28
        default:
            return 0
        }
    }
}
