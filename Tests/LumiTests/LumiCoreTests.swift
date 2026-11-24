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
        XCTAssertTrue(reader.openedReadOnly)
        // immutable=1 read-only open MUST NOT create -shm or -wal sidecars on disk
        XCTAssertFalse(fm.fileExists(atPath: dbPath + "-wal"))
        XCTAssertFalse(fm.fileExists(atPath: dbPath + "-shm"))

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

    // MARK: - Open-Source Safety & P1/P2 Regression Tests

    func testHookInstallerRefusesToOverwriteInvalidJSONCAndBacksUpValidConfig() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("lumi-hook-safe-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let fakeExec = dir.appendingPathComponent("Lumi").path
        try "#!/bin/sh\nexit 0\n".write(toFile: fakeExec, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeExec)

        let config = HookInstaller.Config(
            homeDir: dir.path,
            nativeExecutablePath: fakeExec,
            fallbackPythonPath: nil,
            codexHome: dir.appendingPathComponent(".codex").path,
            claudeHome: dir.appendingPathComponent(".claude").path,
            t3Home: dir.appendingPathComponent(".t3").path
        )

        // 1. Existing JSONC with comments OR trailing comma MUST NOT be wiped or overwritten!
        try fm.createDirectory(atPath: config.claudeHome, withIntermediateDirectories: true)
        let trailingCommaJSON = "{\"permissions\": {\"allow\": [\"Bash\",]},}\n"
        try trailingCommaJSON.write(toFile: config.claudeSettingsPath, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try HookInstaller.install(for: .claude, config: config)) { err in
            XCTAssertEqual(err as? HookInstallerError, .invalidExistingJSON(path: config.claudeSettingsPath))
        }
        XCTAssertEqual(try String(contentsOfFile: config.claudeSettingsPath, encoding: .utf8), trailingCommaJSON)

        let jsonc = "// user comment\n{\"permissions\": {\"allow\": [\"Bash\"]},}\n"
        try jsonc.write(toFile: config.claudeSettingsPath, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try HookInstaller.install(for: .claude, config: config)) { err in
            XCTAssertEqual(err as? HookInstallerError, .invalidExistingJSON(path: config.claudeSettingsPath))
        }
        let after = try String(contentsOfFile: config.claudeSettingsPath, encoding: .utf8)
        XCTAssertEqual(after, jsonc)

        // Verify ownership check NEVER matches an unrelated third-party tool using `--hook --agent`
        XCTAssertFalse(HookInstaller.isLumiCommand("/usr/local/bin/other-tool --hook --agent claude Stop"))
        XCTAssertTrue(HookInstaller.isLumiCommand("\"/Applications/Lumi.app/Contents/MacOS/Lumi\" --hook --agent claude Stop"))
        XCTAssertTrue(HookInstaller.isLumiCommand("/usr/bin/python3 \"/Users/alice/.lumi/lumi-hook.py\" --agent claude Stop"))

        // 2. Valid JSON installs using native `--hook` (zero python3 dependency), preserves other hooks, and writes backup
        let validJSON = #"{"theme":"dark","hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo user"}]}]}}"#
        try validJSON.write(toFile: config.claudeSettingsPath, atomically: true, encoding: .utf8)

        try HookInstaller.install(for: .claude, config: config)
        XCTAssertTrue(HookInstaller.isInstalled(for: .claude, config: config))

        let installedText = try String(contentsOfFile: config.claudeSettingsPath, encoding: .utf8)
        XCTAssertTrue(installedText.contains("--hook --agent claude"))
        XCTAssertFalse(installedText.contains("/usr/bin/python3"))
        XCTAssertTrue(installedText.contains("echo user"))

        let backups = try fm.contentsOfDirectory(atPath: config.claudeHome).filter { $0.hasPrefix("settings.json.bak-") }
        XCTAssertFalse(backups.isEmpty)

        // 3. Uninstall removes ONLY Lumi hooks and keeps user's custom hook intact
        try HookInstaller.uninstall(for: .claude, config: config)
        XCTAssertFalse(HookInstaller.isInstalled(for: .claude, config: config))
        let uninstalledText = try String(contentsOfFile: config.claudeSettingsPath, encoding: .utf8)
        XCTAssertTrue(uninstalledText.contains("echo user"))
        XCTAssertFalse(uninstalledText.contains("--hook --agent claude"))
    }

    func testHookInstallerCursorFlatFormatAndOpenCodeOwnershipGuard() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("lumi-cursor-oc-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let fakeExec = dir.appendingPathComponent("Lumi").path
        try "#!/bin/sh\nexit 0\n".write(toFile: fakeExec, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeExec)

        let config = HookInstaller.Config(
            homeDir: dir.path,
            nativeExecutablePath: fakeExec,
            fallbackPythonPath: nil,
            codexHome: dir.appendingPathComponent(".codex").path,
            claudeHome: dir.appendingPathComponent(".claude").path,
            t3Home: dir.appendingPathComponent(".t3").path
        )

        // Cursor flat hooks.json format with version: 1 and passive afterShellExecution (never blocking beforeShellExecution)
        try HookInstaller.install(for: .cursor, config: config)
        let cursorData = try Data(contentsOf: URL(fileURLWithPath: config.cursorHooksPath))
        let cursorObj = try XCTUnwrap(try JSONSerialization.jsonObject(with: cursorData) as? [String: Any])
        XCTAssertEqual(cursorObj["version"] as? Int, 1)
        let cursorHooks = try XCTUnwrap(cursorObj["hooks"] as? [String: Any])
        XCTAssertNil(cursorHooks["beforeShellExecution"])
        XCTAssertNotNil(cursorHooks["afterShellExecution"])
        let submitList = try XCTUnwrap(cursorHooks["beforeSubmitPrompt"] as? [[String: Any]])
        XCTAssertEqual(submitList.count, 1)
        XCTAssertTrue((submitList[0]["command"] as? String ?? "").contains("--hook --agent cursor beforeSubmitPrompt"))
        XCTAssertNil(submitList[0]["hooks"]) // Must be flat, NOT nested Claude format

        try HookInstaller.uninstall(for: .cursor, config: config)
        XCTAssertFalse(HookInstaller.isInstalled(for: .cursor, config: config))

        // OpenCode ownership guard: refuse to delete foreign plugin file
        let ocDir = (config.openCodePluginPath as NSString).deletingLastPathComponent
        try fm.createDirectory(atPath: ocDir, withIntermediateDirectories: true)
        try "// custom user plugin\nexport default {};\n".write(toFile: config.openCodePluginPath, atomically: true, encoding: .utf8)
        XCTAssertFalse(HookInstaller.isInstalled(for: .opencode, config: config))
        XCTAssertThrowsError(try HookInstaller.uninstall(for: .opencode, config: config)) { err in
            XCTAssertEqual(err as? HookInstallerError, .foreignPluginFile(path: config.openCodePluginPath))
        }
        XCTAssertTrue(fm.fileExists(atPath: config.openCodePluginPath))

        // Remove foreign file, install Lumi OpenCode plugin -> uses native exec + session.status
        try fm.removeItem(atPath: config.openCodePluginPath)
        try HookInstaller.install(for: .opencode, config: config)
        XCTAssertTrue(HookInstaller.isInstalled(for: .opencode, config: config))
        let ocText = try String(contentsOfFile: config.openCodePluginPath, encoding: .utf8)
        XCTAssertTrue(ocText.contains("session.status"))
        XCTAssertTrue(ocText.contains(HookInstaller.openCodeOwnershipMarker))
        XCTAssertFalse(ocText.contains("/usr/bin/python3"))
        try HookInstaller.uninstall(for: .opencode, config: config)
        XCTAssertFalse(fm.fileExists(atPath: config.openCodePluginPath))
    }

    func testNativeHookRelayCursorOpenCodeStaleFieldClearingAndPermissions() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("lumi-relay-\(UUID().uuidString)")
        let liveDir = dir.appendingPathComponent("live").path
        defer { try? fm.removeItem(at: dir) }

        // 1. Cursor beforeSubmitPrompt -> {"continue":true}, legacy beforeShellExecution -> {"permission":"allow"}, stop(aborted) -> canceled
        let baseNow = Date().timeIntervalSince1970 - 300
        let submitPayload = #"{"conversation_id":"cur-1","prompt":"Refactor auth","workspace_roots":["/tmp/repo"]}"#.data(using: .utf8)!
        let r1 = NativeHookRelay.processPayload(agent: "cursor", eventArg: "beforeSubmitPrompt", stdinData: submitPayload, liveDir: liveDir, now: baseNow)
        XCTAssertEqual(r1.stdoutResponse, "{\"continue\":true}\n")
        let loaded1 = LiveHookRecord.loadAll(forAgent: "cursor", dir: liveDir)
        XCTAssertEqual(loaded1["cur-1"]?.state, "running")

        let shellPrePayload = #"{"conversation_id":"cur-1","command":"swift test"}"#.data(using: .utf8)!
        let rPreShell = NativeHookRelay.processPayload(agent: "cursor", eventArg: "beforeShellExecution", stdinData: shellPrePayload, liveDir: liveDir, now: baseNow + 2)
        XCTAssertEqual(rPreShell.stdoutResponse, "{\"permission\":\"allow\"}\n")

        let abortPayload = #"{"conversation_id":"cur-1","status":"aborted"}"#.data(using: .utf8)!
        let rAbort = NativeHookRelay.processPayload(agent: "cursor", eventArg: "stop", stdinData: abortPayload, liveDir: liveDir, now: baseNow + 10)
        XCTAssertEqual(rAbort.stdoutResponse, "{}\n")
        let loaded2 = LiveHookRecord.loadAll(forAgent: "cursor", dir: liveDir)
        XCTAssertEqual(loaded2["cur-1"]?.state, "canceled")

        // 2. OpenCode session.status busy -> idle -> new busy turn clears stale completedAt & durationSec
        let busy1 = #"{"session_id":"oc-1","status":{"type":"busy"},"cwd":"/tmp/oc"}"#.data(using: .utf8)!
        _ = NativeHookRelay.processPayload(agent: "opencode", eventArg: "session.status", stdinData: busy1, liveDir: liveDir, now: baseNow + 100)
        let idle1 = #"{"session_id":"oc-1","status":{"type":"idle"}}"#.data(using: .utf8)!
        _ = NativeHookRelay.processPayload(agent: "opencode", eventArg: "session.status", stdinData: idle1, liveDir: liveDir, now: baseNow + 125)
        let ocDone = LiveHookRecord.loadAll(forAgent: "opencode", dir: liveDir)["oc-1"]
        XCTAssertEqual(ocDone?.state, "done")
        XCTAssertEqual(ocDone?.durationSec ?? 0, 25.0, accuracy: 0.1)
        XCTAssertNotNil(ocDone?.completedAt)

        let busy2 = #"{"session_id":"oc-1","status":{"type":"busy"}}"#.data(using: .utf8)!
        let rBusy2 = NativeHookRelay.processPayload(agent: "opencode", eventArg: "session.status", stdinData: busy2, liveDir: liveDir, now: baseNow + 200)
        let ocRun2 = LiveHookRecord.loadAll(forAgent: "opencode", dir: liveDir)["oc-1"]
        XCTAssertEqual(ocRun2?.state, "running")
        XCTAssertNil(ocRun2?.completedAt)
        XCTAssertNil(ocRun2?.durationSec)

        // Verify strict 0700 dir / 0600 file permissions
        let dirAttrs = try fm.attributesOfItem(atPath: liveDir)
        XCTAssertEqual((dirAttrs[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        if let written = rBusy2.wrotePath {
            let fileAttrs = try fm.attributesOfItem(atPath: written)
            XCTAssertEqual((fileAttrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        }
    }

    func testUTF8MultibyteTailSplitPreservesCodexAndClaudeParsing() throws {
        // Construct a byte buffer that starts mid-UTF-8 character (continuation bytes 0xB5 0x8B from '测'),
        // followed by a newline and valid JSONL lines.
        var raw = Data([0xB5, 0x8B, 0x0A])
        let validLine = #"{"type":"event_msg","payload":{"type":"task_started","started_at":1770000000}}"# + "\n"
        raw.append(validLine.data(using: .utf8)!)
        let lines = FileTailReader.splitCompleteLines(from: raw, dropLeadingPartial: true)
        XCTAssertEqual(lines.count, 1)
        let now = Date()
        let parsed = CodexRolloutParser.parse(lines: lines, mtime: now, now: now)
        XCTAssertEqual(parsed.status, .running)

        // End-to-end ClaudeScanner test with >132KB file cutting across Chinese UTF-8 characters + hook cache separation
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("lumi-claude-utf8-\(UUID().uuidString)")
        let projDir = dir.appendingPathComponent("projA")
        try fm.createDirectory(at: projDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let transcript = projDir.appendingPathComponent("sess-zh.jsonl")
        let firstLine = #"{"type":"user","cwd":"/tmp/zh-app","message":{"content":"你好世界初始任务"}}"# + "\n"
        // Pad with 3-byte Chinese characters so file exceeds 131_072 bytes and tail offset slices mid-character
        let padUnit = #"{"type":"assistant","message":{"content":[{"type":"text","text":"中文填充内容测试文本数据"}]}}"# + "\n"
        var blob = Data(firstLine.utf8)
        while blob.count < 140_000 {
            blob.append(Data(padUnit.utf8))
        }
        let finalUser = #"{"type":"user","cwd":"/tmp/zh-app","message":{"content":"继续执行下一步"}}"# + "\n"
        blob.append(Data(finalUser.utf8))
        try blob.write(to: transcript)

        let scanner = ClaudeScanner(projectsDir: dir.path)
        let s1 = scanner.scan(lookbackHours: 24, now: now, preloadedHooks: [:])
        XCTAssertEqual(s1.count, 1)
        XCTAssertEqual(s1.first?.status, .running)
        XCTAssertEqual(s1.first?.title, "你好世界初始任务")

        // Overlay a needs_input hook, then remove it -> status must return to transcript status cleanly
        let hook = LiveHookRecord(
            agent: "claude", sessionId: "sess-zh", event: "NeedsInput", state: "needs_input",
            action: "等待确认 · rm", lastToolLabel: "", title: "", lastUserInput: "", firstUserInput: "",
            cwd: "/tmp/zh-app", workspacePaths: [], terminationReason: "", error: "",
            updatedAt: now.addingTimeInterval(2), turnStartedAt: now, completedAt: nil, durationSec: nil
        )
        let s2 = scanner.scan(lookbackHours: 24, now: now.addingTimeInterval(3), preloadedHooks: ["sess-zh": hook])
        XCTAssertEqual(s2.first?.status, .needsInput)
        XCTAssertNil(s2.first?.completedAt)

        let s3 = scanner.scan(lookbackHours: 24, now: now.addingTimeInterval(4), preloadedHooks: [:])
        XCTAssertEqual(s3.first?.status, .running)
    }

    func testCodexScannerRollsUpSubagentNeedsInputWithoutCompletedAt() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("lumi-codex-sub-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let now = Date()
        let ts = Int64(now.timeIntervalSince1970)
        let parentRollout = dir.appendingPathComponent("parent.jsonl").path
        let childRollout = dir.appendingPathComponent("child.jsonl").path

        try (#"{"type":"event_msg","payload":{"type":"task_started","started_at":\#(ts - 20)}}"# + "\n"
             + #"{"type":"event_msg","payload":{"type":"task_complete","completed_at":\#(ts - 5)}}"# + "\n")
            .write(toFile: parentRollout, atomically: true, encoding: .utf8)
        try (#"{"type":"event_msg","payload":{"type":"task_started","started_at":\#(ts - 10)}}"# + "\n"
             + #"{"type":"event_msg","payload":{"type":"exec_approval_request","command":"git push"}}"# + "\n")
            .write(toFile: childRollout, atomically: true, encoding: .utf8)

        let dbPath = dir.appendingPathComponent("state_5.sqlite").path
        var rawDB: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbPath, &rawDB), SQLITE_OK)
        let sql = """
        PRAGMA journal_mode=WAL;
        CREATE TABLE thread_spawn_edges (parent_thread_id TEXT, child_thread_id TEXT);
        CREATE TABLE threads (
            id TEXT PRIMARY KEY, rollout_path TEXT, updated_at INTEGER, cwd TEXT,
            title TEXT, first_user_message TEXT, agent_nickname TEXT, source TEXT, archived INTEGER
        );
        INSERT INTO thread_spawn_edges VALUES ('p-1', 'c-1');
        INSERT INTO threads VALUES ('p-1', '\(parentRollout)', \(ts), '/tmp/proj', 'Parent Task', '', '', 'desktop', 0);
        INSERT INTO threads VALUES ('c-1', '\(childRollout)', \(ts), '/tmp/proj', 'Child Task', '', 'helper', 'subagent', 0);
        """
        XCTAssertEqual(sqlite3_exec(rawDB, sql, nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_close(rawDB), SQLITE_OK)

        let scanner = CodexScanner(stateDBPath: dbPath, sessionIndexPath: dir.appendingPathComponent("idx.jsonl").path)
        let sessions = scanner.scan(lookbackHours: 24, now: now, preloadedHooks: [:])
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.rawId, "p-1")
        XCTAssertEqual(sessions.first?.status, .needsInput)
        XCTAssertNil(sessions.first?.completedAt)
        XCTAssertEqual(sessions.first?.activeSubagents, 1)
    }

    func testT3CodeScannerPreservesOlderActiveRootPastLimitAndAvoidsOverDedupe() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("lumi-t3-limit-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let dbPath = dir.appendingPathComponent("statev2.sqlite").path
        var rawDB: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbPath, &rawDB), SQLITE_OK)

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let now = Date()

        var sql = """
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
        INSERT INTO projection_projects VALUES ('p1', 'BigRepo', '/tmp/BigRepo');
        """

        // Insert 105 newer completed threads to exceed LIMIT 100
        for i in 0..<105 {
            let t = iso.string(from: now.addingTimeInterval(Double(-10 - i)))
            sql += "\nINSERT INTO orchestration_v2_projection_threads VALUES ('done-\(i)', 'p1', 'Done \(i)', 'codex', '\(t)', '\(t)', NULL, NULL, '{}');"
            sql += "\nINSERT INTO orchestration_v2_projection_runs VALUES ('r-done-\(i)', 'done-\(i)', 1, 'codex', 'completed', '\(t)', '\(t)', '{}');"
        }
        // Insert 1 older ACTIVE root thread (updated 500s ago -> would be dropped by naive LIMIT 100!)
        let oldT = iso.string(from: now.addingTimeInterval(-500))
        sql += "\nINSERT INTO orchestration_v2_projection_threads VALUES ('older-active-root', 'p1', 'Long Running Root', 'codex', '\(oldT)', '\(oldT)', NULL, NULL, '{}');"
        sql += "\nINSERT INTO orchestration_v2_projection_runs VALUES ('r-old-active', 'older-active-root', 1, 'codex', 'running', '\(oldT)', NULL, '{}');"

        // Insert 1 ARCHIVED thread with nativeThreadRef -> must NOT suppress standalone Codex
        sql += "\nINSERT INTO orchestration_v2_projection_threads VALUES ('archived-th', 'p1', 'Archived', 'codex', '\(oldT)', '\(oldT)', '\(oldT)', NULL, '{}');"
        sql += "\nINSERT INTO orchestration_v2_projection_runs VALUES ('r-arch', 'archived-th', 1, 'codex', 'completed', '\(oldT)', '\(oldT)', '{}');"
        sql += "\nINSERT INTO orchestration_v2_projection_provider_threads VALUES ('pt-arch', 'archived-th', 'codex', '{\"nativeThreadRef\":{\"driver\":\"codex\",\"nativeId\":\"archived-codex-id\"}}');"

        XCTAssertEqual(sqlite3_exec(rawDB, sql, nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_close(rawDB), SQLITE_OK)

        let scanner = T3CodeScanner(v2DbPath: dbPath, v1DbPath: dir.appendingPathComponent("none.sqlite").path, isT3RunningCheck: { true })
        let res = scanner.scanDetailed(lookbackHours: 24, now: now)
        XCTAssertTrue(res.sessions.contains { $0.rawId == "older-active-root" && $0.status == .running })

        let archivedCodex = AgentSession(
            id: "codex:archived-codex-id", rawId: "archived-codex-id", kind: .codex, title: "Archived",
            project: "BigRepo", cwd: "/tmp/BigRepo", isCLI: false, status: .done, currentAction: "已完成",
            detailSummary: "", startedAt: nil, updatedAt: now, completedAt: now, durationSec: nil,
            activeSubagents: 0, isUnread: false
        )
        XCTAssertFalse(res.ownsUnderlying(archivedCodex, now: now))

        // Empty T3 result MUST NOT suppress scratch directory sessions
        let emptyRes = T3CodeScanResult(sessions: [], ownedNativeSessionIds: [], pendingMatches: [])
        let scratchSession = AgentSession(
            id: "codex:only-copy", rawId: "only-copy", kind: .codex, title: "Scratch",
            project: "Scratch", cwd: "/Users/test/.t3/scratch/demo", isCLI: false, status: .running,
            currentAction: "执行中…", detailSummary: "", startedAt: now, updatedAt: now, completedAt: nil,
            durationSec: nil, activeSubagents: 0, isUnread: false
        )
        XCTAssertFalse(emptyRes.ownsUnderlying(scratchSession, now: now))
    }

    func testGeminiDesktopScannerPreventsRenamePhantomAndObservationLossAlerts() {
        final class MockGeminiEnv: @unchecked Sendable {
            var currentObs: GeminiDesktopScanner.WindowObservation = .ok([])
            var appRunning = true
        }
        let env = MockGeminiEnv()
        let scanner = GeminiDesktopScanner(
            cachesRoot: "/tmp/nonexistent-gemini-cache-\(UUID().uuidString)",
            runningAppProvider: { env.appRunning ? (pid: 999, isActive: true) : nil },
            windowObserver: { _ in env.currentObs }
        )

        let t0 = Date()
        // Tick 1: New untitled chat starts generating
        env.currentObs = .ok([
            GeminiDesktopScanner.InspectedWindow(title: "", status: .running, action: "生成回答中…", sidebarTasks: [], sawSidebar: true)
        ])
        let s1 = scanner.scan(lookbackHours: 24, now: t0)
        XCTAssertEqual(s1.count, 1)
        XCTAssertEqual(s1.first?.status, .running)

        // Tick 2: Gemini assigns real title 3s later -> MUST migrate cleanly with zero phantom `.done`!
        env.currentObs = .ok([
            GeminiDesktopScanner.InspectedWindow(title: "Swift Concurrency Guide", status: .running, action: "生成回答中…", sidebarTasks: [], sawSidebar: true)
        ])
        let s2 = scanner.scan(lookbackHours: 24, now: t0.addingTimeInterval(3))
        XCTAssertEqual(s2.count, 1)
        XCTAssertEqual(s2.first?.title, "Swift Concurrency Guide")
        XCTAssertEqual(s2.first?.status, .running)
        XCTAssertFalse(s2.contains { $0.status == .done })

        // Tick 3: Accessibility permission temporarily unavailable -> MUST NOT fabricate `.done`!
        env.currentObs = .unavailable
        let s3 = scanner.scan(lookbackHours: 24, now: t0.addingTimeInterval(6))
        XCTAssertEqual(s3.count, 1)
        XCTAssertEqual(s3.first?.status, .running)

        // Tick 4: Sidebar reveals an old historical Ready task -> MUST NOT stamp `now`!
        env.currentObs = .ok([
            GeminiDesktopScanner.InspectedWindow(
                title: "Swift Concurrency Guide",
                status: .running,
                action: "生成回答中…",
                sidebarTasks: [GeminiSidebarTask(title: "Old Completed Task", status: .done, action: "任务已完成")],
                sawSidebar: true
            )
        ])
        let t4 = t0.addingTimeInterval(9)
        let s4 = scanner.scan(lookbackHours: 24, now: t4)
        let oldReady = s4.first { $0.title == "Old Completed Task" }
        XCTAssertNotNil(oldReady)
        XCTAssertTrue(t4.timeIntervalSince(oldReady?.completedAt ?? t4) > 600)

        // Tick 5: Active chat transitions cleanly to idle -> genuine `.done` with `completedAt == t5`!
        env.currentObs = .ok([
            GeminiDesktopScanner.InspectedWindow(title: "Swift Concurrency Guide", status: .done, action: "已完成", sidebarTasks: [], sawSidebar: true)
        ])
        let t5 = t0.addingTimeInterval(12)
        let s5 = scanner.scan(lookbackHours: 24, now: t5)
        let doneChat = s5.first { $0.title == "Swift Concurrency Guide" }
        XCTAssertEqual(doneChat?.status, .done)
        XCTAssertEqual(doneChat?.completedAt, t5)

        // Tick 6: Start another chat then quit Gemini -> MUST NOT emit fake `.done`!
        env.currentObs = .ok([
            GeminiDesktopScanner.InspectedWindow(title: "Aborted Chat", status: .running, action: "生成回答中…", sidebarTasks: [], sawSidebar: false)
        ])
        _ = scanner.scan(lookbackHours: 24, now: t0.addingTimeInterval(15))
        env.appRunning = false
        let sQuit = scanner.scan(lookbackHours: 24, now: t0.addingTimeInterval(18))
        XCTAssertNil(sQuit.first { $0.title == "Aborted Chat" })

        // Verify collision-safe keys for long titles sharing a 72-char prefix
        let prefix72 = String(repeating: "a", count: 72)
        XCTAssertNotEqual(
            GeminiDesktopClassifier.normalizedKey(from: prefix72 + "-one"),
            GeminiDesktopClassifier.normalizedKey(from: prefix72 + "-two")
        )

        // Verify multi-locale matching (e.g., Japanese locale strings)
        let jpLocale = GeminiLocaleStrings(
            nonChatWindowTitles: ["使用量の上限"],
            bareChatTitles: ["gemini"],
            titlePrefixes: ["Gemini - "],
            stopResponseButtons: ["応答を停止"],
            stopTaskButtons: ["タスクを停止"],
            strongApproveButtons: ["1 回のみ許可"],
            dismissButtons: ["今はしない"],
            waitingTexts: [],
            runningTaskTexts: [],
            runningResponseTexts: [],
            sidebarInProgress: ["進行中"],
            sidebarNeedsAttention: ["要確認"],
            sidebarReady: ["準備完了"],
            sidebarPinned: ["固定済み"]
        )
        XCTAssertEqual(
            GeminiDesktopClassifier.classifyWindow(
                buttons: [GeminiAXButton(identifier: "", title: "", description: "応答を停止")],
                statusTexts: [],
                locale: jpLocale
            ).status,
            .running
        )
        XCTAssertEqual(GeminiDesktopClassifier.parseSidebarTaskRow("「設計メモ」、進行中", locale: jpLocale)?.status, .running)
        XCTAssertNil(GeminiDesktopClassifier.extractChatTitle(fromWindowTitle: "使用量の上限", locale: jpLocale))
    }

    func testFastISO8601ParserRejectsInvalidCivilDatesAndOffsets() {
        XCTAssertNil(FastISO8601Parser.parse("2026-02-30T12:00:00Z"))
        XCTAssertNil(FastISO8601Parser.parse("2026-04-31T12:00:00Z"))
        XCTAssertNil(FastISO8601Parser.parse("2025-02-29T12:00:00Z"))
        XCTAssertNil(FastISO8601Parser.parse("2026-01-01T00:00:00+25:00"))
        XCTAssertNil(FastISO8601Parser.parse("2026-01-01T00:00:00+08:99"))
        XCTAssertNotNil(FastISO8601Parser.parse("2024-02-29T23:59:59Z"))
        XCTAssertNotNil(FastISO8601Parser.parse("2026-11-23 12:30:45", allowBareUTC: true))
        XCTAssertNil(FastISO8601Parser.parse("2026-11-23 12:30:45", allowBareUTC: false))
    }

    func testUpdateCheckerBuildMetadataPrereleaseAndURLValidation() {
        XCTAssertFalse(UpdateChecker.isNewer("v1.3.0+build9", than: "1.3.0"))
        XCTAssertTrue(UpdateChecker.isNewer("v1.4.0", than: "1.4.0-beta.1"))
        XCTAssertFalse(UpdateChecker.isNewer("v1.4.0-beta.1", than: "1.4.0"))
        XCTAssertEqual(
            UpdateChecker.validatedReleaseURL(from: "https://github.com/kf953741/lumi/releases/tag/v1.4.0").absoluteString,
            "https://github.com/kf953741/lumi/releases/tag/v1.4.0"
        )
        XCTAssertEqual(
            UpdateChecker.validatedReleaseURL(from: "http://evil.example.com/lumi.dmg").absoluteString,
            "https://github.com/kf953741/lumi/releases"
        )
    }

    func testSQLiteReaderUsesStrictReadOnlyOnActiveWALDatabase() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("lumi-wal-ro-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let dbPath = dir.appendingPathComponent("active.db").path
        var writerDB: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbPath, &writerDB), SQLITE_OK)
        defer { if let writerDB { sqlite3_close(writerDB) } }

        XCTAssertEqual(
            sqlite3_exec(writerDB, "PRAGMA journal_mode=WAL; CREATE TABLE t(v TEXT); INSERT INTO t VALUES ('live');", nil, nil, nil),
            SQLITE_OK
        )
        XCTAssertTrue(fm.fileExists(atPath: dbPath + "-wal"))
        XCTAssertTrue(fm.fileExists(atPath: dbPath + "-shm"))

        guard let reader = SQLiteReader(path: dbPath) else {
            XCTFail("Failed to open active WAL DB")
            return
        }
        XCTAssertTrue(reader.openedReadOnly)
        var vals: [String] = []
        let ok = reader.withReadTransaction {
            reader.query("SELECT v FROM t;") { stmt in
                vals.append(SQLiteReader.string(stmt, 0))
            }
        }
        XCTAssertEqual(ok, true)
        XCTAssertEqual(vals, ["live"])
    }

    @MainActor
    func testMonitorStoreNotificationAckTimestampDoesNotClearNewerCompletion() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("lumi-store-ack-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let store = MonitorStore(
            statePath: dir.appendingPathComponent("read_state.json").path,
            suppressSystemSideEffects: true
        )
        let t0 = Date()
        let firstDone = AgentSession(
            id: "codex:t1", rawId: "t1", kind: .codex, title: "Turn 1",
            project: "Repo", cwd: "/tmp/repo", isCLI: false, status: .done,
            currentAction: "已完成", detailSummary: "", startedAt: t0.addingTimeInterval(-30),
            updatedAt: t0, completedAt: t0, durationSec: 30, activeSubagents: 0, isUnread: false
        )
        // Initial scan
        store.applyScanned([firstDone], now: t0)

        // Newer turn finishes 60s later
        let t2 = t0.addingTimeInterval(60)
        let secondDone = AgentSession(
            id: "codex:t1", rawId: "t1", kind: .codex, title: "Turn 2",
            project: "Repo", cwd: "/tmp/repo", isCLI: false, status: .done,
            currentAction: "已完成", detailSummary: "", startedAt: t0.addingTimeInterval(40),
            updatedAt: t2, completedAt: t2, durationSec: 20, activeSubagents: 0, isUnread: false
        )
        store.applyScanned([secondDone], now: t2)
        // Wait past settle window
        store.applyScanned([secondDone], now: t2.addingTimeInterval(6))
        XCTAssertEqual(store.totalUnreadCount, 1)

        // Clicking an OLD notification banner from Turn 1 (`upTo: t0`) MUST NOT clear Turn 2!
        store.markRead(byId: "codex:t1", upTo: t0.timeIntervalSince1970)
        XCTAssertEqual(store.totalUnreadCount, 1)

        // Clicking Turn 2's notification (`upTo: t2`) cleanly marks it read
        store.markRead(byId: "codex:t1", upTo: t2.timeIntervalSince1970)
        XCTAssertEqual(store.totalUnreadCount, 0)
    }

    @MainActor
    func testMonitorStoreErrorOnlyDoesNotCelebrateAndMissingScanClearsPendingSettle() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("lumi-store-err-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let store = MonitorStore(
            statePath: dir.appendingPathComponent("read_state.json").path,
            suppressSystemSideEffects: true
        )
        let t0 = Date()
        let running = AgentSession(
            id: "codex:e1", rawId: "e1", kind: .codex, title: "Build",
            project: "Repo", cwd: "/tmp/repo", isCLI: false, status: .running,
            currentAction: "执行中…", detailSummary: "", startedAt: t0,
            updatedAt: t0, completedAt: nil, durationSec: nil, activeSubagents: 0, isUnread: false
        )
        store.applyScanned([running], now: t0)

        // Transition to error and settle -> mascot mood MUST be `.error`, NOT `.celebrating`!
        let failed = AgentSession(
            id: "codex:e1", rawId: "e1", kind: .codex, title: "Build",
            project: "Repo", cwd: "/tmp/repo", isCLI: false, status: .error,
            currentAction: "执行出错", detailSummary: "", startedAt: t0,
            updatedAt: t0.addingTimeInterval(5), completedAt: t0.addingTimeInterval(5),
            durationSec: 5, activeSubagents: 0, isUnread: false
        )
        store.applyScanned([failed], now: t0.addingTimeInterval(5))
        // Session disappears mid-settle -> pending settle timer MUST be cleared (reappearing must restart settle!)
        store.applyScanned([], now: t0.addingTimeInterval(11))
        store.applyScanned([failed], now: t0.addingTimeInterval(12))
        // Because settle restarted at t0+12, it should still be settling (not unread yet)!
        XCTAssertEqual(store.totalUnreadCount, 0)

        // After full settle window from t0+12, error becomes unread and mood is `.error` (not `.celebrating`)
        store.applyScanned([failed], now: t0.addingTimeInterval(18))
        XCTAssertEqual(store.totalUnreadCount, 1)
        XCTAssertEqual(store.mascotMood, .error)
    }

    func testExtraAgentsSkipsIdleHooksAndUpdateCheckerRejectsInvalidTag() {
        let now = Date()
        let idleHook = LiveHookRecord(
            agent: "cursor", sessionId: "idle-1", event: "SessionStart", state: "idle",
            action: "", lastToolLabel: "", title: "Fresh", lastUserInput: "", firstUserInput: "",
            cwd: "/tmp/r", workspacePaths: [], terminationReason: "", error: "",
            updatedAt: now, turnStartedAt: nil, completedAt: nil, durationSec: nil
        )
        let extra = ExtraAgentsScanner()
        let sessions = extra.scan(lookbackHours: 24, preloadedHooksByAgent: ["cursor": ["idle-1": idleHook]])
        XCTAssertTrue(sessions.isEmpty)

        XCTAssertFalse(UpdateChecker.isValidVersionTag("nightly"))
        XCTAssertFalse(UpdateChecker.isValidVersionTag("v1.bad.0"))
        XCTAssertTrue(UpdateChecker.isValidVersionTag("v1.4.0+build.2"))
    }

    func testGeminiSidebarNeedsAttentionOverridesIdleOpenWindow() {
        let scanner = GeminiDesktopScanner(
            cachesRoot: "/tmp/nonexistent-gemini-\(UUID().uuidString)",
            runningAppProvider: { (pid: 777, isActive: true) },
            windowObserver: { _ in
                .ok([
                    GeminiDesktopScanner.InspectedWindow(
                        title: "Deploy Task",
                        status: .done,
                        action: "已完成",
                        sidebarTasks: [GeminiSidebarTask(title: "Deploy Task", status: .needsInput, action: "需要你的确认或协助")],
                        sawSidebar: true
                    )
                ])
            }
        )
        let sessions = scanner.scan(lookbackHours: 24, now: Date())
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.status, .needsInput)
    }

    func testGeminiScrolledOutSidebarTaskExpiresSilentlyWithoutFakeDone() {
        final class ScrollEnv: @unchecked Sendable {
            var obs: GeminiDesktopScanner.WindowObservation = .ok([])
        }
        let env = ScrollEnv()
        let scanner = GeminiDesktopScanner(
            cachesRoot: "/tmp/nonexistent-gemini-scroll-\(UUID().uuidString)",
            runningAppProvider: { (pid: 888, isActive: true) },
            windowObserver: { _ in env.obs }
        )
        let t0 = Date()
        env.obs = .ok([
            GeminiDesktopScanner.InspectedWindow(
                title: "Other Open Chat", status: .done, action: "已完成",
                sidebarTasks: [GeminiSidebarTask(title: "Scrolled Task", status: .running, action: "后台任务进行中…")],
                sawSidebar: true
            )
        ])
        XCTAssertEqual(scanner.scan(lookbackHours: 24, now: t0).first?.status, .running)

        // Task scrolls out of visible sidebar while sidebar remains visible -> MUST NOT become `.done`!
        env.obs = .ok([
            GeminiDesktopScanner.InspectedWindow(
                title: "Other Open Chat", status: .done, action: "已完成",
                sidebarTasks: [], sawSidebar: true
            )
        ])
        let mid = scanner.scan(lookbackHours: 24, now: t0.addingTimeInterval(3))
        XCTAssertFalse(mid.contains { $0.title == "Scrolled Task" && $0.status == .done })
        let expired = scanner.scan(lookbackHours: 24, now: t0.addingTimeInterval(20))
        XCTAssertNil(expired.first { $0.title == "Scrolled Task" })
    }

    func testCodexThreadSettingsAppliedOnOldThreadDoesNotResurrectAsUnread() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("lumi-codex-settings-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let now = Date()
        let monthAgoTs = Int64(now.addingTimeInterval(-26 * 86400).timeIntervalSince1970)
        let nowTs = Int64(now.timeIntervalSince1970)

        // Rollout completed 26 days ago, then Codex Desktop appended `thread_settings_applied` today
        let rolloutPath = dir.appendingPathComponent("old-rollout.jsonl").path
        let content = """
        {"timestamp":"2026-10-28T09:22:50.086Z","type":"event_msg","payload":{"type":"task_complete","completed_at":\(monthAgoTs),"started_at":\(monthAgoTs - 1582),"duration_ms":1582000}}
        {"timestamp":"2026-11-23T07:22:48.558Z","type":"event_msg","payload":{"type":"thread_settings_applied","thread_id":"old-1"}}
        """
        try content.write(toFile: rolloutPath, atomically: true, encoding: .utf8)

        let dbPath = dir.appendingPathComponent("state_5.sqlite").path
        var rawDB: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbPath, &rawDB), SQLITE_OK)
        let sql = """
        PRAGMA journal_mode=WAL;
        CREATE TABLE thread_spawn_edges (parent_thread_id TEXT, child_thread_id TEXT);
        CREATE TABLE threads (
            id TEXT PRIMARY KEY, rollout_path TEXT, updated_at INTEGER, cwd TEXT,
            title TEXT, first_user_message TEXT, agent_nickname TEXT, source TEXT, archived INTEGER
        );
        INSERT INTO threads VALUES ('old-1', '\(rolloutPath)', \(nowTs), '/tmp/lia', '5090 g0.5 piper', '', '', 'vscode', 0);
        """
        XCTAssertEqual(sqlite3_exec(rawDB, sql, nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_close(rawDB), SQLITE_OK)

        let scanner = CodexScanner(stateDBPath: dbPath, sessionIndexPath: dir.appendingPathComponent("idx.jsonl").path)
        let sessions = scanner.scan(lookbackHours: 24, now: now, preloadedHooks: [:])
        // Must be filtered out completely since real task_complete was 26 days ago!
        XCTAssertTrue(sessions.isEmpty)

        // Also verify metadata-only tail (without task_complete in tail) never triggers false `.running`
        let metaOnlyLines = [#"{"timestamp":"2026-11-23T07:22:48.558Z","type":"event_msg","payload":{"type":"thread_settings_applied","thread_id":"old-2"}}"#]
        let metaState = CodexRolloutParser.parse(lines: metaOnlyLines, mtime: now, now: now)
        XCTAssertEqual(metaState.status, .done)
        XCTAssertNil(metaState.completedAt)
    }

    @MainActor
    func testMonitorStoreDoesNotResurrectAckedOldSessionAfterPruneOrMidSessionAppear() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("lumi-store-prune-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let store = MonitorStore(
            statePath: dir.appendingPathComponent("read_state.json").path,
            suppressSystemSideEffects: true
        )
        let t0 = Date()
        let monthAgo = t0.addingTimeInterval(-26 * 86400)
        let oldSession = AgentSession(
            id: "codex:old-ghost", rawId: "old-ghost", kind: .codex, title: "Old Ghost",
            project: "lia", cwd: "/tmp/lia", isCLI: false, status: .done,
            currentAction: "已完成", detailSummary: "", startedAt: monthAgo.addingTimeInterval(-60),
            updatedAt: monthAgo, completedAt: monthAgo, durationSec: 60, activeSubagents: 0, isUnread: false
        )

        // Initial scan with empty list, then old session appears mid-session -> MUST auto-ack, NOT become unread!
        store.applyScanned([], now: t0)
        store.applyScanned([oldSession], now: t0.addingTimeInterval(5))
        XCTAssertEqual(store.totalUnreadCount, 0)

        // Advance past the 600s pruner interval -> ack MUST be preserved while session is active, NEVER resurrecting as unread!
        store.applyScanned([oldSession], now: t0.addingTimeInterval(700))
        store.applyScanned([oldSession], now: t0.addingTimeInterval(702))
        XCTAssertEqual(store.totalUnreadCount, 0)
    }

    func testT3CodeV2PendingBackgroundTasksSubagentsAndRuntimeRequests() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("lumi-t3-p0-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let dbPath = dir.appendingPathComponent("statev2.sqlite").path
        var rawDB: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbPath, &rawDB), SQLITE_OK)

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let now = Date()
        let tStart = iso.string(from: now.addingTimeInterval(-60))
        let tRecent = iso.string(from: now.addingTimeInterval(-10))
        let tOld = iso.string(from: now.addingTimeInterval(-500))

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
            provider_thread_id TEXT PRIMARY KEY, thread_id TEXT NOT NULL, provider TEXT NOT NULL, payload_json TEXT NOT NULL
        );
        CREATE INDEX orchestration_v2_projection_provider_threads_pending_tasks_idx
            ON orchestration_v2_projection_provider_threads(thread_id)
            WHERE CASE WHEN json_valid(payload_json) THEN json_array_length(payload_json, '$.pendingBackgroundTasks') > 0 ELSE 0 END;
        CREATE TABLE orchestration_v2_projection_subagents (
            subagent_id TEXT PRIMARY KEY, thread_id TEXT NOT NULL, run_id TEXT, provider_thread_id TEXT,
            provider_instance_id TEXT, child_thread_id TEXT, status TEXT NOT NULL,
            completion_delivery_state TEXT, started_at TEXT, updated_at TEXT
        );
        CREATE TABLE orchestration_v2_projection_runtime_requests (
            runtime_request_id TEXT PRIMARY KEY, thread_id TEXT NOT NULL, node_id TEXT,
            provider_turn_id TEXT, kind TEXT NOT NULL, status TEXT NOT NULL,
            created_at TEXT NOT NULL, resolved_at TEXT, payload_json TEXT NOT NULL
        );
        CREATE INDEX orchestration_v2_projection_requests_recovery_idx
            ON orchestration_v2_projection_runtime_requests(thread_id) WHERE status = 'pending';
        CREATE INDEX orchestration_v2_projection_nodes_thread_run_idx
            ON orchestration_v2_projection_nodes(thread_id, run_id);
        CREATE TABLE provider_session_runtime (thread_id TEXT PRIMARY KEY, provider_name TEXT, status TEXT NOT NULL, resume_cursor_json TEXT);

        INSERT INTO projection_projects VALUES ('p1', 'LumiApp', '/Users/test/lumi');

        -- 1. Thread with awaited command in pendingBackgroundTasks -> MUST stay running
        INSERT INTO orchestration_v2_projection_threads VALUES
            ('th-bg-awaited', 'p1', 'Build in bg', 'claude', '\(tStart)', '\(tRecent)', NULL, NULL,
             '{"activeProviderThreadId":"pt-bg-1","providerInstanceId":"claude"}');
        INSERT INTO orchestration_v2_projection_runs VALUES
            ('r-bg-1', 'th-bg-awaited', 1, 'claude', 'completed', '\(tStart)', '\(tRecent)', '{}');
        INSERT INTO orchestration_v2_projection_provider_threads VALUES
            ('pt-bg-1', 'th-bg-awaited', 'claude',
             '{"providerInstanceId":"claude","updatedAt":"\(tRecent)","pendingBackgroundTasks":[{"taskId":"t1","kind":"command","awaited":true}]}');

        -- 2. Thread with NON-awaited command daemon in pendingBackgroundTasks -> MUST be done
        INSERT INTO orchestration_v2_projection_threads VALUES
            ('th-bg-daemon', 'p1', 'Dev server', 'claude', '\(tStart)', '\(tRecent)', NULL, NULL,
             '{"activeProviderThreadId":"pt-bg-2","providerInstanceId":"claude"}');
        INSERT INTO orchestration_v2_projection_runs VALUES
            ('r-bg-2', 'th-bg-daemon', 1, 'claude', 'completed', '\(tStart)', '\(tRecent)', '{}');
        INSERT INTO orchestration_v2_projection_provider_threads VALUES
            ('pt-bg-2', 'th-bg-daemon', 'claude',
             '{"providerInstanceId":"claude","updatedAt":"\(tRecent)","pendingBackgroundTasks":[{"taskId":"t2","kind":"command"}]}');

        -- 3. Thread with undelivered subagent completion (`completion_delivery_state = pending`, blank provider_thread_id matching run_id) -> MUST stay running
        INSERT INTO orchestration_v2_projection_threads VALUES
            ('th-sub-pend', 'p1', 'Delegated work', 'codex', '\(tStart)', '\(tRecent)', NULL, NULL,
             '{"activeProviderThreadId":"pt-sub-1","providerInstanceId":"codex"}');
        INSERT INTO orchestration_v2_projection_runs VALUES
            ('r-sub-1', 'th-sub-pend', 1, 'codex', 'completed', '\(tStart)', '\(tRecent)', '{}');
        INSERT INTO orchestration_v2_projection_subagents VALUES
            ('sub-1', 'th-sub-pend', 'r-sub-1', '', 'codex', '', 'completed', 'pending', '\(tStart)', '\(tRecent)');

        -- 4. Thread with bare run.status = 'waiting' and non-actionable dynamic_tool_call request -> MUST be .running (NOT .needsInput!)
        INSERT INTO orchestration_v2_projection_threads VALUES
            ('th-blip', 'p1', 'Waiting blip', 'antigravity', '\(tStart)', '\(tRecent)', NULL, NULL, '{}');
        INSERT INTO orchestration_v2_projection_runs VALUES
            ('r-blip', 'th-blip', 1, 'antigravity', 'waiting', '\(tStart)', NULL, '{}');
        INSERT INTO orchestration_v2_projection_runtime_requests VALUES
            ('req-dyn', 'th-blip', 'n1', 'pt1', 'dynamic_tool_call', 'pending', '\(tRecent)', NULL, '{"prompt":"internal"}');

        -- 5. Thread with real pending command approval runtime_request -> MUST be .needsInput!
        INSERT INTO orchestration_v2_projection_threads VALUES
            ('th-appr', 'p1', 'Needs approval', 'claude', '\(tStart)', '\(tRecent)', NULL, NULL, '{}');
        INSERT INTO orchestration_v2_projection_runs VALUES
            ('r-appr', 'th-appr', 1, 'claude', 'waiting', '\(tStart)', NULL, '{}');
        INSERT INTO orchestration_v2_projection_runtime_requests VALUES
            ('req-cmd', 'th-appr', 'n2', 'pt2', 'command', 'pending', '\(tRecent)', NULL,
             '{"command":"rm -rf build","responseCapability":{"type":"interactive"}}');
        """

        // Verify exact partial-index query hits `orchestration_v2_projection_provider_threads_pending_tasks_idx`!
        XCTAssertEqual(sqlite3_exec(rawDB, sql, nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_close(rawDB), SQLITE_OK)

        let reader = try XCTUnwrap(SQLiteReader(path: dbPath))
        var planLines: [String] = []
        _ = reader.query("""
            EXPLAIN QUERY PLAN
            SELECT thread_id, provider_thread_id, provider, payload_json
            FROM orchestration_v2_projection_provider_threads
            WHERE CASE WHEN json_valid(payload_json) THEN json_array_length(payload_json, '$.pendingBackgroundTasks') > 0 ELSE 0 END;
            """) { stmt in
            planLines.append(SQLiteReader.string(stmt, 3))
        }
        XCTAssertTrue(planLines.joined(separator: " ").contains("orchestration_v2_projection_provider_threads_pending_tasks_idx"))

        let scanner = T3CodeScanner(v2DbPath: dbPath, v1DbPath: dir.appendingPathComponent("none.sqlite").path, isT3RunningCheck: { true })
        let sessions = scanner.scan(lookbackHours: 24, now: now)

        XCTAssertEqual(sessions.first(where: { $0.rawId == "th-bg-awaited" })?.status, .running)
        XCTAssertEqual(sessions.first(where: { $0.rawId == "th-bg-daemon" })?.status, .done)
        XCTAssertEqual(sessions.first(where: { $0.rawId == "th-sub-pend" })?.status, .running)
        XCTAssertEqual(sessions.first(where: { $0.rawId == "th-blip" })?.status, .running)
        let appr = try XCTUnwrap(sessions.first(where: { $0.rawId == "th-appr" }))
        XCTAssertEqual(appr.status, .needsInput)
        XCTAssertTrue(appr.currentAction.contains("rm -rf build"))
        _ = tOld
    }

    @MainActor
    func testT3CodeV2AntigravityHandoffGraceReplaysRun32AndRun33WithoutPrematurePopup() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("lumi-t3-handoff-\(UUID().uuidString)")
        let providersRoot = dir.appendingPathComponent("providers/antigravity").path
        let subagentsDir = "\(providersRoot)/profile1/antigravity-acp/brain/parent-conv-33/.system_generated/subagents"
        try fm.createDirectory(atPath: subagentsDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        // Create known Antigravity subagent descriptor file
        let recipientId = "469e4eb6-a7f5-4e78-9d66-7ff52937e90b"
        try #"{"conversationId":"469e4eb6-a7f5-4e78-9d66-7ff52937e90b","state":"SUBAGENT_STATE_ALIVE"}"#
            .write(toFile: "\(subagentsDir)/\(recipientId).json", atomically: true, encoding: .utf8)

        let dbPath = dir.appendingPathComponent("statev2.sqlite").path
        var rawDB: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbPath, &rawDB), SQLITE_OK)

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let launch = Date()
        let t32Start = launch.addingTimeInterval(10)
        let t32Tool = launch.addingTimeInterval(61.3)
        let t32End = launch.addingTimeInterval(70.0)   // 8.7s after send_message (Run 32 real shape)
        let t33Start = launch.addingTimeInterval(197.8) // +127.8s gap (Run 32 -> Run 33 real counterexample!)
        let t33Tool = launch.addingTimeInterval(241.8)
        let t33End = launch.addingTimeInterval(260.0)   // 18.2s after send_message (Run 33 real shape)
        let t34Start = launch.addingTimeInterval(310.4) // +50.4s gap (Run 33 -> Run 34 real incident!)
        let t34End = launch.addingTimeInterval(335.0)

        let initSql = """
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
            provider_thread_id TEXT PRIMARY KEY, thread_id TEXT NOT NULL, provider TEXT NOT NULL, payload_json TEXT NOT NULL
        );
        CREATE TABLE provider_session_runtime (thread_id TEXT PRIMARY KEY, provider_name TEXT, status TEXT NOT NULL, resume_cursor_json TEXT);

        INSERT INTO projection_projects VALUES ('p1', 'google_sim', '/Users/test/google_sim');
        INSERT INTO orchestration_v2_projection_threads VALUES
            ('th-sim', 'p1', '复现机器人演示与仿真场景需求', 'antigravity', '\(iso.string(from: t32Start))', '\(iso.string(from: t32End))', NULL, NULL,
             '{"activeProviderThreadId":"pt-sim","providerInstanceId":"antigravity"}');
        INSERT INTO orchestration_v2_projection_provider_threads VALUES
            ('pt-sim', 'th-sim', 'antigravity',
             '{"providerInstanceId":"antigravity","nativeThreadRef":{"driver":"antigravity","nativeId":"parent-conv-33"},"pendingBackgroundTasks":[]}');
        INSERT INTO orchestration_v2_projection_runs VALUES
            ('run-32', 'th-sim', 32, 'antigravity', 'completed', '\(iso.string(from: t32Start))', '\(iso.string(from: t32End))', '{}');
        INSERT INTO orchestration_v2_projection_turn_items VALUES
            ('it-32', 'th-sim', 'run-32', 3201, 'dynamic_tool', 'completed', '\(iso.string(from: t32Tool))',
             '{"toolName":"Run send_message","completedAt":"\(iso.string(from: t32Tool))","nativeItemRef":{"nativeId":"call_32"},"input":{"Recipient":"\(recipientId)","Message":"re-check"}}');
        """
        XCTAssertEqual(sqlite3_exec(rawDB, initSql, nil, nil, nil), SQLITE_OK)

        let scanner = T3CodeScanner(
            v2DbPath: dbPath,
            v1DbPath: dir.appendingPathComponent("none.sqlite").path,
            antigravityProvidersRoot: providersRoot,
            handoffGraceSeconds: 150.0,
            launchTime: launch,
            isT3RunningCheck: { true }
        )
        let store = MonitorStore(statePath: dir.appendingPathComponent("read_state.json").path, suppressSystemSideEffects: true)

        // Initial baseline scan before Run 32 completes (simulate active tracking)
        store.applyScanned([], now: launch)

        // 1. 6s after Run 32 completes (past 4.5s debounce) -> MUST still be held as .running, 0 unread!
        let s32a = scanner.scan(lookbackHours: 24, now: t32End.addingTimeInterval(6))
        store.applyScanned(s32a, now: t32End.addingTimeInterval(6))
        XCTAssertEqual(s32a.first?.status, .running)
        XCTAssertEqual(store.totalUnreadCount, 0)

        // 2. 120s after Run 32 completes (still inside 150s grace covering the 127.8s real gap!) -> still .running, 0 unread!
        let s32b = scanner.scan(lookbackHours: 24, now: t32End.addingTimeInterval(120))
        store.applyScanned(s32b, now: t32End.addingTimeInterval(120))
        XCTAssertEqual(s32b.first?.status, .running)
        XCTAssertEqual(store.totalUnreadCount, 0)

        // 3. Run 33 starts at +127.8s and completes after calling send_message 18.2s earlier
        let run33Sql = """
        INSERT INTO orchestration_v2_projection_runs VALUES
            ('run-33', 'th-sim', 33, 'antigravity', 'completed', '\(iso.string(from: t33Start))', '\(iso.string(from: t33End))', '{}');
        INSERT INTO orchestration_v2_projection_turn_items VALUES
            ('it-33', 'th-sim', 'run-33', 3301, 'dynamic_tool', 'completed', '\(iso.string(from: t33Tool))',
             '{"toolName":"Run send_message","completedAt":"\(iso.string(from: t33Tool))","nativeItemRef":{"nativeId":"call_33"},"input":{"Recipient":"\(recipientId)","Message":"re-check v2"}}');
        UPDATE orchestration_v2_projection_threads SET updated_at = '\(iso.string(from: t33End))' WHERE thread_id = 'th-sim';
        """
        XCTAssertEqual(sqlite3_exec(rawDB, run33Sql, nil, nil, nil), SQLITE_OK)

        // 10s after Run 33 completes -> MUST stay .running, ZERO premature completion!
        let s33 = scanner.scan(lookbackHours: 24, now: t33End.addingTimeInterval(10))
        store.applyScanned(s33, now: t33End.addingTimeInterval(10))
        XCTAssertEqual(s33.first?.status, .running)
        XCTAssertEqual(store.totalUnreadCount, 0)

        // 4. Run 34 wakes at +50.4s and finishes normally WITHOUT calling send_message
        let run34Sql = """
        INSERT INTO orchestration_v2_projection_runs VALUES
            ('run-34', 'th-sim', 34, 'antigravity', 'completed', '\(iso.string(from: t34Start))', '\(iso.string(from: t34End))', '{}');
        UPDATE orchestration_v2_projection_threads SET updated_at = '\(iso.string(from: t34End))' WHERE thread_id = 'th-sim';
        """
        XCTAssertEqual(sqlite3_exec(rawDB, run34Sql, nil, nil, nil), SQLITE_OK)

        // Immediately at t34End + 1s -> settling in 4.5s debounce
        let s34a = scanner.scan(lookbackHours: 24, now: t34End.addingTimeInterval(1))
        XCTAssertEqual(s34a.first?.status, .done)
        store.applyScanned(s34a, now: t34End.addingTimeInterval(1))
        XCTAssertEqual(store.totalUnreadCount, 0)

        // At t34End + 6s -> confirmed ONE final completion!
        let s34b = scanner.scan(lookbackHours: 24, now: t34End.addingTimeInterval(6))
        store.applyScanned(s34b, now: t34End.addingTimeInterval(6))
        XCTAssertEqual(store.totalUnreadCount, 1)
        XCTAssertEqual(store.allSessions.first?.durationSec ?? 0, 24.6, accuracy: 0.5)

        // 5. Verify cache invalidates cleanly when an orphaned handoff reaches grace deadline (no DB changes!)
        let t35Start = t34End.addingTimeInterval(20)
        let t35Tool = t35Start.addingTimeInterval(5)
        let t35End = t35Start.addingTimeInterval(10)
        let run35Sql = """
        INSERT INTO orchestration_v2_projection_runs VALUES
            ('run-35', 'th-sim', 35, 'antigravity', 'completed', '\(iso.string(from: t35Start))', '\(iso.string(from: t35End))', '{}');
        INSERT INTO orchestration_v2_projection_turn_items VALUES
            ('it-35', 'th-sim', 'run-35', 3501, 'dynamic_tool', 'completed', '\(iso.string(from: t35Tool))',
             '{"toolName":"Run send_message","completedAt":"\(iso.string(from: t35Tool))","nativeItemRef":{"nativeId":"call_35"},"input":{"Recipient":"\(recipientId)","Message":"final note"}}');
        UPDATE orchestration_v2_projection_threads SET updated_at = '\(iso.string(from: t35End))' WHERE thread_id = 'th-sim';
        """
        XCTAssertEqual(sqlite3_exec(rawDB, run35Sql, nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_close(rawDB), SQLITE_OK)

        let s35Held = scanner.scan(lookbackHours: 24, now: t35End.addingTimeInterval(10))
        XCTAssertEqual(s35Held.first?.status, .running)

        // Without touching DB/WAL at all, scanning at t35End + 151s MUST bypass cache and release as .done with exact 10s duration!
        let s35Expired = scanner.scan(lookbackHours: 24, now: t35End.addingTimeInterval(151))
        let expSession = try XCTUnwrap(s35Expired.first)
        XCTAssertEqual(expSession.status, .done)
        XCTAssertEqual(expSession.durationSec ?? 0, 10.0, accuracy: 0.5)

        // 6. Verify Lumi restart (launchTime AFTER t35End) NEVER holds historical completed runs as .running!
        let restartedScanner = T3CodeScanner(
            v2DbPath: dbPath,
            v1DbPath: dir.appendingPathComponent("none.sqlite").path,
            antigravityProvidersRoot: providersRoot,
            handoffGraceSeconds: 150.0,
            launchTime: t35End.addingTimeInterval(5),
            isT3RunningCheck: { true }
        )
        let afterRestart = restartedScanner.scan(lookbackHours: 24, now: t35End.addingTimeInterval(10))
        XCTAssertEqual(afterRestart.first?.status, .done)
    }

    @MainActor
    func testT3CodeV2AntigravityACPSummaryDBReplaysRun39GapAndBackgroundCommands() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("lumi-t3-acp-live-\(UUID().uuidString)")
        let providersRoot = dir.appendingPathComponent("providers/antigravity").path
        let acpDir = "\(providersRoot)/profile1/antigravity-acp"
        let subagentsDir = "\(acpDir)/brain/parent-39/.system_generated/subagents"
        try fm.createDirectory(atPath: subagentsDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let subagentId = "469e4eb6-a7f5-4e78-9d66-7ff52937e90b"
        try #"{"conversationId":"469e4eb6-a7f5-4e78-9d66-7ff52937e90b","state":"SUBAGENT_STATE_ALIVE"}"#
            .write(toFile: "\(subagentsDir)/\(subagentId).json", atomically: true, encoding: .utf8)

        let v2Path = dir.appendingPathComponent("statev2.sqlite").path
        let acpDbPath = "\(acpDir)/conversation_summaries.db"
        var v2DB: OpaquePointer?
        var acpDB: OpaquePointer?
        XCTAssertEqual(sqlite3_open(v2Path, &v2DB), SQLITE_OK)
        XCTAssertEqual(sqlite3_open(acpDbPath, &acpDB), SQLITE_OK)

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func acpTS(_ d: Date) -> String {
            iso.string(from: d).replacingOccurrences(of: "T", with: " ").replacingOccurrences(of: "Z", with: "+00:00")
        }

        let launch = Date()
        let t39Start = launch.addingTimeInterval(10)
        let t39Tool = launch.addingTimeInterval(290)
        let t39End = launch.addingTimeInterval(306) // Run 39 completed (4m56s)

        let v2Sql = """
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
            provider_thread_id TEXT PRIMARY KEY, thread_id TEXT NOT NULL, provider TEXT NOT NULL, payload_json TEXT NOT NULL
        );
        CREATE TABLE provider_session_runtime (thread_id TEXT PRIMARY KEY, provider_name TEXT, status TEXT NOT NULL, resume_cursor_json TEXT);

        INSERT INTO projection_projects VALUES ('p1', 'google_sim', '/Users/test/google_sim');

        -- Thread 1: Run 39 completed (with older inactive provider_thread row too -> must resolve activeProviderThreadId!)
        INSERT INTO orchestration_v2_projection_threads VALUES
            ('th-39', 'p1', '复现机器人演示与仿真场景需求', 'antigravity', '\(iso.string(from: t39Start))', '\(iso.string(from: t39End))', NULL, NULL,
             '{"activeProviderThreadId":"pt-active","providerInstanceId":"antigravity"}');
        INSERT INTO orchestration_v2_projection_provider_threads VALUES
            ('pt-old', 'th-39', 'antigravity', '{"nativeThreadRef":{"driver":"antigravity","nativeId":"stale-old-conv"}}'),
            ('pt-active', 'th-39', 'antigravity', '{"nativeThreadRef":{"driver":"antigravity","nativeId":"parent-39"}}');
        INSERT INTO orchestration_v2_projection_runs VALUES
            ('run-39', 'th-39', 39, 'antigravity', 'completed', '\(iso.string(from: t39Start))', '\(iso.string(from: t39End))', '{}');
        INSERT INTO orchestration_v2_projection_turn_items VALUES
            ('it-39', 'th-39', 'run-39', 3901, 'dynamic_tool', 'completed', '\(iso.string(from: t39Tool))',
             '{"toolName":"Run send_message","completedAt":"\(iso.string(from: t39Tool))","nativeItemRef":{"nativeId":"call_39"},"input":{"Recipient":"\(subagentId)","Message":"audit"}}');

        -- Thread 2: Background run_command (Run 42 shape, NO send_message at all!)
        INSERT INTO orchestration_v2_projection_threads VALUES
            ('th-bg', 'p1', 'Bg rsync task', 'antigravity', '\(iso.string(from: t39Start))', '\(iso.string(from: t39End))', NULL, NULL,
             '{"activeProviderThreadId":"pt-bg","providerInstanceId":"antigravity"}');
        INSERT INTO orchestration_v2_projection_provider_threads VALUES
            ('pt-bg', 'th-bg', 'antigravity', '{"nativeThreadRef":{"driver":"antigravity","nativeId":"parent-bg"}}');
        INSERT INTO orchestration_v2_projection_runs VALUES
            ('run-42', 'th-bg', 42, 'antigravity', 'completed', '\(iso.string(from: t39Start))', '\(iso.string(from: t39End))', '{}');

        -- Thread 3: Cancelled run -> MUST NOT be promoted even if ACP DB briefly still shows RUNNING
        INSERT INTO orchestration_v2_projection_threads VALUES
            ('th-cancel', 'p1', 'Stopped task', 'antigravity', '\(iso.string(from: t39Start))', '\(iso.string(from: t39End))', NULL, NULL,
             '{"activeProviderThreadId":"pt-cancel","providerInstanceId":"antigravity"}');
        INSERT INTO orchestration_v2_projection_provider_threads VALUES
            ('pt-cancel', 'th-cancel', 'antigravity', '{"nativeThreadRef":{"driver":"antigravity","nativeId":"parent-cancel"}}');
        INSERT INTO orchestration_v2_projection_runs VALUES
            ('run-c', 'th-cancel', 1, 'antigravity', 'cancelled', '\(iso.string(from: t39Start))', '\(iso.string(from: t39End))', '{}');
        """
        XCTAssertEqual(sqlite3_exec(v2DB, v2Sql, nil, nil, nil), SQLITE_OK)

        let acpInitSql = """
        PRAGMA journal_mode=WAL;
        CREATE TABLE conversation_summaries (
            conversation_id TEXT PRIMARY KEY,
            parent_conversation_id TEXT NOT NULL DEFAULT '',
            status TEXT NOT NULL DEFAULT '',
            not_fully_idle INTEGER NOT NULL DEFAULT 0,
            killed INTEGER NOT NULL DEFAULT 0,
            last_modified_time TEXT NOT NULL
        );
        -- Subagent actively running while parent-39 is IDLE (126s subagent phase)
        INSERT INTO conversation_summaries VALUES
            ('parent-39', '', 'CASCADE_RUN_STATUS_IDLE', 0, 0, '\(acpTS(t39End))'),
            ('\(subagentId)', 'parent-39', 'CASCADE_RUN_STATUS_RUNNING', 1, 0, '\(acpTS(t39End.addingTimeInterval(60)))'),
            -- Background command running on parent-bg (IDLE + not_fully_idle = 1)
            ('parent-bg', '', 'CASCADE_RUN_STATUS_IDLE', 1, 0, '\(acpTS(t39End.addingTimeInterval(5)))'),
            -- Cancelled thread still briefly RUNNING in ACP DB
            ('parent-cancel', '', 'CASCADE_RUN_STATUS_RUNNING', 1, 0, '\(acpTS(t39End))'),
            -- Killed subagent must be ignored
            ('killed-sub', 'parent-39', 'CASCADE_RUN_STATUS_RUNNING', 1, 1, '\(acpTS(t39End))');
        """
        XCTAssertEqual(sqlite3_exec(acpDB, acpInitSql, nil, nil, nil), SQLITE_OK)

        let scanner = T3CodeScanner(
            v2DbPath: v2Path,
            v1DbPath: dir.appendingPathComponent("none.sqlite").path,
            antigravityProvidersRoot: providersRoot,
            handoffGraceSeconds: 150.0,
            launchTime: launch,
            isT3RunningCheck: { true }
        )
        let store = MonitorStore(statePath: dir.appendingPathComponent("read_state.json").path, suppressSystemSideEffects: true)
        store.applyScanned([], now: launch)

        // 1. At t39End + 100s: Subagent still running -> th-39 is .running (1 subagent), th-bg is .running (background task), th-cancel stays .canceled!
        let s1 = scanner.scan(lookbackHours: 24, now: t39End.addingTimeInterval(100))
        store.applyScanned(s1, now: t39End.addingTimeInterval(100))
        let th39_1 = try XCTUnwrap(s1.first(where: { $0.rawId == "th-39" }))
        XCTAssertEqual(th39_1.status, .running)
        XCTAssertEqual(th39_1.activeSubagents, 1)
        XCTAssertEqual(th39_1.currentAction, "等待 1 个子 Agent 执行…")
        let thBg_1 = try XCTUnwrap(s1.first(where: { $0.rawId == "th-bg" }))
        XCTAssertEqual(thBg_1.status, .running)
        XCTAssertEqual(thBg_1.currentAction, "后台任务运行中…")
        XCTAssertEqual(s1.first(where: { $0.rawId == "th-cancel" })?.status, .canceled)
        XCTAssertEqual(store.totalUnreadCount, 0)

        // 2. At t39End + 160s (PAST old 150s grace!!): Subagent finished (IDLE), parent-39 ALREADY woke up and is thinking
        //    (`CASCADE_RUN_STATUS_RUNNING`) BEFORE T3 Code creates Run 40 in statev2.sqlite! (Exact Run 39 -> Run 40 gap!)
        let tParentWake = t39End.addingTimeInterval(126)
        let acpPhase2 = """
        UPDATE conversation_summaries SET status = 'CASCADE_RUN_STATUS_IDLE', not_fully_idle = 0, last_modified_time = '\(acpTS(tParentWake))' WHERE conversation_id = '\(subagentId)';
        UPDATE conversation_summaries SET status = 'CASCADE_RUN_STATUS_RUNNING', not_fully_idle = 1, last_modified_time = '\(acpTS(t39End.addingTimeInterval(155)))' WHERE conversation_id = 'parent-39';
        """
        XCTAssertEqual(sqlite3_exec(acpDB, acpPhase2, nil, nil, nil), SQLITE_OK)

        let s2 = scanner.scan(lookbackHours: 24, now: t39End.addingTimeInterval(160))
        store.applyScanned(s2, now: t39End.addingTimeInterval(160))
        let th39_2 = try XCTUnwrap(s2.first(where: { $0.rawId == "th-39" }))
        XCTAssertEqual(th39_2.status, .running)
        XCTAssertEqual(th39_2.currentAction, "思考与执行中…")
        XCTAssertEqual(store.totalUnreadCount, 0)

        // 3. Parent & bg command finally go IDLE/0 in ACP DB (WITHOUT changing statev2.sqlite at all!)
        //    -> During the 12s post-ACP-idle seam they stay .running ("等待主会话接续…") to absorb handoff gaps;
        //       right after seam expiry they release to .done and emit clean completions after 4.5s debounce!
        let tAllDone = t39End.addingTimeInterval(162)
        let acpPhase3 = """
        UPDATE conversation_summaries SET status = 'CASCADE_RUN_STATUS_IDLE', not_fully_idle = 0, last_modified_time = '\(acpTS(tAllDone))' WHERE conversation_id IN ('parent-39', 'parent-bg');
        """
        XCTAssertEqual(sqlite3_exec(acpDB, acpPhase3, nil, nil, nil), SQLITE_OK)

        // At tAllDone + 1s (first IDLE observation starts the 12s post-ACP-idle seam -> expires at tAllDone + 13s) -> still held!
        let s3Seam = scanner.scan(lookbackHours: 24, now: tAllDone.addingTimeInterval(1))
        XCTAssertEqual(s3Seam.first(where: { $0.rawId == "th-39" })?.status, .running)
        XCTAssertEqual(s3Seam.first(where: { $0.rawId == "th-bg" })?.status, .running)

        // Past 12s post-ACP-idle seam from first IDLE observation (tAllDone + 1s + 12s = tAllDone + 13s) -> releases cleanly as .done!
        let tAfterSeam = tAllDone.addingTimeInterval(14)
        let s3Done = scanner.scan(lookbackHours: 24, now: tAfterSeam)
        XCTAssertEqual(s3Done.first(where: { $0.rawId == "th-39" })?.status, .done)
        XCTAssertEqual(s3Done.first(where: { $0.rawId == "th-bg" })?.status, .done)

        // Settle past 4.5s debounce -> emits final completions cleanly!
        store.applyScanned(s3Done, now: tAfterSeam)
        XCTAssertEqual(store.totalUnreadCount, 0)
        let s4 = scanner.scan(lookbackHours: 24, now: tAfterSeam.addingTimeInterval(5))
        store.applyScanned(s4, now: tAfterSeam.addingTimeInterval(5))
        XCTAssertEqual(store.totalUnreadCount, 2)

        XCTAssertEqual(sqlite3_close(v2DB), SQLITE_OK)
        XCTAssertEqual(sqlite3_close(acpDB), SQLITE_OK)
    }

    @MainActor
    func testT3CodeV2TickByTickReplayRun39To40AndRun42To43WithFailureAndRestartGuards() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("lumi-t3-tick-replay-\(UUID().uuidString)")
        let providersRoot = dir.appendingPathComponent("providers/antigravity").path
        let acpDir = "\(providersRoot)/profile1/antigravity-acp"
        let subagentsDir = "\(acpDir)/brain/parent-39/.system_generated/subagents"
        try fm.createDirectory(atPath: subagentsDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let subId = "469e4eb6-a7f5-4e78-9d66-7ff52937e90b"
        try #"{"conversationId":"469e4eb6-a7f5-4e78-9d66-7ff52937e90b","state":"SUBAGENT_STATE_ALIVE"}"#
            .write(toFile: "\(subagentsDir)/\(subId).json", atomically: true, encoding: .utf8)

        let v2Path = dir.appendingPathComponent("statev2.sqlite").path
        let acpDbPath = "\(acpDir)/conversation_summaries.db"
        var v2DB: OpaquePointer?
        var acpDB: OpaquePointer?
        XCTAssertEqual(sqlite3_open(v2Path, &v2DB), SQLITE_OK)
        XCTAssertEqual(sqlite3_open(acpDbPath, &acpDB), SQLITE_OK)

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func acpTS(_ d: Date) -> String {
            iso.string(from: d).replacingOccurrences(of: "T", with: " ").replacingOccurrences(of: "Z", with: "+00:00")
        }

        let launch = Date()
        let t39Start = launch.addingTimeInterval(10)
        let t39Tool = launch.addingTimeInterval(290)
        let t39End = launch.addingTimeInterval(306)

        let v2Init = """
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
            provider_thread_id TEXT PRIMARY KEY, thread_id TEXT NOT NULL, provider TEXT NOT NULL, payload_json TEXT NOT NULL
        );
        CREATE TABLE provider_session_runtime (thread_id TEXT PRIMARY KEY, provider_name TEXT, status TEXT NOT NULL, resume_cursor_json TEXT);

        INSERT INTO projection_projects VALUES ('p1', 'google_sim', '/Users/test/google_sim');

        -- Run 39 (send_message -> 126s subagent -> 6s BOTH-IDLE handoff seam -> 46.5s parent wake -> Run 40 INSERT at +178.5s!)
        INSERT INTO orchestration_v2_projection_threads VALUES
            ('th-39', 'p1', 'Run 39->40', 'antigravity', '\(iso.string(from: t39Start))', '\(iso.string(from: t39End))', NULL, NULL,
             '{"activeProviderThreadId":"pt-39","providerInstanceId":"antigravity"}');
        INSERT INTO orchestration_v2_projection_provider_threads VALUES
            ('pt-39', 'th-39', 'antigravity', '{"providerInstanceId":"antigravity","nativeThreadRef":{"driver":"antigravity","nativeId":"parent-39"}}');
        INSERT INTO orchestration_v2_projection_runs VALUES
            ('run-39', 'th-39', 39, 'antigravity', 'completed', '\(iso.string(from: t39Start))', '\(iso.string(from: t39End))',
             '{"providerThreadId":"pt-39","providerInstanceId":"antigravity"}');
        INSERT INTO orchestration_v2_projection_turn_items VALUES
            ('it-39', 'th-39', 'run-39', 3901, 'dynamic_tool', 'completed', '\(iso.string(from: t39Tool))',
             '{"toolName":"Run send_message","completedAt":"\(iso.string(from: t39Tool))","nativeItemRef":{"nativeId":"call_39"},"input":{"Recipient":"\(subId)","Message":"audit"}}');

        -- Run 42 (NO send_message, background run_command not_fully_idle=1 -> 6s IDLE seam -> Run 43 INSERT at +14s!)
        INSERT INTO orchestration_v2_projection_threads VALUES
            ('th-42', 'p1', 'Run 42->43', 'antigravity', '\(iso.string(from: t39Start))', '\(iso.string(from: t39End))', NULL, NULL,
             '{"activeProviderThreadId":"pt-42","providerInstanceId":"antigravity"}');
        INSERT INTO orchestration_v2_projection_provider_threads VALUES
            ('pt-42', 'th-42', 'antigravity', '{"providerInstanceId":"antigravity","nativeThreadRef":{"driver":"antigravity","nativeId":"parent-42"}}');
        INSERT INTO orchestration_v2_projection_runs VALUES
            ('run-42', 'th-42', 42, 'antigravity', 'completed', '\(iso.string(from: t39Start))', '\(iso.string(from: t39End))',
             '{"providerThreadId":"pt-42","providerInstanceId":"antigravity"}');
        """
        XCTAssertEqual(sqlite3_exec(v2DB, v2Init, nil, nil, nil), SQLITE_OK)

        let acpInit = """
        PRAGMA journal_mode=WAL;
        CREATE TABLE conversation_summaries (
            conversation_id TEXT PRIMARY KEY,
            parent_conversation_id TEXT NOT NULL DEFAULT '',
            status TEXT NOT NULL DEFAULT '',
            not_fully_idle INTEGER NOT NULL DEFAULT 0,
            killed INTEGER NOT NULL DEFAULT 0,
            last_modified_time TEXT NOT NULL
        );
        INSERT INTO conversation_summaries VALUES
            ('parent-39', '', 'CASCADE_RUN_STATUS_IDLE', 0, 0, '\(acpTS(t39End))'),
            ('\(subId)', 'parent-39', 'CASCADE_RUN_STATUS_RUNNING', 1, 0, '\(acpTS(t39End))'),
            ('parent-42', '', 'CASCADE_RUN_STATUS_IDLE', 1, 0, '\(acpTS(t39End))');
        """
        XCTAssertEqual(sqlite3_exec(acpDB, acpInit, nil, nil, nil), SQLITE_OK)

        let scanner = T3CodeScanner(
            v2DbPath: v2Path,
            v1DbPath: dir.appendingPathComponent("none.sqlite").path,
            antigravityProvidersRoot: providersRoot,
            handoffGraceSeconds: 150.0,
            acpIdleSeamSeconds: 12.0,
            launchTime: launch,
            isT3RunningCheck: { true }
        )
        let store = MonitorStore(statePath: dir.appendingPathComponent("read_state.json").path, suppressSystemSideEffects: true)
        store.applyScanned([], now: launch)

        // Tick every 1.5s from t39End+1.5s to t39End+195s!
        var tOffset: TimeInterval = 1.5
        var didRun42IdleSeam = false
        var didRun43Insert = false
        var didRun43Complete = false
        var didSubagentFinishSeam = false
        var didParentWake = false
        var didRun40Insert = false
        var didRun40Complete = false

        while tOffset <= 198.0 {
            let now = t39End.addingTimeInterval(tOffset)

            // Run 42 bg command flips IDLE at +8s -> 6s BOTH-IDLE seam until Run 43 starts at +14s -> completes at +22s
            if !didRun42IdleSeam && tOffset >= 8.0 {
                didRun42IdleSeam = true
                XCTAssertEqual(sqlite3_exec(acpDB, "UPDATE conversation_summaries SET not_fully_idle = 0, last_modified_time = '\(acpTS(now))' WHERE conversation_id = 'parent-42';", nil, nil, nil), SQLITE_OK)
            }
            if !didRun43Insert && tOffset >= 14.0 {
                didRun43Insert = true
                XCTAssertEqual(sqlite3_exec(v2DB, """
                    INSERT INTO orchestration_v2_projection_runs VALUES
                        ('run-43', 'th-42', 43, 'antigravity', 'running', '\(iso.string(from: now))', NULL, '{"providerThreadId":"pt-42","providerInstanceId":"antigravity"}');
                    UPDATE orchestration_v2_projection_threads SET updated_at = '\(iso.string(from: now))' WHERE thread_id = 'th-42';
                    """, nil, nil, nil), SQLITE_OK)
            }
            if !didRun43Complete && tOffset >= 22.0 {
                didRun43Complete = true
                XCTAssertEqual(sqlite3_exec(v2DB, """
                    UPDATE orchestration_v2_projection_runs SET status = 'completed', completed_at = '\(iso.string(from: now))' WHERE run_id = 'run-43';
                    UPDATE orchestration_v2_projection_threads SET updated_at = '\(iso.string(from: now))' WHERE thread_id = 'th-42';
                    """, nil, nil, nil), SQLITE_OK)
            }

            // Run 39 subagent flips IDLE at +126s while parent stays IDLE for 6 FULL seconds (+126s..+132s) ->
            // parent wakes as BUSY/RUNNING at +132s -> Run 40 inserted into statev2.sqlite at +178.5s -> completes at +186s!
            if !didSubagentFinishSeam && tOffset >= 126.0 {
                didSubagentFinishSeam = true
                XCTAssertEqual(sqlite3_exec(acpDB, "UPDATE conversation_summaries SET status = 'CASCADE_RUN_STATUS_IDLE', not_fully_idle = 0, last_modified_time = '\(acpTS(now))' WHERE conversation_id = '\(subId)';", nil, nil, nil), SQLITE_OK)
            }
            if !didParentWake && tOffset >= 132.0 {
                didParentWake = true
                XCTAssertEqual(sqlite3_exec(acpDB, "UPDATE conversation_summaries SET status = 'CASCADE_RUN_STATUS_BUSY', not_fully_idle = 1, last_modified_time = '\(acpTS(now))' WHERE conversation_id = 'parent-39';", nil, nil, nil), SQLITE_OK)
            }
            if !didRun40Insert && tOffset >= 178.5 {
                didRun40Insert = true
                XCTAssertEqual(sqlite3_exec(v2DB, """
                    INSERT INTO orchestration_v2_projection_runs VALUES
                        ('run-40', 'th-39', 40, 'antigravity', 'running', '\(iso.string(from: now))', NULL, '{"providerThreadId":"pt-39","providerInstanceId":"antigravity"}');
                    UPDATE orchestration_v2_projection_threads SET updated_at = '\(iso.string(from: now))' WHERE thread_id = 'th-39';
                    """, nil, nil, nil), SQLITE_OK)
            }
            if !didRun40Complete && tOffset >= 186.0 {
                didRun40Complete = true
                XCTAssertEqual(sqlite3_exec(acpDB, "UPDATE conversation_summaries SET status = 'CASCADE_RUN_STATUS_IDLE', not_fully_idle = 0, last_modified_time = '\(acpTS(now))' WHERE conversation_id = 'parent-39';", nil, nil, nil), SQLITE_OK)
                XCTAssertEqual(sqlite3_exec(v2DB, """
                    UPDATE orchestration_v2_projection_runs SET status = 'completed', completed_at = '\(iso.string(from: now))' WHERE run_id = 'run-40';
                    UPDATE orchestration_v2_projection_threads SET updated_at = '\(iso.string(from: now))' WHERE thread_id = 'th-39';
                    """, nil, nil, nil), SQLITE_OK)
            }

            let res = scanner.scanDetailed(lookbackHours: 24, now: now)
            store.applyScanned(res.sessions, now: now, deferConfirmKinds: res.hadTransientFailure ? [.t3code] : [])

            // Before Run 43 finishes (+22s), ZERO premature popups!
            if tOffset < 22.0 {
                XCTAssertEqual(store.totalUnreadCount, 0, "Premature popup before Run 43 finished at t+\(tOffset)s")
            }
            // Between Run 43 finish (+27s) and Run 40 finish (+186s), ONLY th-42 may be unread (NEVER th-39!)
            if tOffset >= 28.0 && tOffset < 186.0 {
                XCTAssertEqual(store.totalUnreadCount, 1, "Premature popup for Run 39->40 at t+\(tOffset)s")
                XCTAssertEqual(store.unreadCompletedSessions.map(\.rawId), ["th-42"])
            }
            tOffset += 1.5
        }

        // After Run 40 finishes (+186s + 4.5s debounce), BOTH th-42 and th-39 emitted EXACTLY 1 confirmed completion each!
        XCTAssertEqual(store.totalUnreadCount, 2)
        XCTAssertEqual(store.confirmedCompletionIds, ["t3code:th-42", "t3code:th-39"])

        // --- Regression 2: Unchanged FileStamp SQLite EXCLUSIVE lock failure crossing >6.5s (scoped deferral!) ---
        // Add BOTH an Antigravity thread (`th-fail`) AND a Codex thread (`th-codex`).
        // Hold `BEGIN EXCLUSIVE` on `acpDB` so `FileStamp` is 100% UNCHANGED while reads fail with SQLITE_BUSY!
        let tFailBase = t39End.addingTimeInterval(220)
        XCTAssertEqual(sqlite3_exec(v2DB, """
            INSERT INTO orchestration_v2_projection_threads VALUES
                ('th-fail', 'p1', 'ACP Fail Guard', 'antigravity', '\(iso.string(from: tFailBase))', '\(iso.string(from: tFailBase.addingTimeInterval(5)))', NULL, NULL,
                 '{"activeProviderThreadId":"pt-fail","providerInstanceId":"antigravity"}'),
                ('th-codex', 'p1', 'Codex Unaffected', 'codex', '\(iso.string(from: tFailBase))', '\(iso.string(from: tFailBase.addingTimeInterval(5)))', NULL, NULL,
                 '{"activeProviderThreadId":"pt-codex","providerInstanceId":"codex"}');
            INSERT INTO orchestration_v2_projection_provider_threads VALUES
                ('pt-fail', 'th-fail', 'antigravity', '{"providerInstanceId":"antigravity","nativeThreadRef":{"driver":"antigravity","nativeId":"parent-fail"}}'),
                ('pt-codex', 'th-codex', 'codex', '{"providerInstanceId":"codex","nativeThreadRef":{"driver":"codex","nativeId":"codex-conv-1"}}');
            INSERT INTO orchestration_v2_projection_runs VALUES
                ('run-fail', 'th-fail', 1, 'antigravity', 'completed', '\(iso.string(from: tFailBase))', '\(iso.string(from: tFailBase.addingTimeInterval(5)))',
                 '{"providerThreadId":"pt-fail","providerInstanceId":"antigravity"}'),
                ('run-codex', 'th-codex', 1, 'codex', 'completed', '\(iso.string(from: tFailBase))', '\(iso.string(from: tFailBase.addingTimeInterval(5)))',
                 '{"providerThreadId":"pt-codex","providerInstanceId":"codex"}');
            """, nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(acpDB, "INSERT INTO conversation_summaries VALUES ('parent-fail', '', 'CASCADE_RUN_STATUS_IDLE', 0, 0, '\(acpTS(tFailBase.addingTimeInterval(5)))');", nil, nil, nil), SQLITE_OK)

        // Start settling both cleanly at +6s
        let rOk1 = scanner.scanDetailed(lookbackHours: 24, now: tFailBase.addingTimeInterval(6), forceFresh: false)
        XCTAssertFalse(rOk1.hadTransientFailure)
        store.applyScanned(rOk1.sessions, now: tFailBase.addingTimeInterval(6), deferConfirmKinds: rOk1.deferAllCompletions ? [.t3code] : [], deferConfirmSessionIds: rOk1.deferredSessionIds)

        // Acquire a genuine SQLite WAL EXCLUSIVE lock (`PRAGMA locking_mode=EXCLUSIVE` + `BEGIN EXCLUSIVE`)
        // touching 0 rows so BOTH db and -wal FileStamps stay 100% UNCHANGED while readers hit SQLITE_BUSY (5)!
        var stDbBefore = stat()
        var stWalBefore = stat()
        XCTAssertEqual(stat(acpDbPath, &stDbBefore), 0)
        let hasWalBefore = (stat(acpDbPath + "-wal", &stWalBefore) == 0)
        XCTAssertEqual(sqlite3_exec(acpDB, "PRAGMA locking_mode=EXCLUSIVE; BEGIN EXCLUSIVE; UPDATE conversation_summaries SET killed = killed WHERE 0;", nil, nil, nil), SQLITE_OK)

        let rLock1 = scanner.scanDetailed(lookbackHours: 24, now: tFailBase.addingTimeInterval(8), forceFresh: true)
        XCTAssertFalse(rLock1.deferAllCompletions, "ACP DB lock must NOT defer non-Antigravity Codex sessions!")
        XCTAssertTrue(rLock1.deferredSessionIds.contains("t3code:th-fail"))
        XCTAssertFalse(rLock1.deferredSessionIds.contains("t3code:th-codex"))
        store.applyScanned(rLock1.sessions, now: tFailBase.addingTimeInterval(8), deferConfirmKinds: [], deferConfirmSessionIds: rLock1.deferredSessionIds)

        let rLock2 = scanner.scanDetailed(lookbackHours: 24, now: tFailBase.addingTimeInterval(13), forceFresh: true)
        XCTAssertTrue(rLock2.deferredSessionIds.contains("t3code:th-fail"), "Dirty ACP path must still retry on unchanged FileStamp!")
        store.applyScanned(rLock2.sessions, now: tFailBase.addingTimeInterval(13), deferConfirmKinds: [], deferConfirmSessionIds: rLock2.deferredSessionIds)
        // Codex thread confirmed cleanly despite ACP lock, while Antigravity thread stayed paused!
        XCTAssertEqual(store.confirmedCompletionIds, ["t3code:th-42", "t3code:th-39", "t3code:th-codex"])

        // Release exclusive lock (BOTH db and -wal FileStamps stay 100% UNCHANGED!) -> dirty path retries even with forceFresh: false!
        XCTAssertEqual(sqlite3_exec(acpDB, "ROLLBACK; PRAGMA locking_mode=NORMAL; SELECT 1 FROM conversation_summaries LIMIT 1;", nil, nil, nil), SQLITE_OK)
        var stDbAfter = stat()
        var stWalAfter = stat()
        XCTAssertEqual(stat(acpDbPath, &stDbAfter), 0)
        XCTAssertEqual(stDbBefore.st_ino, stDbAfter.st_ino)
        XCTAssertEqual(stDbBefore.st_size, stDbAfter.st_size)
        XCTAssertEqual(stDbBefore.st_mtimespec.tv_sec, stDbAfter.st_mtimespec.tv_sec)
        XCTAssertEqual(stDbBefore.st_mtimespec.tv_nsec, stDbAfter.st_mtimespec.tv_nsec)
        if hasWalBefore {
            XCTAssertEqual(stat(acpDbPath + "-wal", &stWalAfter), 0)
            XCTAssertEqual(stWalBefore.st_size, stWalAfter.st_size)
            XCTAssertEqual(stWalBefore.st_mtimespec.tv_sec, stWalAfter.st_mtimespec.tv_sec)
            XCTAssertEqual(stWalBefore.st_mtimespec.tv_nsec, stWalAfter.st_mtimespec.tv_nsec)
        }

        let rRec1 = scanner.scanDetailed(lookbackHours: 24, now: tFailBase.addingTimeInterval(14.5), forceFresh: false)
        XCTAssertFalse(rRec1.hadTransientFailure, "Dirty ACP path must recover on unchanged FileStamp!")
        store.applyScanned(rRec1.sessions, now: tFailBase.addingTimeInterval(14.5))
        // At +17.5s (3.0s after first clean read at +14.5s, even though 4.5s after failed +13s!) -> MUST STILL be settling!
        let rRecMid = scanner.scanDetailed(lookbackHours: 24, now: tFailBase.addingTimeInterval(17.5), forceFresh: true)
        store.applyScanned(rRecMid.sessions, now: tFailBase.addingTimeInterval(17.5))
        XCTAssertEqual(store.confirmedCompletionIds, ["t3code:th-42", "t3code:th-39", "t3code:th-codex"], "Must require full 4.5s of clean reads after failure recovery!")
        // At +19.5s (5.0s after first clean read at +14.5s) -> confirms cleanly!
        let rRec2 = scanner.scanDetailed(lookbackHours: 24, now: tFailBase.addingTimeInterval(19.5), forceFresh: true)
        store.applyScanned(rRec2.sessions, now: tFailBase.addingTimeInterval(19.5))
        XCTAssertEqual(store.confirmedCompletionIds, ["t3code:th-42", "t3code:th-39", "t3code:th-codex", "t3code:th-fail"])

        // --- Regression 3: Lumi restart while pre-launch Run's ACP depth-2 grandchild is active, finishes post-launch without Run N+1 ---
        let restartLaunch = tFailBase.addingTimeInterval(50)
        let preLaunchStart = restartLaunch.addingTimeInterval(-60)
        let preLaunchEnd = restartLaunch.addingTimeInterval(-10)
        XCTAssertEqual(sqlite3_exec(v2DB, """
            INSERT INTO orchestration_v2_projection_threads VALUES
                ('th-pre', 'p1', 'Pre-launch ACP work', 'antigravity', '\(iso.string(from: preLaunchStart))', '\(iso.string(from: preLaunchEnd))', NULL, NULL,
                 '{"activeProviderThreadId":"pt-pre","providerInstanceId":"antigravity"}');
            INSERT INTO orchestration_v2_projection_provider_threads VALUES
                ('pt-pre', 'th-pre', 'antigravity', '{"providerInstanceId":"antigravity","nativeThreadRef":{"driver":"antigravity","nativeId":"parent-pre"}}');
            INSERT INTO orchestration_v2_projection_runs VALUES
                ('run-pre', 'th-pre', 1, 'antigravity', 'completed', '\(iso.string(from: preLaunchStart))', '\(iso.string(from: preLaunchEnd))',
                 '{"providerThreadId":"pt-pre","providerInstanceId":"antigravity"}');
            """, nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(acpDB, """
            INSERT INTO conversation_summaries VALUES
                ('parent-pre', '', 'CASCADE_RUN_STATUS_IDLE', 0, 0, '\(acpTS(preLaunchEnd))'),
                ('mid-idle', 'parent-pre', 'CASCADE_RUN_STATUS_IDLE', 0, 0, '\(acpTS(preLaunchEnd))'),
                ('grandchild-pre', 'mid-idle', 'CASCADE_RUN_STATUS_RUNNING', 1, 0, '\(acpTS(restartLaunch))');
            """, nil, nil, nil), SQLITE_OK)

        let restartedScanner = T3CodeScanner(
            v2DbPath: v2Path,
            v1DbPath: dir.appendingPathComponent("none.sqlite").path,
            antigravityProvidersRoot: providersRoot,
            handoffGraceSeconds: 150.0,
            acpIdleSeamSeconds: 6.0,
            launchTime: restartLaunch,
            isT3RunningCheck: { true }
        )
        let restartedStore = MonitorStore(
            statePath: dir.appendingPathComponent("read_state_restart.json").path,
            launchTime: restartLaunch,
            suppressSystemSideEffects: true
        )

        // First scan right at restartLaunch: th-pre MUST be .running via depth-2 grandchild (NOT unread)!
        let rs1 = restartedScanner.scanDetailed(lookbackHours: 24, now: restartLaunch.addingTimeInterval(1))
        XCTAssertEqual(rs1.sessions.first(where: { $0.rawId == "th-pre" })?.status, .running)
        restartedStore.applyScanned(rs1.sessions, now: restartLaunch.addingTimeInterval(1))
        XCTAssertEqual(restartedStore.confirmedCompletionIds, [])

        // Grandchild finishes post-launch at restartLaunch + 20s (NO Run N+1!)
        let tPostFinish = restartLaunch.addingTimeInterval(20)
        XCTAssertEqual(sqlite3_exec(acpDB, "UPDATE conversation_summaries SET status = 'CASCADE_RUN_STATUS_IDLE', not_fully_idle = 0, last_modified_time = '\(acpTS(tPostFinish))' WHERE conversation_id = 'grandchild-pre';", nil, nil, nil), SQLITE_OK)

        // First IDLE observation at tPostFinish + 2s starts the 6s seam -> expires at tPostFinish + 8s!
        let rs2 = restartedScanner.scanDetailed(lookbackHours: 24, now: tPostFinish.addingTimeInterval(2))
        XCTAssertEqual(rs2.sessions.first(where: { $0.rawId == "th-pre" })?.status, .running)
        restartedStore.applyScanned(rs2.sessions, now: tPostFinish.addingTimeInterval(2))
        XCTAssertEqual(restartedStore.confirmedCompletionIds, [])

        // Past 6s seam from first IDLE observation (tPostFinish + 2s + 6s = tPostFinish + 8s) -> releases with post-launch completedAt & notifies!
        let tAfterRestartSeam = tPostFinish.addingTimeInterval(9)
        let rs3 = restartedScanner.scanDetailed(lookbackHours: 24, now: tAfterRestartSeam)
        let preSession = try XCTUnwrap(rs3.sessions.first(where: { $0.rawId == "th-pre" }))
        XCTAssertEqual(preSession.status, .done)
        XCTAssertGreaterThanOrEqual(preSession.completedAt ?? .distantPast, restartLaunch)
        XCTAssertEqual(preSession.completedAt?.timeIntervalSince(tPostFinish) ?? 99, 0, accuracy: 1.0)
        restartedStore.applyScanned(rs3.sessions, now: tAfterRestartSeam)
        let rs4 = restartedScanner.scanDetailed(lookbackHours: 24, now: tAfterRestartSeam.addingTimeInterval(5), forceFresh: true)
        restartedStore.applyScanned(rs4.sessions, now: tAfterRestartSeam.addingTimeInterval(5))
        XCTAssertEqual(restartedStore.confirmedCompletionIds, ["t3code:th-pre"])

        XCTAssertEqual(sqlite3_close(v2DB), SQLITE_OK)
        XCTAssertEqual(sqlite3_close(acpDB), SQLITE_OK)
    }

    @MainActor
    func testT3CodeV2ACPFirstIdleAnchorUnpublishedRecipientAndKilledAncestorGuards() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("lumi-t3-acp-edge-\(UUID().uuidString)")
        let providersRoot = dir.appendingPathComponent("providers/antigravity").path
        let acpDir = "\(providersRoot)/profile1/antigravity-acp"
        let subagentsDir = "\(acpDir)/brain/parent-sm/.system_generated/subagents"
        try fm.createDirectory(atPath: subagentsDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let recipientId = "rec-sub-1"
        try #"{"conversationId":"rec-sub-1","state":"SUBAGENT_STATE_ALIVE"}"#
            .write(toFile: "\(subagentsDir)/\(recipientId).json", atomically: true, encoding: .utf8)

        let v2Path = dir.appendingPathComponent("statev2.sqlite").path
        let acpDbPath = "\(acpDir)/conversation_summaries.db"
        var v2DB: OpaquePointer?
        var acpDB: OpaquePointer?
        XCTAssertEqual(sqlite3_open(v2Path, &v2DB), SQLITE_OK)
        XCTAssertEqual(sqlite3_open(acpDbPath, &acpDB), SQLITE_OK)

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func acpTS(_ d: Date) -> String {
            iso.string(from: d).replacingOccurrences(of: "T", with: " ").replacingOccurrences(of: "Z", with: "+00:00")
        }

        let launch = Date()
        let tStart = launch.addingTimeInterval(5)
        let tTool = launch.addingTimeInterval(15)
        let tEnd = launch.addingTimeInterval(20)

        let v2Sql = """
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
            provider_thread_id TEXT PRIMARY KEY, thread_id TEXT NOT NULL, provider TEXT NOT NULL, payload_json TEXT NOT NULL
        );
        CREATE TABLE provider_session_runtime (thread_id TEXT PRIMARY KEY, provider_name TEXT, status TEXT NOT NULL, resume_cursor_json TEXT);

        INSERT INTO projection_projects VALUES ('p1', 'Proj', '/Users/test/proj');

        -- Case A: Cache-hit ticks before first IDLE observation with UNCHANGED last_modified_time
        INSERT INTO orchestration_v2_projection_threads VALUES
            ('th-cache', 'p1', 'Cache hit seam', 'antigravity', '\(iso.string(from: tStart))', '\(iso.string(from: tEnd))', NULL, NULL,
             '{"activeProviderThreadId":"pt-cache","providerInstanceId":"antigravity"}');
        INSERT INTO orchestration_v2_projection_provider_threads VALUES
            ('pt-cache', 'th-cache', 'antigravity', '{"providerInstanceId":"antigravity","nativeThreadRef":{"driver":"antigravity","nativeId":"parent-cache"}}');
        INSERT INTO orchestration_v2_projection_runs VALUES
            ('run-cache', 'th-cache', 1, 'antigravity', 'completed', '\(iso.string(from: tStart))', '\(iso.string(from: tEnd))',
             '{"providerThreadId":"pt-cache","providerInstanceId":"antigravity"}');

        -- Case B: send_message where parent is IDLE/0 but recipient subagent is NOT yet published/updated -> must keep 150s fallback!
        INSERT INTO orchestration_v2_projection_threads VALUES
            ('th-sm', 'p1', 'SendMsg unpublished rec', 'antigravity', '\(iso.string(from: tStart))', '\(iso.string(from: tEnd))', NULL, NULL,
             '{"activeProviderThreadId":"pt-sm","providerInstanceId":"antigravity"}');
        INSERT INTO orchestration_v2_projection_provider_threads VALUES
            ('pt-sm', 'th-sm', 'antigravity', '{"providerInstanceId":"antigravity","nativeThreadRef":{"driver":"antigravity","nativeId":"parent-sm"}}');
        INSERT INTO orchestration_v2_projection_runs VALUES
            ('run-sm', 'th-sm', 1, 'antigravity', 'completed', '\(iso.string(from: tStart))', '\(iso.string(from: tEnd))',
             '{"providerThreadId":"pt-sm","providerInstanceId":"antigravity"}');
        INSERT INTO orchestration_v2_projection_turn_items VALUES
            ('it-sm', 'th-sm', 'run-sm', 101, 'dynamic_tool', 'completed', '\(iso.string(from: tTool))',
             '{"toolName":"Run send_message","completedAt":"\(iso.string(from: tTool))","nativeItemRef":{"nativeId":"call_sm"},"input":{"Recipient":"\(recipientId)","Message":"check"}}');

        -- Case C: Killed RUNNING intermediate ancestor backfilled via PK -> MUST NOT reactivate root!
        INSERT INTO orchestration_v2_projection_threads VALUES
            ('th-killed', 'p1', 'Killed ancestor guard', 'antigravity', '\(iso.string(from: tStart))', '\(iso.string(from: tEnd))', NULL, NULL,
             '{"activeProviderThreadId":"pt-killed","providerInstanceId":"antigravity"}');
        INSERT INTO orchestration_v2_projection_provider_threads VALUES
            ('pt-killed', 'th-killed', 'antigravity', '{"providerInstanceId":"antigravity","nativeThreadRef":{"driver":"antigravity","nativeId":"root-killed"}}');
        INSERT INTO orchestration_v2_projection_runs VALUES
            ('run-killed', 'th-killed', 1, 'antigravity', 'completed', '\(iso.string(from: tStart))', '\(iso.string(from: tEnd))',
             '{"providerThreadId":"pt-killed","providerInstanceId":"antigravity"}');
        """
        XCTAssertEqual(sqlite3_exec(v2DB, v2Sql, nil, nil, nil), SQLITE_OK)

        let acpSql = """
        PRAGMA journal_mode=WAL;
        CREATE TABLE conversation_summaries (
            conversation_id TEXT PRIMARY KEY,
            parent_conversation_id TEXT NOT NULL DEFAULT '',
            status TEXT NOT NULL DEFAULT '',
            not_fully_idle INTEGER NOT NULL DEFAULT 0,
            killed INTEGER NOT NULL DEFAULT 0,
            last_modified_time TEXT NOT NULL
        );
        INSERT INTO conversation_summaries VALUES
            ('parent-cache', '', 'CASCADE_RUN_STATUS_RUNNING', 1, 0, '\(acpTS(tEnd))'),
            ('parent-sm', '', 'CASCADE_RUN_STATUS_IDLE', 0, 0, '\(acpTS(tEnd))'),
            -- Recipient subagent lastModified is OLDER than send_message toolCompletedAt -> has NOT finished new work yet!
            ('\(recipientId)', 'parent-sm', 'CASCADE_RUN_STATUS_IDLE', 0, 0, '\(acpTS(tStart))'),
            -- Killed intermediate RUNNING ancestor with IDLE root and IDLE leaf (backfilled by PK!)
            ('root-killed', '', 'CASCADE_RUN_STATUS_IDLE', 0, 0, '\(acpTS(tEnd))'),
            ('mid-killed', 'root-killed', 'CASCADE_RUN_STATUS_RUNNING', 1, 1, '\(acpTS(tEnd))'),
            ('leaf-idle', 'mid-killed', 'CASCADE_RUN_STATUS_IDLE', 0, 0, '\(acpTS(tEnd))'),
            -- Cycle A <-> B (must not infinite-loop or misattribute)
            ('cyc-a', 'cyc-b', 'CASCADE_RUN_STATUS_RUNNING', 1, 0, '\(acpTS(tEnd))'),
            ('cyc-b', 'cyc-a', 'CASCADE_RUN_STATUS_IDLE', 0, 0, '\(acpTS(tEnd))');
        """
        XCTAssertEqual(sqlite3_exec(acpDB, acpSql, nil, nil, nil), SQLITE_OK)

        let scanner = T3CodeScanner(
            v2DbPath: v2Path,
            v1DbPath: dir.appendingPathComponent("none.sqlite").path,
            antigravityProvidersRoot: providersRoot,
            handoffGraceSeconds: 150.0,
            acpIdleSeamSeconds: 12.0,
            launchTime: launch,
            isT3RunningCheck: { true }
        )

        // Tick at tEnd+0: parent-cache is RUNNING, parent-sm is held by 150s fallback, root-killed is .done (NOT reactivated by killed mid!)
        let s0 = scanner.scan(lookbackHours: 24, now: tEnd)
        XCTAssertEqual(s0.first(where: { $0.rawId == "th-cache" })?.status, .running)
        XCTAssertEqual(s0.first(where: { $0.rawId == "th-sm" })?.status, .running)
        XCTAssertEqual(s0.first(where: { $0.rawId == "th-killed" })?.status, .done)

        // Simulate cache-hit ticks from +1.5s to +10.5s (no DB writes!)
        for step in stride(from: 1.5, through: 10.5, by: 1.5) {
            let sHit = scanner.scan(lookbackHours: 24, now: tEnd.addingTimeInterval(step))
            XCTAssertEqual(sHit.first(where: { $0.rawId == "th-cache" })?.status, .running)
        }

        // At tEnd + 12.0s: parent-cache flips IDLE WITHOUT advancing last_modified_time!
        // Seam MUST start from first IDLE observation (tEnd + 12.0s -> expires at tEnd + 24.0s), NOT expire immediately!
        XCTAssertEqual(sqlite3_exec(acpDB, "UPDATE conversation_summaries SET status = 'CASCADE_RUN_STATUS_IDLE', not_fully_idle = 0 WHERE conversation_id = 'parent-cache';", nil, nil, nil), SQLITE_OK)

        let s12 = scanner.scan(lookbackHours: 24, now: tEnd.addingTimeInterval(12.0))
        XCTAssertEqual(s12.first(where: { $0.rawId == "th-cache" })?.status, .running, "First IDLE observation must start fresh 12s seam!")
        let s20 = scanner.scan(lookbackHours: 24, now: tEnd.addingTimeInterval(20.0))
        XCTAssertEqual(s20.first(where: { $0.rawId == "th-cache" })?.status, .running, "Must stay held inside 12s seam from first IDLE!")
        let s25 = scanner.scan(lookbackHours: 24, now: tEnd.addingTimeInterval(25.0))
        XCTAssertEqual(s25.first(where: { $0.rawId == "th-cache" })?.status, .done, "Must release after 12s seam from first IDLE!")

        // Case B: At tEnd + 30s (PAST 20s!) recipient still hasn't updated past tTool -> th-sm MUST STILL be .running under full 150s fallback!
        let s30 = scanner.scan(lookbackHours: 24, now: tEnd.addingTimeInterval(30.0))
        XCTAssertEqual(s30.first(where: { $0.rawId == "th-sm" })?.status, .running)

        // Once recipient finishes and updates last_modified_time >= tTool -> th-sm now has confirmed recipient IDLE and releases!
        XCTAssertEqual(sqlite3_exec(acpDB, "UPDATE conversation_summaries SET status = 'CASCADE_RUN_STATUS_IDLE', not_fully_idle = 0, last_modified_time = '\(acpTS(tEnd.addingTimeInterval(25)))' WHERE conversation_id = '\(recipientId)';", nil, nil, nil), SQLITE_OK)
        let s31 = scanner.scan(lookbackHours: 24, now: tEnd.addingTimeInterval(31.0))
        XCTAssertEqual(s31.first(where: { $0.rawId == "th-sm" })?.status, .done)

        // --- Case D: Run 42->43 dual-command shadow test where ACP is ALREADY IDLE/0 from tick 0 (NEVER sampled active!) ---
        // Order: (1) earlier verified background command (`ord=4201`, 15.5s, has `task-1380.log`),
        // followed by (2) a LATER 11s synchronous command (`ord=4202`, NO task log!) — the unverified later sync command
        // MUST NOT shadow the earlier verified background command!
        let bgTasksDir = "\(acpDir)/brain/parent-bg-never-active/.system_generated/tasks"
        try fm.createDirectory(atPath: bgTasksDir, withIntermediateDirectories: true)
        let tBgRunStart = tEnd.addingTimeInterval(40)
        let tBgCmdStart = tEnd.addingTimeInterval(42)
        let tBgCmdEnd = tEnd.addingTimeInterval(57.5)      // 15.5s backgrounded command (`task-1380.log`)
        let tLaterSyncStart = tEnd.addingTimeInterval(60)  // later 11s synchronous command (window starts +58.0s > +57.5s task log!)
        let tLaterSyncEnd = tEnd.addingTimeInterval(71.0)
        let tBgRunEnd = tEnd.addingTimeInterval(73.4)      // 15.9s after bg cmd, 2.4s after later sync cmd
        let taskLogPath = "\(bgTasksDir)/task-1380.log"
        try "background command output".write(toFile: taskLogPath, atomically: true, encoding: .utf8)
        try fm.setAttributes([.modificationDate: tBgCmdEnd], ofItemAtPath: taskLogPath)

        XCTAssertEqual(sqlite3_exec(v2DB, """
            INSERT INTO orchestration_v2_projection_threads VALUES
                ('th-bg-idle', 'p1', 'Run 42 dual-cmd never-sampled ACP', 'antigravity', '\(iso.string(from: tBgRunStart))', '\(iso.string(from: tBgRunEnd))', NULL, NULL,
                 '{"activeProviderThreadId":"pt-bgi","providerInstanceId":"antigravity"}'),
                ('th-sync-cmd', 'p1', 'Sync 1.5s cmd', 'antigravity', '\(iso.string(from: tBgRunStart))', '\(iso.string(from: tBgRunEnd))', NULL, NULL,
                 '{"activeProviderThreadId":"pt-sync","providerInstanceId":"antigravity"}');
            INSERT INTO orchestration_v2_projection_provider_threads VALUES
                ('pt-bgi', 'th-bg-idle', 'antigravity', '{"providerInstanceId":"antigravity","nativeThreadRef":{"driver":"antigravity","nativeId":"parent-bg-never-active"}}'),
                ('pt-sync', 'th-sync-cmd', 'antigravity', '{"providerInstanceId":"antigravity","nativeThreadRef":{"driver":"antigravity","nativeId":"parent-sync"}}');
            INSERT INTO orchestration_v2_projection_runs VALUES
                ('run-bg-42', 'th-bg-idle', 42, 'antigravity', 'completed', '\(iso.string(from: tBgRunStart))', '\(iso.string(from: tBgRunEnd))',
                 '{"providerThreadId":"pt-bgi","providerInstanceId":"antigravity"}'),
                ('run-sync', 'th-sync-cmd', 1, 'antigravity', 'completed', '\(iso.string(from: tBgRunStart))', '\(iso.string(from: tBgRunEnd))',
                 '{"providerThreadId":"pt-sync","providerInstanceId":"antigravity"}');
            INSERT INTO orchestration_v2_projection_turn_items VALUES
                ('it-bg-cmd', 'th-bg-idle', 'run-bg-42', 4201, 'command_execution', 'completed', '\(iso.string(from: tBgCmdEnd))',
                 '{"startedAt":"\(iso.string(from: tBgCmdStart))","completedAt":"\(iso.string(from: tBgCmdEnd))","nativeItemRef":{"nativeId":"call_bg_42"}}'),
                ('it-later-sync', 'th-bg-idle', 'run-bg-42', 4202, 'command_execution', 'completed', '\(iso.string(from: tLaterSyncEnd))',
                 '{"startedAt":"\(iso.string(from: tLaterSyncStart))","completedAt":"\(iso.string(from: tLaterSyncEnd))","nativeItemRef":{"nativeId":"call_later_sync"}}'),
                ('it-sync-cmd', 'th-sync-cmd', 'run-sync', 101, 'command_execution', 'completed', '\(iso.string(from: tBgCmdEnd))',
                 '{"startedAt":"\(iso.string(from: tBgCmdEnd.addingTimeInterval(-1.5)))","completedAt":"\(iso.string(from: tBgCmdEnd))","nativeItemRef":{"nativeId":"call_sync"}}');
            """, nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(acpDB, """
            INSERT INTO conversation_summaries VALUES
                ('parent-bg-never-active', '', 'CASCADE_RUN_STATUS_IDLE', 0, 0, '\(acpTS(tBgRunEnd))'),
                ('parent-sync', '', 'CASCADE_RUN_STATUS_IDLE', 0, 0, '\(acpTS(tBgRunEnd))');
            """, nil, nil, nil), SQLITE_OK)

        let bgStore = MonitorStore(statePath: dir.appendingPathComponent("read_state_bg.json").path, launchTime: launch, suppressSystemSideEffects: true)
        bgStore.applyScanned([], now: launch)

        // Tick every 1.5s across the 14.07s gap until Run 43 starts at +14.1s and finishes at +21s!
        // th-sync-cmd (normal 1.5s sync cmd) MUST confirm right after 4.5s; th-bg-idle MUST stay held until Run 43 completes!
        var bgOffset: TimeInterval = 1.5
        var didInsert43 = false
        var didComplete43 = false
        while bgOffset <= 27.0 {
            let tickNow = tBgRunEnd.addingTimeInterval(bgOffset)
            if !didInsert43 && bgOffset >= 14.1 {
                didInsert43 = true
                XCTAssertEqual(sqlite3_exec(v2DB, """
                    INSERT INTO orchestration_v2_projection_runs VALUES
                        ('run-bg-43', 'th-bg-idle', 43, 'antigravity', 'running', '\(iso.string(from: tickNow))', NULL, '{"providerThreadId":"pt-bgi","providerInstanceId":"antigravity"}');
                    UPDATE orchestration_v2_projection_threads SET updated_at = '\(iso.string(from: tickNow))' WHERE thread_id = 'th-bg-idle';
                    """, nil, nil, nil), SQLITE_OK)
            }
            if !didComplete43 && bgOffset >= 21.0 {
                didComplete43 = true
                XCTAssertEqual(sqlite3_exec(v2DB, """
                    UPDATE orchestration_v2_projection_runs SET status = 'completed', completed_at = '\(iso.string(from: tickNow))' WHERE run_id = 'run-bg-43';
                    UPDATE orchestration_v2_projection_threads SET updated_at = '\(iso.string(from: tickNow))' WHERE thread_id = 'th-bg-idle';
                    """, nil, nil, nil), SQLITE_OK)
            }
            let r = scanner.scanDetailed(lookbackHours: 24, now: tickNow, forceFresh: true)
            bgStore.applyScanned(r.sessions, now: tickNow)
            if bgOffset < 21.0 {
                XCTAssertFalse(bgStore.confirmedCompletionIds.contains("t3code:th-bg-idle"), "Premature popup on never-sampled-active Run 42 at +\(bgOffset)s")
            }
            bgOffset += 1.5
        }
        XCTAssertTrue(bgStore.confirmedCompletionIds.contains("t3code:th-sync-cmd"), "Normal 1.5s sync command must confirm without extra delay!")
        XCTAssertEqual(bgStore.confirmedCompletionIds.filter { $0 == "t3code:th-bg-idle" }.count, 1)

        // --- Case E: `forceFresh: true` bypasses `terminalRunDetailCache` when an approval item is appended to a freshly completed run ---
        XCTAssertEqual(sqlite3_exec(v2DB, """
            INSERT INTO orchestration_v2_projection_turn_items VALUES
                ('it-late-appr', 'th-sync-cmd', 'run-sync', 102, 'approval_request', 'pending', '\(iso.string(from: tBgRunEnd.addingTimeInterval(28)))',
                 '{"command":"deploy"}');
            """, nil, nil, nil), SQLITE_OK)
        let rLateAppr = scanner.scanDetailed(lookbackHours: 24, now: tBgRunEnd.addingTimeInterval(28), forceFresh: true)
        XCTAssertEqual(rLateAppr.sessions.first(where: { $0.rawId == "th-sync-cmd" })?.status, .needsInput, "forceFresh must bypass terminalRunDetailCache!")

        XCTAssertEqual(sqlite3_close(v2DB), SQLITE_OK)
        XCTAssertEqual(sqlite3_close(acpDB), SQLITE_OK)
    }
}
