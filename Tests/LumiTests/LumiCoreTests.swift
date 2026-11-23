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
        XCTAssertTrue(ok)
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
}
