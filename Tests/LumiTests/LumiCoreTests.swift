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

    func testFormatMMSSFormatsTabularElapsedDuration() {
        XCTAssertEqual(ProjectNameHelper.formatMMSS(0), "00:00")
        XCTAssertEqual(ProjectNameHelper.formatMMSS(9), "00:09")
        XCTAssertEqual(ProjectNameHelper.formatMMSS(134), "02:14")
        XCTAssertEqual(ProjectNameHelper.formatMMSS(3903), "1h05")
    }

    func testAntigravityAXPromptDetectorCatchesBrowserDownloadApproval() {
        let buttons = [
            "Stop execution",
            "Yes, allow this download",
            "No (tell the agent what to do instead)",
            "Skip",
            "Submit ↵",
            "Cancel (⌃C)"
        ]
        let texts = [
            "Gemini Web Image Generator",
            "Allow the browser agent to download a file?",
            "File",
            "Gemini_Generated_Image.jpeg"
        ]
        XCTAssertEqual(
            AntigravityAXPromptDetector.classifyPrompt(buttons: buttons, texts: texts),
            "Allow the browser agent to download a file?"
        )
    }

    func testAntigravityAXPromptDetectorIgnoresNormalRunningChrome() {
        let buttons = [
            "Automations", "Stop execution", "Copy", "Undo to this point",
            "Record voice memo", "Start Voice mode", "Cancel (⌃C)", "Settings"
        ]
        let texts = ["Ask anything, @ to mention, / for actions", "Agent working"]
        XCTAssertNil(AntigravityAXPromptDetector.classifyPrompt(buttons: buttons, texts: texts))
    }

    func testAntigravityAXPromptDetectorExtractsConversationIdFromLocalURL() {
        let url = "https://127.0.0.1:55044/c/72a7abe1-df64-462b-9484-f9998214b483?project=a64f3e40"
        XCTAssertEqual(
            AntigravityAXPromptDetector.extractConversationId(from: url),
            "72a7abe1-df64-462b-9484-f9998214b483"
        )
    }

    func testT3CodeScannerDetectsRunningWaitingCompletedAndSkipsUntouchedImports() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("lumi-t3-test-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let dbPath = dir.appendingPathComponent("statev2.sqlite").path
        var rawDB: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbPath, &rawDB), SQLITE_OK)

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let now = Date()
        let tStart = iso.string(from: now.addingTimeInterval(-90))
        let tRecent = iso.string(from: now.addingTimeInterval(-10))
        let tDone = iso.string(from: now.addingTimeInterval(-30))

        let schemaAndData = """
        PRAGMA journal_mode=WAL;
        CREATE TABLE projection_projects (project_id TEXT PRIMARY KEY, title TEXT NOT NULL, workspace_root TEXT NOT NULL);
        CREATE TABLE orchestration_v2_projection_threads (
            thread_id TEXT PRIMARY KEY, project_id TEXT NOT NULL, title TEXT NOT NULL,
            default_provider TEXT NOT NULL, created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
            archived_at TEXT, deleted_at TEXT, payload_json TEXT NOT NULL
        );
        CREATE TABLE orchestration_v2_projection_runs (
            run_id TEXT PRIMARY KEY, thread_id TEXT NOT NULL, ordinal INTEGER NOT NULL,
            provider TEXT NOT NULL, status TEXT NOT NULL, requested_at TEXT NOT NULL,
            completed_at TEXT, payload_json TEXT NOT NULL
        );
        CREATE TABLE orchestration_v2_projection_nodes (
            node_id TEXT PRIMARY KEY, thread_id TEXT NOT NULL, run_id TEXT,
            kind TEXT NOT NULL, status TEXT NOT NULL, started_at TEXT, completed_at TEXT,
            payload_json TEXT NOT NULL
        );
        CREATE TABLE orchestration_v2_projection_turn_items (
            turn_item_id TEXT PRIMARY KEY, thread_id TEXT NOT NULL, run_id TEXT,
            ordinal INTEGER NOT NULL, type TEXT NOT NULL, status TEXT NOT NULL,
            updated_at TEXT NOT NULL, payload_json TEXT NOT NULL
        );
        CREATE TABLE provider_session_runtime (thread_id TEXT PRIMARY KEY, status TEXT NOT NULL);

        INSERT INTO projection_projects VALUES ('p1', 'LumiApp', '/Users/test/lumi');
        INSERT INTO projection_projects VALUES ('p2', 'No project', '/Users/test/.t3/scratch');

        -- 1. Actively running thread with command_execution + 1 active subagent
        INSERT INTO orchestration_v2_projection_threads VALUES
            ('th-run', 'p1', 'Add T3 Code support', 'codex', '\(tStart)', '\(tRecent)', NULL, NULL, '{"worktreePath":"/Users/test/lumi"}');
        INSERT INTO orchestration_v2_projection_runs VALUES
            ('run-1', 'th-run', 1, 'codex', 'running', '\(tStart)', NULL, '{}');
        INSERT INTO orchestration_v2_projection_nodes VALUES
            ('n-sub', 'th-run', 'run-1', 'subagent', 'running', '\(tRecent)', NULL, '{}');
        INSERT INTO orchestration_v2_projection_turn_items VALUES
            ('i-cmd', 'th-run', 'run-1', 10, 'command_execution', 'running', '\(tRecent)', '{"input":"swift test"}');

        -- 2. Thread waiting on approval request inside a running turn
        INSERT INTO orchestration_v2_projection_threads VALUES
            ('th-wait', 'p1', 'Deploy release', 'claude', '\(tStart)', '\(tRecent)', NULL, NULL, '{}');
        INSERT INTO orchestration_v2_projection_runs VALUES
            ('run-2', 'th-wait', 1, 'claude', 'running', '\(tStart)', NULL, '{}');
        INSERT INTO orchestration_v2_projection_nodes VALUES
            ('n-appr', 'th-wait', 'run-2', 'approval_request', 'waiting_for_approval', '\(tRecent)', NULL, '{"command":"git push"}');

        -- 3. Completed thread (scratch project -> falls back cleanly to 独立对话)
        INSERT INTO orchestration_v2_projection_threads VALUES
            ('th-done', 'p2', 'Quick question', 'antigravity', '\(tStart)', '\(tDone)', NULL, NULL, '{"worktreePath":"/Users/test/.t3/scratch/demo"}');
        INSERT INTO orchestration_v2_projection_runs VALUES
            ('run-3', 'th-done', 1, 'antigravity', 'completed', '\(tStart)', '\(tDone)', '{}');

        -- 4. Untouched imported Codex thread (zero runs -> must be skipped to avoid duplicates)
        INSERT INTO orchestration_v2_projection_threads VALUES
            ('import:codex:abc-123', 'p1', 'Old Codex thread', 'codex', '\(tStart)', '\(tRecent)', NULL, NULL, '{}');
        """

        XCTAssertEqual(sqlite3_exec(rawDB, schemaAndData, nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_close(rawDB), SQLITE_OK)

        let scanner = T3CodeScanner(v2DbPath: dbPath, v1DbPath: dir.appendingPathComponent("none.sqlite").path, isT3RunningCheck: { true })
        let sessions = scanner.scan(lookbackHours: 24, now: now)

        XCTAssertEqual(sessions.count, 3)
        XCTAssertNil(sessions.first(where: { $0.rawId == "import:codex:abc-123" }))

        let running = try XCTUnwrap(sessions.first(where: { $0.rawId == "th-run" }))
        XCTAssertEqual(running.kind, .t3code)
        XCTAssertEqual(running.status, .running)
        XCTAssertEqual(running.project, "LumiApp")
        XCTAssertEqual(running.activeSubagents, 1)
        XCTAssertTrue(running.currentAction.contains("swift test"))

        let waiting = try XCTUnwrap(sessions.first(where: { $0.rawId == "th-wait" }))
        XCTAssertEqual(waiting.status, .needsInput)
        XCTAssertTrue(waiting.currentAction.contains("git push"))

        let done = try XCTUnwrap(sessions.first(where: { $0.rawId == "th-done" }))
        XCTAssertEqual(done.status, .done)
        XCTAssertEqual(done.project, "独立对话")
        XCTAssertEqual(done.durationSec ?? 0, 60.0, accuracy: 2.0)
    }
}
