import AppKit
import Foundation

struct T3PendingMatch: Equatable, Sendable {
    let providerKey: String
    let normalizedCwd: String
    let startedAt: Date
}

struct T3CodeScanResult: Sendable {
    let sessions: [AgentSession]
    /// Exact `"<provider>:<nativeId>"` keys of underlying provider sessions owned by T3 Code runs.
    let ownedNativeSessionIds: Set<String>
    /// Active T3 Code runs whose `nativeThreadRef` has not yet been written (first-second race window).
    let pendingMatches: [T3PendingMatch]

    func ownsUnderlying(_ session: AgentSession) -> Bool {
        guard session.kind != .t3code else { return false }
        if ownedNativeSessionIds.contains(session.id) {
            return true
        }
        let canonical = "\(session.kind.rawValue):\(session.rawId)"
        if ownedNativeSessionIds.contains(canonical) {
            return true
        }
        let normCwd = T3CodeScanner.normalizePath(session.cwd)
        if normCwd.contains("/.t3/scratch")
            || normCwd.contains("/.t3/worktrees")
            || normCwd.contains("/.t3/userdata") {
            return true
        }
        if !pendingMatches.isEmpty, !normCwd.isEmpty {
            let refTime = session.startedAt ?? session.updatedAt
            for pm in pendingMatches where pm.providerKey == session.kind.rawValue && pm.normalizedCwd == normCwd {
                if abs(refTime.timeIntervalSince(pm.startedAt)) <= 20 {
                    return true
                }
            }
        }
        return false
    }
}

/// Zero-config live monitor for T3 Code (Desktop & CLI) reading its local SQLite WAL control plane:
/// - Orchestration v2 (T3 Code v0.1.7+): `~/.t3/userdata/statev2.sqlite`
/// - Legacy v1 fallback: `~/.t3/userdata/state.sqlite`
final class T3CodeScanner: @unchecked Sendable {
    private let v2DbPath: String
    private let v1DbPath: String
    private let environmentIdPath: String
    private let isT3RunningCheck: @Sendable () -> Bool

