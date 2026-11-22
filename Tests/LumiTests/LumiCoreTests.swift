import SQLite3
import XCTest
@testable import Lumi

final class LumiCoreTests: XCTestCase {
    func testProjectNameDisambiguatesGenericLeafFolders() {
        XCTAssertEqual(ProjectNameHelper.projectName(from: "/Users/alice/work/google_sim/lib"), "google_sim/lib")
        XCTAssertEqual(ProjectNameHelper.projectName(from: "file:///Users/alice/Projects/%E7%AB%8B%E5%88%BB%E8%B5%B7%E5%BA%8A%E9%97%B9%E9%92%9F"), "立刻起床闹钟")
        XCTAssertEqual(ProjectNameHelper.projectName(from: "/Users/alice/Documents/Codex/2026-10-31/new-chat-2"), "Codex · 10-31")
    }

    func testCleanOneLineStripsUserRequestAndMarkdown() {
        let raw = "<USER_REQUEST>\n# Fix [bug](https://example.com) now\n</USER_REQUEST>"
        XCTAssertEqual(ProjectNameHelper.cleanOneLine(raw), "Fix bug now")
    }

    func testCodexLongRunningTurnWithoutTaskStartedInTailStaysRunning() {
        let now = Date()
        let lines = [
            #"{"type":"response_item","payload":{"type":"reasoning"}}"#,
            #"{"type":"response_item","payload":{"type":"custom_tool_call","name":"exec","input":"swift build"}}"#,
            #"{"type":"event_msg","payload":{"type":"item_completed"}}"#
        ]
        let state = CodexRolloutParser.parse(lines: lines, mtime: now.addingTimeInterval(-3), now: now)
        XCTAssertEqual(state.status, .running)
        XCTAssertTrue(state.currentAction.contains("swift build"))
        XCTAssertNil(state.completedAt)
    }

    func testCodexExplicitTaskCompleteTransitionsToDone() {
        let now = Date()
        let compTs = Int(now.timeIntervalSince1970) - 5
        let lines = [
            #"{"type":"event_msg","payload":{"type":"task_started","started_at":\#(compTs - 42)}}"#,
            #"{"type":"event_msg","payload":{"type":"task_complete","completed_at":\#(compTs),"duration_ms":42000,"last_agent_message":"All checks passed."}}"#
        ]
        let state = CodexRolloutParser.parse(lines: lines, mtime: now, now: now)
        XCTAssertEqual(state.status, .done)
        XCTAssertEqual(state.lastAgentMessage, "All checks passed.")
        XCTAssertEqual(state.durationSec ?? 0, 42.0, accuracy: 0.1)
    }

    func testCodexTurnAbortedMarkedCanceled() {
        let now = Date()
        let lines = [
            #"{"type":"event_msg","payload":{"type":"task_started"}}"#,
            #"{"type":"event_msg","payload":{"type":"turn_aborted"}}"#
        ]
        let state = CodexRolloutParser.parse(lines: lines, mtime: now, now: now)
        XCTAssertEqual(state.status, .canceled)
    }

    func testSQLiteReaderReadsWALDatabaseWhenWalAndShmAreMissing() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("lumi-wal-test-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let dbPath = dir.appendingPathComponent("test.db").path
        var rawDB: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbPath, &rawDB), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(rawDB, "PRAGMA journal_mode=WAL; CREATE TABLE items(id TEXT, status TEXT); INSERT INTO items VALUES ('a1', 'RUNNING'); PRAGMA wal_checkpoint(TRUNCATE);", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_close(rawDB), SQLITE_OK)

        // Ensure -wal and -shm are absent (matching Antigravity after its writer checkpoints & closes)
        try? fm.removeItem(atPath: dbPath + "-wal")
        try? fm.removeItem(atPath: dbPath + "-shm")
        XCTAssertFalse(fm.fileExists(atPath: dbPath + "-wal"))
        XCTAssertFalse(fm.fileExists(atPath: dbPath + "-shm"))

        guard let reader = SQLiteReader(path: dbPath) else {
            XCTFail("SQLiteReader failed to open WAL DB without -wal/-shm")
            return
        }

        var rows: [(String, String)] = []
        let ok = reader.query("SELECT id, status FROM items;") { stmt in
            rows.append((SQLiteReader.string(stmt, 0), SQLiteReader.string(stmt, 1)))
        }
        XCTAssertTrue(ok)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.0, "a1")
        XCTAssertEqual(rows.first?.1, "RUNNING")

        // Verify PRAGMA query_only prevents mutations
        let writeOk = reader.query("INSERT INTO items VALUES ('a2', 'IDLE');") { _ in }
        XCTAssertFalse(writeOk)
    }

    func testL10nTranslatesScannerActionsToEnglish() {
        let en = L10n(isEnglish: true)
        let zh = L10n(isEnglish: false)
        XCTAssertEqual(en.action("编辑 ShadowPass.ts"), "Editing ShadowPass.ts")
        XCTAssertEqual(en.action("收尾确认中…"), "Settling…")
        XCTAssertEqual(en.action("等待你的审批或回复"), "Waiting for approval")
        XCTAssertEqual(en.action("等待 2 个子 Agent 执行…"), "Waiting on 2 subagent(s)…")
        XCTAssertEqual(zh.action("编辑 ShadowPass.ts"), "编辑 ShadowPass.ts")
    }

    func testCodexRolloutParserDetectsApprovalNeedsInput() {
        let now = Date()
        let lines = [
            #"{"type":"event_msg","payload":{"type":"task_started","started_at":1770000000}}"#,
            #"{"type":"event_msg","payload":{"type":"exec_approval_request","command":"rm -rf build"}}"#
        ]
        let parsed = CodexRolloutParser.parse(lines: lines, mtime: now, now: now)
        XCTAssertEqual(parsed.status, .needsInput)
    }

    func testUpdateCheckerSemanticVersionComparison() {
        XCTAssertTrue(UpdateChecker.isNewer("v1.3.0", than: "1.2.0"))
        XCTAssertTrue(UpdateChecker.isNewer("2.0.0", than: "1.9.9"))
        XCTAssertFalse(UpdateChecker.isNewer("v1.3.0", than: "1.3.0"))
        XCTAssertFalse(UpdateChecker.isNewer("v1.2.9", than: "1.3.0"))
    }
}
