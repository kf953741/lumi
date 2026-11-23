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

    func testT3CodeDeduplicatesUnderlyingCodexAndAntigravitySessions() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("lumi-t3-dedupe-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let dbPath = dir.appendingPathComponent("statev2.sqlite").path
        var rawDB: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbPath, &rawDB), SQLITE_OK)

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let now = Date()
        let tStart = iso.string(from: now.addingTimeInterval(-30))
        let tNow = iso.string(from: now.addingTimeInterval(-2))

        let sql = """
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
        CREATE TABLE orchestration_v2_projection_provider_threads (
            provider_thread_id TEXT PRIMARY KEY, thread_id TEXT NOT NULL, provider TEXT NOT NULL,
            payload_json TEXT NOT NULL
        );
        CREATE TABLE provider_session_runtime (
            thread_id TEXT PRIMARY KEY, provider_name TEXT NOT NULL, status TEXT NOT NULL,
            resume_cursor_json TEXT
        );

        INSERT INTO projection_projects VALUES ('p1', 'MyRepo', '/Users/test/MyRepo');

        -- T3 thread running GPT via Codex with bound nativeThreadRef
        INSERT INTO orchestration_v2_projection_threads VALUES
            ('t3-gpt', 'p1', 'Refactor API', 'codex', '\(tStart)', '\(tNow)', NULL, NULL, '{"worktreePath":"/Users/test/MyRepo"}');
        INSERT INTO orchestration_v2_projection_runs VALUES
            ('run-gpt', 't3-gpt', 1, 'codex', 'running', '\(tStart)', NULL, '{}');
        INSERT INTO orchestration_v2_projection_provider_threads VALUES
            ('pt-1', 't3-gpt', 'codex', '{"nativeThreadRef":{"driver":"codex","nativeId":"01a20458-f6db-73c1-b7bb-549783b69ea8","strength":"strong"}}');

        -- T3 thread in first-second pending window (nativeThreadRef not written yet)
        INSERT INTO orchestration_v2_projection_threads VALUES
            ('t3-pending', 'p1', 'Just started', 'codex', '\(tNow)', '\(tNow)', NULL, NULL, '{"worktreePath":"/Users/test/PendingRepo"}');
        INSERT INTO orchestration_v2_projection_runs VALUES
            ('run-pend', 't3-pending', 1, 'codex', 'starting', '\(tNow)', NULL, '{}');

        -- Untouched imported Codex thread (must NOT suppress standalone Codex)
        INSERT INTO orchestration_v2_projection_threads VALUES
            ('import:codex:standalone-codex-id', 'p1', 'Standalone Codex', 'codex', '\(tStart)', '\(tStart)', NULL, NULL, '{}');
        INSERT INTO orchestration_v2_projection_provider_threads VALUES
            ('pt-imp', 'import:codex:standalone-codex-id', 'codex', '{"nativeThreadRef":{"driver":"codex","nativeId":"standalone-codex-id","strength":"strong"}}');
        """
        XCTAssertEqual(sqlite3_exec(rawDB, sql, nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_close(rawDB), SQLITE_OK)

        let scanner = T3CodeScanner(v2DbPath: dbPath, v1DbPath: dir.appendingPathComponent("none.sqlite").path, isT3RunningCheck: { true })
        let res = scanner.scanDetailed(lookbackHours: 24, now: now)

        func makeSession(kind: AgentKind, rawId: String, cwd: String, startedAt: Date) -> AgentSession {
            AgentSession(
                id: "\(kind.rawValue):\(rawId)", rawId: rawId, kind: kind, title: "test",
                project: "MyRepo", cwd: cwd, isCLI: false, status: .running,
                currentAction: "执行中…", detailSummary: "", startedAt: startedAt,
                updatedAt: startedAt, completedAt: nil, durationSec: nil, activeSubagents: 0, isUnread: false
            )
        }

        // 1. Exact nativeThreadRef match -> MUST be owned/suppressed
        let dupCodex = makeSession(kind: .codex, rawId: "01a20458-f6db-73c1-b7bb-549783b69ea8", cwd: "/Users/test/MyRepo", startedAt: now)
        XCTAssertTrue(res.ownsUnderlying(dupCodex))

        // 2. T3 scratch directory fallback -> MUST be owned/suppressed
        let scratchCodex = makeSession(kind: .codex, rawId: "any-new-id", cwd: "/Users/test/.t3/scratch/2026-11-22-demo", startedAt: now)
        XCTAssertTrue(res.ownsUnderlying(scratchCodex))

        // 3. First-second pending race match (same provider + cwd + within 20s) -> MUST be owned/suppressed
        let pendingCodex = makeSession(kind: .codex, rawId: "brand-new-id", cwd: "/Users/test/PendingRepo", startedAt: now)
        XCTAssertTrue(res.ownsUnderlying(pendingCodex))

        // 4. Genuine standalone Codex session (even if previously imported untouched!) -> MUST NOT be suppressed
        let realStandalone = makeSession(kind: .codex, rawId: "standalone-codex-id", cwd: "/Users/test/MyRepo", startedAt: now.addingTimeInterval(-120))
        XCTAssertFalse(res.ownsUnderlying(realStandalone))
    }

    func testT3CodeDeepLinkEncodesThreadIdsAndReadsSiblingEnvironmentId() throws {
        // 1. Plain UUID thread ID
        let uuidUrl = T3CodeScanner.deepLinkURL(
            environmentId: "412f7ce2-4663-4a5e-a547-d0c1f060808d",
            threadId: "36999499-43c0-4845-8fdf-a50c85c7b97b"
        )
        XCTAssertEqual(
            uuidUrl?.absoluteString,
            "t3code://threads/412f7ce2-4663-4a5e-a547-d0c1f060808d/36999499-43c0-4845-8fdf-a50c85c7b97b"
        )

        // 2. Colon-delimited MCP/imported thread IDs must percent-encode ':' -> '%3A'
        let mcpUrl = T3CodeScanner.deepLinkURL(
            environmentId: "412f7ce2-4663-4a5e-a547-d0c1f060808d",
            threadId: "mcp:launch:af6eda900c71bfdebf15f3c90f174b2982cd7468e21a5c9ec5e2600e55165bbb",
            scheme: "t3code-dev"
        )
        XCTAssertEqual(
            mcpUrl?.absoluteString,
            "t3code-dev://threads/412f7ce2-4663-4a5e-a547-d0c1f060808d/mcp%3Alaunch%3Aaf6eda900c71bfdebf15f3c90f174b2982cd7468e21a5c9ec5e2600e55165bbb"
        )

        // 3. Empty inputs return nil
        XCTAssertNil(T3CodeScanner.deepLinkURL(environmentId: "  ", threadId: "abc"))
        XCTAssertNil(T3CodeScanner.deepLinkURL(environmentId: "env-1", threadId: ""))

        // 4. Instance helper reads sibling `environment-id` file next to `statev2.sqlite`
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("lumi-t3-envid-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let dbPath = dir.appendingPathComponent("statev2.sqlite").path
        let scanner = T3CodeScanner(v2DbPath: dbPath, v1DbPath: dir.appendingPathComponent("none.sqlite").path, isT3RunningCheck: { true })
        XCTAssertNil(scanner.deepLinkURL(forThreadId: "import:codex:abc-123", scheme: "t3code"))

        try "412f7ce2-4663-4a5e-a547-d0c1f060808d\n".write(
            to: dir.appendingPathComponent("environment-id"),
            atomically: true,
            encoding: .utf8
        )
        XCTAssertEqual(
            scanner.deepLinkURL(forThreadId: "import:codex:abc-123", scheme: "t3code")?.absoluteString,
            "t3code://threads/412f7ce2-4663-4a5e-a547-d0c1f060808d/import%3Acodex%3Aabc-123"
        )
    }

    func testGeminiDesktopClassifierHandlesWindowTitlesRunningApprovalsAndSidebarTasks() {
        // 1. Window title parsing & non-chat settings window exclusion
        XCTAssertEqual(
            GeminiDesktopClassifier.extractChatTitle(fromWindowTitle: "Gemini - 如何在 Mac 上使用 Gemini 操控电脑"),
            "如何在 Mac 上使用 Gemini 操控电脑"
        )
        XCTAssertEqual(
            GeminiDesktopClassifier.extractChatTitle(fromWindowTitle: "Gemini — Build an iOS app"),
            "Build an iOS app"
        )
        XCTAssertEqual(GeminiDesktopClassifier.extractChatTitle(fromWindowTitle: "Gemini"), "")
        XCTAssertNil(GeminiDesktopClassifier.extractChatTitle(fromWindowTitle: "用量限额"))
        XCTAssertNil(GeminiDesktopClassifier.extractChatTitle(fromWindowTitle: "Usage Limits"))

        // 2. Running detection via Chinese & English stop-response / stop-task buttons
        let zhRun = GeminiDesktopClassifier.classifyWindow(
            buttons: [GeminiAXButton(identifier: "", title: "", description: "停止回答")],
            statusTexts: []
        )
        XCTAssertEqual(zhRun.status, .running)

        let enTaskRun = GeminiDesktopClassifier.classifyWindow(
            buttons: [GeminiAXButton(identifier: "", title: "", description: "Stop task")],
            statusTexts: []
        )
        XCTAssertEqual(enTaskRun.status, .running)

        // Voice recording stop button must NOT trigger a false running chat state
        let micStop = GeminiDesktopClassifier.classifyWindow(
            buttons: [GeminiAXButton(identifier: "recording_stop_button", title: "", description: "停止录音")],
            statusTexts: []
        )
        XCTAssertEqual(micStop.status, .done)

        // 3. Needs-input / Computer Use approval detection
        let approval = GeminiDesktopClassifier.classifyWindow(
            buttons: [
                GeminiAXButton(identifier: "", title: "", description: "停止回答"),
                GeminiAXButton(identifier: "", title: "", description: "允许一次"),
                GeminiAXButton(identifier: "", title: "", description: "暂不")
            ],
            statusTexts: ["允许 Gemini 使用 Chrome 来处理你的任务？"]
        )
        XCTAssertEqual(approval.status, .needsInput)
        XCTAssertTrue(approval.action.contains("允许 Gemini 使用 Chrome"))

        // 4. Sidebar task badges (ZH & EN)
        let zhInProg = GeminiDesktopClassifier.parseSidebarTaskRow("“冰岛行程规划”，进行中")
        XCTAssertEqual(zhInProg?.title, "冰岛行程规划")
        XCTAssertEqual(zhInProg?.status, .running)

        let enAttn = GeminiDesktopClassifier.parseSidebarTaskRow("Deep research report, Needs attention")
        XCTAssertEqual(enAttn?.title, "Deep research report")
        XCTAssertEqual(enAttn?.status, .needsInput)

        let zhReady = GeminiDesktopClassifier.parseSidebarTaskRow("“竞品分析”，准备就绪")
        XCTAssertEqual(zhReady?.title, "竞品分析")
        XCTAssertEqual(zhReady?.status, .done)

        XCTAssertNil(GeminiDesktopClassifier.parseSidebarTaskRow("大模型学习路线GitHub仓库推荐，已固定"))

        // 5. Native deep link generation
        XCTAssertEqual(
            GeminiDesktopClassifier.deepLinkURL(conversationId: "c_1bfb80c6c2b11224")?.absoluteString,
            "googlegemini://conversation/c_1bfb80c6c2b11224"
        )
    }

    func testT3CodeFastISOParserMatchesFoundationFormatter() throws {
        let fracFmt = ISO8601DateFormatter()
        fracFmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let basicFmt = ISO8601DateFormatter()
        basicFmt.formatOptions = [.withInternetDateTime]

        let samples = [
            "2026-11-22T18:01:20.410Z",
            "2024-02-29T23:59:59.999Z",
            "2026-01-01T00:00:00Z",
            "2026-11-23T12:30:45+08:00"
        ]
        for s in samples {
            let expected = try XCTUnwrap(fracFmt.date(from: s) ?? basicFmt.date(from: s))
            let actual = try XCTUnwrap(T3CodeScanner.parseISO(s))
            XCTAssertEqual(actual.timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: 0.001, "Mismatch for \(s)")
        }
        XCTAssertNil(T3CodeScanner.parseISO(""))
        XCTAssertNil(T3CodeScanner.parseISO("not-a-date"))
    }
}