    private static let pathSegmentAllowedCharacters: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-_.~")
        return set
    }()

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

    init(
        v2DbPath: String = "\(NSHomeDirectory())/.t3/userdata/statev2.sqlite",
        v1DbPath: String = "\(NSHomeDirectory())/.t3/userdata/state.sqlite",
        environmentIdPath: String? = nil,
        isT3RunningCheck: (@Sendable () -> Bool)? = nil
    ) {
        self.v2DbPath = v2DbPath
        self.v1DbPath = v1DbPath
        self.environmentIdPath = environmentIdPath ?? URL(fileURLWithPath: v2DbPath)
            .deletingLastPathComponent()
            .appendingPathComponent("environment-id")
            .path
        self.isT3RunningCheck = isT3RunningCheck ?? {
            Self.isT3CodeAppRunning()
        }
    }

    func readEnvironmentId() -> String? {
        guard let raw = try? String(contentsOfFile: environmentIdPath, encoding: .utf8) else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Builds T3 Code's official `t3code://threads/<environmentId>/<encodedThreadId>` deep link
    /// (parsed by T3 Code's `promptLinkAppPath` -> `DesktopWebLinks.receive` -> `/$environmentId/$threadId`).
    static func deepLinkURL(environmentId: String, threadId: String, scheme: String = "t3code") -> URL? {
        let env = environmentId.trimmingCharacters(in: .whitespacesAndNewlines)
        let tid = threadId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !env.isEmpty, !tid.isEmpty,
              let encodedEnv = env.addingPercentEncoding(withAllowedCharacters: pathSegmentAllowedCharacters),
              let encodedTid = tid.addingPercentEncoding(withAllowedCharacters: pathSegmentAllowedCharacters) else {
            return nil
        }
        return URL(string: "\(scheme)://threads/\(encodedEnv)/\(encodedTid)")
    }

    func deepLinkURL(forThreadId threadId: String, scheme: String? = nil) -> URL? {
        guard let envId = readEnvironmentId() else { return nil }
        let resolvedScheme = scheme ?? Self.preferredURLScheme()
        return Self.deepLinkURL(environmentId: envId, threadId: threadId, scheme: resolvedScheme)
    }

    private static func preferredURLScheme() -> String {
        let prodRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: "com.t3tools.t3code").isEmpty
        if prodRunning { return "t3code" }
        let devRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: "com.t3tools.t3code.dev").isEmpty
        if devRunning { return "t3code-dev" }
        if NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.t3tools.t3code") != nil {
            return "t3code"
        }
        if NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.t3tools.t3code.dev") != nil {
            return "t3code-dev"
        }
        return "t3code"
    }

    func scan(lookbackHours: Double = 24, now: Date = Date()) -> [AgentSession] {
        scanDetailed(lookbackHours: lookbackHours, now: now).sessions
    }

    func scanDetailed(lookbackHours: Double = 24, now: Date = Date()) -> T3CodeScanResult {
        var results: [AgentSession] = []
        var seenThreadIds = Set<String>()
        var ownedNativeIds = Set<String>()
        var pendingMatches: [T3PendingMatch] = []

        if let v2 = SQLiteReader(path: v2DbPath) {
            let v2Res = scanV2(reader: v2, lookbackHours: lookbackHours, now: now)
            for s in v2Res.sessions {
                seenThreadIds.insert(s.rawId)
                results.append(s)
            }
            ownedNativeIds.formUnion(v2Res.ownedNativeSessionIds)
            pendingMatches.append(contentsOf: v2Res.pendingMatches)
        }

        if let v1 = SQLiteReader(path: v1DbPath) {
            let v1Sessions = scanV1(reader: v1, excluding: seenThreadIds, lookbackHours: lookbackHours, now: now)
            results.append(contentsOf: v1Sessions)
        }

        return T3CodeScanResult(
            sessions: results,
            ownedNativeSessionIds: ownedNativeIds,
            pendingMatches: pendingMatches
        )
    }

    // MARK: - Orchestration v2 (statev2.sqlite)

    private struct V2Project {
        let title: String
        let workspaceRoot: String
    }

    private struct V2Thread {
        let threadId: String
        let projectId: String
        let title: String
        let defaultProvider: String
        let createdAt: Date
        let updatedAt: Date
        let worktreePath: String
        let parentThreadId: String?
        let rootThreadId: String?
    }

    private struct V2Run {
        let runId: String
        let threadId: String
        let ordinal: Int
        let provider: String
        let status: String
        let requestedAt: Date?
        let completedAt: Date?
    }

    private struct V2RunDetail {
        var hasPendingApproval: Bool = false
        var pendingPrompt: String = ""
        var activeSubagents: Int = 0
        var latestAction: String = ""
        var latestActivityAt: Date?
    }

    private func scanV2(reader: SQLiteReader, lookbackHours: Double, now: Date) -> T3CodeScanResult {
        let cutoff = now.addingTimeInterval(-lookbackHours * 3600)
        let appRunning = isT3RunningCheck()

        // 1. Projects map
        var projects: [String: V2Project] = [:]
        reader.query("SELECT project_id, title, workspace_root FROM projection_projects;") { stmt in
            let pid = SQLiteReader.string(stmt, 0)
            let title = SQLiteReader.string(stmt, 1)
            let root = SQLiteReader.string(stmt, 2)
            if !pid.isEmpty {
                projects[pid] = V2Project(title: title, workspaceRoot: root)
            }
        }

        // 2. Latest run per thread
        var latestRuns: [String: V2Run] = [:]
        reader.query("""
            SELECT run_id, thread_id, ordinal, provider, status, requested_at, completed_at
            FROM orchestration_v2_projection_runs
            ORDER BY thread_id ASC, ordinal DESC, requested_at DESC;
            """) { stmt in
            let tid = SQLiteReader.string(stmt, 1)
            guard !tid.isEmpty, latestRuns[tid] == nil else { return }
            latestRuns[tid] = V2Run(
                runId: SQLiteReader.string(stmt, 0),
                threadId: tid,
                ordinal: SQLiteReader.int(stmt, 2),
                provider: SQLiteReader.string(stmt, 3),
                status: SQLiteReader.string(stmt, 4).lowercased(),
                requestedAt: Self.parseISO(SQLiteReader.string(stmt, 5)),
                completedAt: Self.parseISO(SQLiteReader.string(stmt, 6))
            )
        }

        // 3. Active provider runtimes (catches imported threads actively resumed inside T3 Code)
        var runningRuntimeThreads = Set<String>()
        reader.query("""
            SELECT thread_id, status
            FROM provider_session_runtime
            WHERE lower(status) IN ('running', 'starting', 'busy', 'waiting', 'waiting_for_approval', 'waiting_for_input');
            """) { stmt in
            let tid = SQLiteReader.string(stmt, 0)
            if !tid.isEmpty { runningRuntimeThreads.insert(tid) }
        }

        // 4. Threads (non-deleted, non-archived)
        var threads: [V2Thread] = []
        reader.query("""
            SELECT thread_id, project_id, title, default_provider, created_at, updated_at, payload_json
            FROM orchestration_v2_projection_threads
            WHERE deleted_at IS NULL AND archived_at IS NULL
            ORDER BY updated_at DESC
            LIMIT 80;
            """) { stmt in
            let tid = SQLiteReader.string(stmt, 0)
            guard !tid.isEmpty else { return }
            let payloadStr = SQLiteReader.string(stmt, 6)
            let payload = Self.parseJSONObject(payloadStr)
            let worktree = payload["worktreePath"] as? String ?? ""
            let lineage = payload["lineage"] as? [String: Any]
            let parentTid = lineage?["parentThreadId"] as? String
            let rootTid = lineage?["rootThreadId"] as? String

            let createdAt = Self.parseISO(SQLiteReader.string(stmt, 4)) ?? now
            let updatedAt = Self.parseISO(SQLiteReader.string(stmt, 5)) ?? createdAt
            threads.append(V2Thread(
                threadId: tid,
                projectId: SQLiteReader.string(stmt, 1),
                title: SQLiteReader.string(stmt, 2),
                defaultProvider: SQLiteReader.string(stmt, 3),
                createdAt: createdAt,
                updatedAt: updatedAt,
                worktreePath: worktree,
                parentThreadId: (parentTid?.isEmpty == false) ? parentTid : nil,
                rootThreadId: (rootTid?.isEmpty == false) ? rootTid : nil
            ))
        }

        // Separate root threads vs child subagent threads so child runs roll up cleanly onto their root thread
        var childRunningByRoot: [String: Int] = [:]
        var childNeedsInputByRoot: [String: String] = [:]
        var rootThreads: [V2Thread] = []

        for th in threads {
            if let parentId = th.parentThreadId {
                let rootKey = th.rootThreadId ?? parentId
                if let run = latestRuns[th.threadId] {
                    if Self.isWaitingRunStatus(run.status) {
                        childNeedsInputByRoot[rootKey] = "等待你的审批或回复"
                    } else if Self.isActiveRunStatus(run.status) {
                        childRunningByRoot[rootKey, default: 0] += 1
                    }
                }
                continue
            }
            rootThreads.append(th)
        }

        // 5. Inspect nodes & turn items only for recent or active runs (keeps idle scan near 0% CPU)
        var runDetails: [String: V2RunDetail] = [:]
        for th in rootThreads {
            guard let run = latestRuns[th.threadId] else { continue }
            let isPotentiallyActive = Self.isActiveRunStatus(run.status) || Self.isWaitingRunStatus(run.status) || runningRuntimeThreads.contains(th.threadId)
            guard isPotentiallyActive || th.updatedAt >= cutoff else { continue }
            runDetails[run.runId] = inspectV2Run(reader: reader, runId: run.runId)
        }

        // 5b. Map T3-owned threads to their underlying provider native session IDs
        // (e.g. `nativeThreadRef: { driver: "codex", nativeId: "01a20458-..." }`)
        // so Lumi suppresses duplicate alerts from Codex/Claude/Antigravity scanners.
        var ownedNativeIds = Set<String>()
        var threadsWithNativeRef = Set<String>()
        let ownedThreadIds = Set(
            threads
                .filter { !$0.threadId.hasPrefix("import:") || latestRuns[$0.threadId] != nil || runningRuntimeThreads.contains($0.threadId) }
                .map(\.threadId)
        )
        reader.query("""
            SELECT thread_id, provider, payload_json
            FROM orchestration_v2_projection_provider_threads;
            """) { stmt in
            let tid = SQLiteReader.string(stmt, 0)
            guard !tid.isEmpty, ownedThreadIds.contains(tid) || latestRuns[tid] != nil else { return }
            let colProvider = SQLiteReader.string(stmt, 1)
            let payload = Self.parseJSONObject(SQLiteReader.string(stmt, 2))
            if let ref = payload["nativeThreadRef"] as? [String: Any],
               let nativeId = ref["nativeId"] as? String,
               !nativeId.isEmpty,
               !nativeId.hasPrefix("pending:") {
                let rawDriver = (ref["driver"] as? String) ?? colProvider
                if let key = Self.normalizeProviderKey(rawDriver) {
                    ownedNativeIds.insert("\(key):\(nativeId)")
                    threadsWithNativeRef.insert(tid)
                }
            }
        }

        // Also check provider_session_runtime resume_cursor_json for any active/run-backed T3 thread
        reader.query("""
            SELECT thread_id, provider_name, resume_cursor_json
            FROM provider_session_runtime;
            """) { stmt in
            let tid = SQLiteReader.string(stmt, 0)
            guard !tid.isEmpty, ownedThreadIds.contains(tid) else { return }
            let rawProvider = SQLiteReader.string(stmt, 1)
            let cursor = Self.parseJSONObject(SQLiteReader.string(stmt, 2))
            if let nativeId = (cursor["threadId"] as? String) ?? (cursor["sessionId"] as? String),
               !nativeId.isEmpty,
               !nativeId.hasPrefix("pending:"),
               let key = Self.normalizeProviderKey(rawProvider) {
                ownedNativeIds.insert("\(key):\(nativeId)")
                threadsWithNativeRef.insert(tid)
            }
        }

        // 6. Build AgentSession list
        var sessions: [AgentSession] = []
        var pendingMatches: [T3PendingMatch] = []
        for th in rootThreads {
            let run = latestRuns[th.threadId]
            let runtimeActive = runningRuntimeThreads.contains(th.threadId)

            // Skip untouched imported threads (e.g. `import:codex:<uuid>`) that have never run in T3 Code,
            // preventing duplicates of threads already shown by CodexScanner / ClaudeScanner.
            if th.threadId.hasPrefix("import:") && run == nil && !runtimeActive {
                continue
            }

            let detail = run.flatMap { runDetails[$0.runId] } ?? V2RunDetail()
            let childRunning = childRunningByRoot[th.threadId] ?? 0
            let childNeedsPrompt = childNeedsInputByRoot[th.threadId]

            let activityCandidates: [Date] = [th.updatedAt, run?.requestedAt, run?.completedAt, detail.latestActivityAt].compactMap { $0 }
            let latestActivity = activityCandidates.max() ?? th.updatedAt

            // Determine raw status
            var status: SessionStatus
            var action: String

            if let childPrompt = childNeedsPrompt {
                status = .needsInput
                action = childPrompt
            } else if detail.hasPendingApproval {
                status = .needsInput
                action = detail.pendingPrompt.isEmpty ? "等待你的审批或回复" : detail.pendingPrompt
            } else if let run {
                if Self.isWaitingRunStatus(run.status) {
                    status = .needsInput
                    action = detail.pendingPrompt.isEmpty ? "等待你的审批或回复" : detail.pendingPrompt
                } else if Self.isActiveRunStatus(run.status) {
                    status = .running
                    action = detail.latestAction.isEmpty ? "思考与执行中…" : detail.latestAction
                } else if run.status == "failed" || run.status == "error" {
                    status = .error
                    action = "执行出错"
                } else if run.status == "cancelled" || run.status == "canceled" || run.status == "interrupted" {
                    status = .canceled
                    action = "已手动停止"
                } else {
                    status = .done
                    action = "已完成"
                }
            } else if runtimeActive {
                status = .running
                action = "执行中…"
            } else {
                status = .done
                action = "已完成"
            }

            // Roll up active child threads onto an idle parent thread
            if status == .done && childRunning > 0 {
                status = .running
                action = "等待 \(childRunning) 个子 Agent 执行…"
            }

            // Stale guard if T3 Code crashed / was quit mid-run leaving an unclosed row in SQLite
            let idleAge = now.timeIntervalSince(latestActivity)
            if status == .running && !appRunning && idleAge > 180 {
                status = .done
                action = "已完成"
            } else if status == .running && idleAge > 900 {
                status = .done
                action = "已完成"
            } else if status == .needsInput && !appRunning && idleAge > 600 {
                status = .done
                action = "已完成"
            }

            let isActive = (status == .running || status == .needsInput)
            guard isActive || latestActivity >= cutoff else { continue }

            let proj = projects[th.projectId]
            let cwd = !th.worktreePath.isEmpty ? th.worktreePath : (proj?.workspaceRoot ?? "")
            let projectName = Self.resolveProjectName(project: proj, worktreePath: th.worktreePath)
            let cleanTitle = ProjectNameHelper.cleanOneLine(th.title, maxLength: 78)
            let displayTitle = cleanTitle.isEmpty ? (projectName.isEmpty ? "T3 Code 对话" : projectName) : cleanTitle

            let startedAt = run?.requestedAt ?? th.createdAt
            let completedAt: Date? = isActive ? nil : (run?.completedAt ?? latestActivity)
            let durationSec: TimeInterval? = {
                guard !isActive, let s = run?.requestedAt, let c = completedAt else { return nil }
                let d = c.timeIntervalSince(s)
                return d >= 0 ? d : nil
            }()

            let activeSubs = max(detail.activeSubagents, childRunning)

            if isActive,
               !threadsWithNativeRef.contains(th.threadId),
               let provKey = Self.normalizeProviderKey(run?.provider ?? th.defaultProvider),
               !cwd.isEmpty {
                pendingMatches.append(T3PendingMatch(
                    providerKey: provKey,
                    normalizedCwd: Self.normalizePath(cwd),
                    startedAt: startedAt
                ))
            }

            sessions.append(AgentSession(
                id: "t3code:\(th.threadId)",
                rawId: th.threadId,
                kind: .t3code,
                title: displayTitle,
                project: projectName,
                cwd: cwd,
                isCLI: false,
                status: status,
                currentAction: action,
                detailSummary: "",
                startedAt: startedAt,
                updatedAt: latestActivity,
                completedAt: completedAt,
                durationSec: durationSec,
                activeSubagents: activeSubs,
                isUnread: false
            ))
        }

        return T3CodeScanResult(
            sessions: sessions,
            ownedNativeSessionIds: ownedNativeIds,
            pendingMatches: pendingMatches
        )
    }

    private func inspectV2Run(reader: SQLiteReader, runId: String) -> V2RunDetail {
        var detail = V2RunDetail()
        let escapedRunId = Self.sqlLiteral(runId)

        // Check active/waiting nodes (approvals, user input, subagents)
        reader.query("""
            SELECT kind, status, started_at, completed_at, payload_json
            FROM orchestration_v2_projection_nodes
            WHERE run_id = \(escapedRunId)
            ORDER BY rowid DESC
            LIMIT 40;
            """) { stmt in
            let kind = SQLiteReader.string(stmt, 0).lowercased()
            let st = SQLiteReader.string(stmt, 1).lowercased()
            let startedAt = Self.parseISO(SQLiteReader.string(stmt, 2))
            let completedStr = SQLiteReader.string(stmt, 3)
            let isUnfinished = completedStr.isEmpty

            if let s = startedAt, detail.latestActivityAt == nil || s > detail.latestActivityAt! {
                detail.latestActivityAt = s
            }

            if isUnfinished && (kind == "approval_request" || kind == "user_input_request" || Self.isWaitingRunStatus(st)) {
                detail.hasPendingApproval = true
                if detail.pendingPrompt.isEmpty {
                    let payload = Self.parseJSONObject(SQLiteReader.string(stmt, 4))
                    detail.pendingPrompt = Self.extractApprovalAction(kind: kind, payload: payload)
                }
            } else if isUnfinished && kind == "subagent" && (Self.isActiveRunStatus(st) || Self.isWaitingRunStatus(st) || st == "pending") {
                detail.activeSubagents += 1
            }
        }

        // Check recent turn items for latest live tool action + uncompleted approval/user_input items
        reader.query("""
            SELECT type, status, updated_at, payload_json
            FROM orchestration_v2_projection_turn_items
            WHERE run_id = \(escapedRunId)
            ORDER BY ordinal DESC, rowid DESC
            LIMIT 12;
            """) { stmt in
            let itemType = SQLiteReader.string(stmt, 0).lowercased()
            let st = SQLiteReader.string(stmt, 1).lowercased()
            let updatedAt = Self.parseISO(SQLiteReader.string(stmt, 2))
            let payloadStr = SQLiteReader.string(stmt, 3)

            if let u = updatedAt, detail.latestActivityAt == nil || u > detail.latestActivityAt! {
                detail.latestActivityAt = u
            }

            let isTerminalItem = ["completed", "resolved", "approved", "denied", "rejected", "cancelled", "canceled", "failed", "interrupted"].contains(st)
            if (itemType == "approval_request" || itemType == "user_input_request") && !isTerminalItem {
                detail.hasPendingApproval = true
                if detail.pendingPrompt.isEmpty {
                    let payload = Self.parseJSONObject(payloadStr)
                    detail.pendingPrompt = Self.extractApprovalAction(kind: itemType, payload: payload)
                }
            }

            if detail.latestAction.isEmpty && itemType != "user_message" && itemType != "checkpoint" && itemType != "system_notice" {
                let payload = Self.parseJSONObject(payloadStr)
                let described = Self.describeTurnItem(type: itemType, payload: payload)
                if !described.isEmpty {
                    detail.latestAction = described
                }
            }
        }

        return detail
    }

    // MARK: - Legacy T3 Code v1 (state.sqlite) Fallback

    private func scanV1(reader: SQLiteReader, excluding seen: Set<String>, lookbackHours: Double, now: Date) -> [AgentSession] {
        let cutoff = now.addingTimeInterval(-lookbackHours * 3600)
        var projects: [String: V2Project] = [:]
        reader.query("SELECT project_id, title, workspace_root FROM projection_projects;") { stmt in
            let pid = SQLiteReader.string(stmt, 0)
            if !pid.isEmpty {
                projects[pid] = V2Project(title: SQLiteReader.string(stmt, 1), workspaceRoot: SQLiteReader.string(stmt, 2))
            }
        }

        var results: [AgentSession] = []
        reader.query("""
            SELECT thread_id, project_id, title, worktree_path, created_at, updated_at,
                   pending_approval_count, pending_user_input_count
            FROM projection_threads
            WHERE deleted_at IS NULL AND archived_at IS NULL
            ORDER BY updated_at DESC
            LIMIT 50;
            """) { stmt in
            let tid = SQLiteReader.string(stmt, 0)
            guard !tid.isEmpty, !seen.contains(tid) else { return }
            let updatedAt = Self.parseISO(SQLiteReader.string(stmt, 5)) ?? now
            let pendingApprovals = SQLiteReader.int(stmt, 6)
            let pendingInputs = SQLiteReader.int(stmt, 7)
            let needsInput = pendingApprovals > 0 || pendingInputs > 0
            guard needsInput || updatedAt >= cutoff else { return }

            let proj = projects[SQLiteReader.string(stmt, 1)]
            let worktree = SQLiteReader.string(stmt, 3)
            let projectName = Self.resolveProjectName(project: proj, worktreePath: worktree)
            let cleanTitle = ProjectNameHelper.cleanOneLine(SQLiteReader.string(stmt, 2), maxLength: 78)

            results.append(AgentSession(
                id: "t3code:\(tid)",
                rawId: tid,
                kind: .t3code,
                title: cleanTitle.isEmpty ? "T3 Code 对话" : cleanTitle,
                project: projectName,
                cwd: !worktree.isEmpty ? worktree : (proj?.workspaceRoot ?? ""),
                isCLI: false,
                status: needsInput ? .needsInput : .done,
                currentAction: needsInput ? "等待你的审批或回复" : "已完成",
                detailSummary: "",
                startedAt: Self.parseISO(SQLiteReader.string(stmt, 4)),
                updatedAt: updatedAt,
                completedAt: needsInput ? nil : updatedAt,
                durationSec: nil,
                activeSubagents: 0,
                isUnread: false
            ))
        }
        return results
    }

    // MARK: - Formatting & Helpers

    private static func isActiveRunStatus(_ s: String) -> Bool {
        s == "running" || s == "starting" || s == "queued" || s == "in_progress"
    }

    private static func isWaitingRunStatus(_ s: String) -> Bool {
        s == "waiting" || s == "waiting_for_approval" || s == "waiting_for_input" || s == "pending_approval" || s == "needs_input"
    }

    private static func resolveProjectName(project: V2Project?, worktreePath: String) -> String {
        if let title = project?.title.trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty,
           title.lowercased() != "no project" {
            return title
        }
        if !worktreePath.isEmpty && !worktreePath.contains("/.t3/scratch") {
            let derived = ProjectNameHelper.projectName(from: worktreePath)
            if !derived.isEmpty { return derived }
        }
        if let root = project?.workspaceRoot, !root.isEmpty && !root.contains("/.t3/scratch") {
            let derived = ProjectNameHelper.projectName(from: root)
            if !derived.isEmpty { return derived }
        }
        return "独立对话"
    }

    private static func extractApprovalAction(kind: String, payload: [String: Any]) -> String {
        let candidates = [
            payload["prompt"] as? String,
            payload["question"] as? String,
            payload["command"] as? String,
            payload["title"] as? String,
            payload["message"] as? String
        ].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }

        if let first = candidates.first {
            let clean = ProjectNameHelper.cleanOneLine(first, maxLength: 36)
            if !clean.isEmpty {
                return "等待确认 · \(clean)"
            }
        }
        return kind == "user_input_request" ? "等待你确认/回答" : "等待你的审批或回复"
    }

    private static func describeTurnItem(type: String, payload: [String: Any]) -> String {
        let title = (payload["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        switch type {
        case "command_execution":
            let cmd = (payload["input"] as? String ?? payload["command"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !cmd.isEmpty {
                return ToolActionFormatter.describe(name: "exec", rawInput: cmd)
            }
            return "运行终端命令"
        case "file_search":
            return "检索代码"
        case "file_change", "file_edit", "patch":
            let path = payload["path"] as? String ?? payload["filePath"] as? String ?? ""
            if !path.isEmpty {
                return "编辑 \((path as NSString).lastPathComponent)"
            }
            return "修改代码文件"
        case "dynamic_tool", "mcp_tool", "tool_call":
            let toolName = payload["toolName"] as? String ?? payload["name"] as? String ?? title
            let rawInput = payload["input"] as? String ?? ""
            if !toolName.isEmpty {
                return ToolActionFormatter.describe(name: toolName, rawInput: rawInput)
            }
            return "执行工具中…"
        case "reasoning":
            return "深度思考中…"
        case "assistant_message":
            return "输出回复中…"
        case "approval_request":
            return extractApprovalAction(kind: "approval_request", payload: payload)
        case "user_input_request":
            return extractApprovalAction(kind: "user_input_request", payload: payload)
        default:
            return title.isEmpty ? "执行中…" : ProjectNameHelper.cleanOneLine(title, maxLength: 36)
        }
    }

    private static func parseJSONObject(_ raw: String) -> [String: Any] {
        guard !raw.isEmpty,
              let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return obj
    }

    private static func parseISO(_ raw: String) -> Date? {
        guard !raw.isEmpty else { return nil }
        return isoFracFormatter.date(from: raw) ?? isoBasicFormatter.date(from: raw)
    }

    private static func sqlLiteral(_ s: String) -> String {
        "'\(s.replacingOccurrences(of: "'", with: "''"))'"
    }

    private static func isT3CodeAppRunning() -> Bool {
        for bid in ["com.t3tools.t3code", "com.t3tools.t3code.dev"] {
            if !NSRunningApplication.runningApplications(withBundleIdentifier: bid).isEmpty {
                return true
            }
        }
        return false
    }

    static func normalizeProviderKey(_ raw: String) -> String? {
        let low = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if low.isEmpty { return nil }
        if low.contains("codex") || low.contains("openai") { return AgentKind.codex.rawValue }
        if low.contains("claude") || low.contains("anthropic") { return AgentKind.claude.rawValue }
        if low.contains("antigravity") || low.contains("agy") { return AgentKind.antigravity.rawValue }
        if low.contains("cursor") { return AgentKind.cursor.rawValue }
        if low.contains("gemini") { return AgentKind.gemini.rawValue }
        if low.contains("opencode") { return AgentKind.opencode.rawValue }
        return nil
    }

    static func normalizePath(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("file://"), let url = URL(string: s) {
            s = url.path
        }
        while s.count > 1 && s.hasSuffix("/") {
            s.removeLast()
        }
        return s
    }
}
