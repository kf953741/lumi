import Darwin
import Foundation

public struct CodexRolloutState: Equatable, Sendable {
    public let status: SessionStatus
    public let currentAction: String
    public let lastAgentMessage: String
    public let startedAt: Date?
    public let completedAt: Date?
    public let durationSec: TimeInterval?
    public let cwd: String
}

public enum CodexRolloutParser {
    /// Parses the tail lines of a Codex rollout JSONL file.
    /// Safe for long-running turns (>256KB) where `task_started` has scrolled off the tail window.
    public static func parse(lines: [String], mtime: Date, now: Date) -> CodexRolloutState {
        var status: SessionStatus? = nil
        var currentAction = ""
        var lastAgentMessage = ""
        var startedAt: Date?
        var completedAt: Date?
        var durationSec: TimeInterval?
        var cwd = ""

        for rawLine in lines where !rawLine.isEmpty {
            guard let lineData = rawLine.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let topType = obj["type"] as? String else { continue }

            let payload = obj["payload"] as? [String: Any] ?? [:]

            if topType == "turn_context" {
                status = .running
                completedAt = nil
                if let c = payload["cwd"] as? String, !c.isEmpty { cwd = c }
                if startedAt == nil { startedAt = parseISO(obj["timestamp"] as? String) }
            } else if topType == "event_msg" {
                let ptype = payload["type"] as? String ?? ""
                if ptype == "task_started" {
                    status = .running
                    currentAction = "思考规划中…"
                    lastAgentMessage = ""
                    completedAt = nil
                    durationSec = nil
                    startedAt = parseEpoch(payload["started_at"]) ?? parseISO(obj["timestamp"] as? String)
                } else if ptype == "task_complete" {
                    status = .done
                    currentAction = "已完成"
                    if let msg = payload["last_agent_message"] as? String, !msg.isEmpty {
                        lastAgentMessage = String(msg.prefix(400))
                    }
                    completedAt = parseEpoch(payload["completed_at"]) ?? parseISO(obj["timestamp"] as? String) ?? mtime
                    if let s = parseEpoch(payload["started_at"]) { startedAt = s }
                    if let durMs = parseDouble(payload["duration_ms"]) {
                        durationSec = durMs / 1000.0
                    } else if let s = startedAt, let c = completedAt {
                        durationSec = max(0, c.timeIntervalSince(s))
                    }
                } else if ptype == "turn_aborted" {
                    status = .canceled
                    currentAction = "已手动停止"
                    completedAt = parseISO(obj["timestamp"] as? String) ?? mtime
                } else if ptype == "exec_approval_request"
                            || ptype == "apply_patch_approval_request"
                            || ptype == "request_user_input"
                            || ptype == "elicitation_request" {
                    status = .needsInput
                    completedAt = nil
                    currentAction = "等待你的审批或回复"
                } else if ptype == "item_completed" {
                    if status != .done && status != .canceled {
                        status = .running
                        completedAt = nil
                        if currentAction.isEmpty { currentAction = "执行中…" }
                    }
                }
            } else if topType == "response_item" {
                let ptype = payload["type"] as? String ?? ""
                if ptype == "custom_tool_call" {
                    status = .running
                    completedAt = nil
                    currentAction = ToolActionFormatter.describe(
                        name: payload["name"] as? String ?? "",
                        rawInput: payload["input"] as? String ?? ""
                    )
                } else if ptype == "function_call" {
                    status = .running
                    completedAt = nil
                    currentAction = ToolActionFormatter.describe(
                        name: payload["name"] as? String ?? "",
                        rawInput: payload["arguments"] as? String ?? ""
                    )
                } else if ptype == "custom_tool_call_output" || ptype == "function_call_output" {
                    status = .running
                    completedAt = nil
                    if currentAction.isEmpty { currentAction = "整理工具结果…" }
                } else if ptype == "reasoning" {
                    status = .running
                    completedAt = nil
                    currentAction = "深度思考中…"
                } else if ptype == "message",
                          (payload["role"] as? String) == "assistant",
                          let content = payload["content"] as? [[String: Any]] {
                    for part in content {
                        if let txt = part["text"] as? String, !txt.isEmpty {
                            lastAgentMessage = String(txt.prefix(400))
                            if (payload["phase"] as? String) == "final_answer", status == .running {
                                currentAction = "输出回复中…"
                            }
                            break
                        }
                    }
                }
            }
        }

        let resolved: SessionStatus
        if let st = status {
            if st == .running && now.timeIntervalSince(mtime) > 600 {
                resolved = .done
                currentAction = "已完成"
                completedAt = mtime
            } else {
                resolved = st
            }
        } else if now.timeIntervalSince(mtime) < 60 {
            resolved = .running
            currentAction = "执行中…"
        } else {
            resolved = .done
            currentAction = "已完成"
            completedAt = mtime
        }

        return CodexRolloutState(
            status: resolved,
            currentAction: currentAction,
            lastAgentMessage: lastAgentMessage,
            startedAt: startedAt,
            completedAt: (resolved == .running || resolved == .needsInput) ? nil : completedAt,
            durationSec: durationSec,
            cwd: cwd
        )
    }

    private static func parseEpoch(_ val: Any?) -> Date? {
        guard let d = parseDouble(val), d > 1_000_000_000 else { return nil }
        return Date(timeIntervalSince1970: d)
    }

    private static func parseDouble(_ val: Any?) -> Double? {
        if let d = val as? Double { return d }
        if let i = val as? Int { return Double(i) }
        if let i64 = val as? Int64 { return Double(i64) }
        if let s = val as? String, let d = Double(s) { return d }
        return nil
    }

    private static func parseISO(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        return FastISO8601Parser.parse(raw)
    }
}

final class CodexScanner: @unchecked Sendable {
    private let stateDBPath: String
    private let sessionIndexPath: String

    private var cachedIndexMtime: Date?
    private var threadNameById: [String: String] = [:]

    private struct FileMeta: Equatable {
        let inode: UInt64
        let size: UInt64
        let mtimeSec: Int
        let mtimeNsec: Int

        var mtime: Date {
            Date(timeIntervalSince1970: TimeInterval(mtimeSec) + TimeInterval(mtimeNsec) / 1_000_000_000.0)
        }

        static func read(_ path: String) -> FileMeta? {
            var st = stat()
            guard stat(path, &st) == 0 else { return nil }
            return FileMeta(
                inode: UInt64(st.st_ino),
                size: UInt64(max(0, st.st_size)),
                mtimeSec: st.st_mtimespec.tv_sec,
                mtimeNsec: st.st_mtimespec.tv_nsec
            )
        }
    }

    private struct CachedRollout {
        let meta: FileMeta
        let state: CodexRolloutState
    }

    private var rolloutCache: [String: CachedRollout] = [:]
    private var lastDBFingerprint: String = ""
    private var cachedDBPayload: ([DBThread], [String: String])?
    private var lastKnownSessions: [AgentSession] = []

    private struct DBThread {
        let id: String
        let rolloutPath: String
        let updatedAt: Date
        let cwd: String
        let title: String
        let firstUserMessage: String
        let agentNickname: String
        let source: String
    }

    init(stateDBPath: String? = nil, sessionIndexPath: String? = nil) {
        let envHome = ProcessInfo.processInfo.environment["CODEX_HOME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let codexDir: String
        if let envHome, !envHome.isEmpty {
            codexDir = (envHome as NSString).expandingTildeInPath
        } else {
            codexDir = "\(NSHomeDirectory())/.codex"
        }
        self.stateDBPath = stateDBPath ?? "\(codexDir)/state_5.sqlite"
        self.sessionIndexPath = sessionIndexPath ?? "\(codexDir)/session_index.jsonl"
    }

    func scan(lookbackHours: Double = 24, now: Date = Date(), preloadedHooks: [String: LiveHookRecord]? = nil) -> [AgentSession] {
        guard FileManager.default.fileExists(atPath: stateDBPath) else {
            lastKnownSessions = []
            cachedDBPayload = nil
            lastDBFingerprint = ""
            rolloutCache.removeAll()
            return []
        }
        refreshSessionIndexIfNeeded()
        let cutoff = now.addingTimeInterval(-lookbackHours * 3600)
        guard let (threads, parentOfChild) = loadDBThreadsAndEdges() else {
            return lastKnownSessions
        }

        var parsedMap: [String: CodexRolloutState] = [:]
        var rolloutMtimeMap: [String: Date] = [:]
        var activeSubagents: [String: Int] = [:]
        var subagentNeedsInput: [String: (Date, String)] = [:]
        var seenRolloutPaths = Set<String>()

        for th in threads {
            let meta = th.rolloutPath.isEmpty ? nil : FileMeta.read(th.rolloutPath)
            let fileMtime = meta?.mtime
            let effectiveMtime = max(th.updatedAt, fileMtime ?? .distantPast)
            guard effectiveMtime >= cutoff else { continue }
            if let fileMtime { rolloutMtimeMap[th.id] = fileMtime }

            if let meta {
                seenRolloutPaths.insert(th.rolloutPath)
                if let snap = parseRolloutTail(path: th.rolloutPath, meta: meta, now: now) {
                    parsedMap[th.id] = snap
                    if let parent = rootParent(of: th.id, map: parentOfChild) {
                        if snap.status == .running {
                            activeSubagents[parent, default: 0] += 1
                        } else if snap.status == .needsInput {
                            activeSubagents[parent, default: 0] += 1
                            let action = snap.currentAction.isEmpty ? "等待你的审批或回复" : snap.currentAction
                            if let existing = subagentNeedsInput[parent] {
                                if effectiveMtime > existing.0 {
                                    subagentNeedsInput[parent] = (effectiveMtime, action)
                                }
                            } else {
                                subagentNeedsInput[parent] = (effectiveMtime, action)
                            }
                        }
                    }
                }
            }
        }

        // Bounded cache eviction: drop rollout entries no longer in the recent thread window
        if rolloutCache.count > seenRolloutPaths.count + 24 {
            rolloutCache = rolloutCache.filter { seenRolloutPaths.contains($0.key) }
        }

        let hookMap = preloadedHooks ?? LiveHookRecord.loadAll(forAgent: "codex")
        var sessions: [AgentSession] = []
        for th in threads {
            let srcLow = th.source.lowercased()
            let isSubagent = srcLow.contains("subagent") || srcLow.hasPrefix("{")
            if parentOfChild[th.id] != nil || !th.agentNickname.isEmpty || isSubagent { continue }

            let fileMtime = rolloutMtimeMap[th.id]
            let snap = parsedMap[th.id]
            let subCount = activeSubagents[th.id] ?? 0
            let childNeeds = subagentNeedsInput[th.id]
            let effectiveMtime = max(th.updatedAt, fileMtime ?? .distantPast)
            guard effectiveMtime >= cutoff || snap?.status == .running || snap?.status == .needsInput || subCount > 0 || childNeeds != nil else { continue }
            let effectiveCwd = (snap?.cwd.isEmpty == false ? snap?.cwd : nil) ?? th.cwd
            let project = ProjectNameHelper.projectName(from: effectiveCwd)

            let rawTitle: String
            if let idxName = threadNameById[th.id], !idxName.isEmpty {
                rawTitle = idxName
            } else if !th.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                rawTitle = th.title
            } else if !th.firstUserMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                rawTitle = th.firstUserMessage
            } else {
                rawTitle = project.isEmpty ? "Codex 对话" : project
            }
            let title = ProjectNameHelper.cleanOneLine(rawTitle, maxLength: 78)

            var status = snap?.status ?? .done
            let hook = hookMap[th.id]
            let hookFresher = hook.map { $0.updatedAt.timeIntervalSince(effectiveMtime) > 1.5 } ?? false
            if let hook, hook.state == "needs_input",
               now.timeIntervalSince(hook.updatedAt) < 1200,
               hook.updatedAt.timeIntervalSince(effectiveMtime) > -5 {
                status = .needsInput
            } else if childNeeds != nil {
                status = .needsInput
            } else if let hook, hookFresher {
                if hook.state == "canceled" {
                    status = .canceled
                } else if hook.state == "error" {
                    status = .error
                } else if hook.state == "done" && subCount == 0 {
                    status = .done
                } else if hook.state == "running" && now.timeIntervalSince(hook.updatedAt) < 180 {
                    status = .running
                } else if subCount > 0 && status != .running && status != .needsInput {
                    status = .running
                }
            } else if subCount > 0 && status != .running && status != .needsInput {
                status = .running
            }

            let action: String
            if status == .needsInput {
                if let h = hook, !h.action.isEmpty, h.state == "needs_input" { action = h.action }
                else if let cn = childNeeds { action = cn.1 }
                else if let a = snap?.currentAction, !a.isEmpty { action = a }
                else { action = "等待你的审批或回复" }
            } else if status == .running {
                if let h = hook, hookFresher, h.state == "running", !h.action.isEmpty { action = h.action }
                else if let a = snap?.currentAction, !a.isEmpty { action = a }
                else if subCount > 0 { action = "等待 \(subCount) 个子 Agent 执行…" }
                else { action = "思考与执行中…" }
            } else if status == .error {
                action = (hook?.action.isEmpty == false) ? (hook?.action ?? "执行出错") : "执行出错"
            } else if status == .canceled {
                action = "已手动停止"
            } else {
                action = "已完成"
            }

            let isCLI = srcLow == "cli" || srcLow == "exec"
            let hookTime = hookFresher ? (hook?.updatedAt ?? .distantPast) : .distantPast
            let updatedAt = max(effectiveMtime, max(hookTime, max(snap?.completedAt ?? .distantPast, childNeeds?.0 ?? .distantPast)))
            let isActive = (status == .running || status == .needsInput)
            let resolvedCompletedAt: Date? = isActive ? nil : (hookFresher ? (hook?.completedAt ?? hook?.updatedAt) : (snap?.completedAt ?? effectiveMtime))

            sessions.append(AgentSession(
                id: "codex:\(th.id)",
                rawId: th.id,
                kind: .codex,
                title: title,
                project: project.isEmpty ? "Codex" : project,
                cwd: effectiveCwd,
                isCLI: isCLI,
                status: status,
                currentAction: action,
                detailSummary: "",
                startedAt: snap?.startedAt ?? hook?.turnStartedAt,
                updatedAt: updatedAt,
                completedAt: resolvedCompletedAt,
                durationSec: isActive ? nil : (hookFresher ? (hook?.durationSec ?? snap?.durationSec) : snap?.durationSec),
                activeSubagents: subCount,
                isUnread: false
            ))
        }
        lastKnownSessions = sessions
        return sessions
    }

    private func computeDBFingerprint() -> String {
        var parts: [String] = []
        for p in [stateDBPath, stateDBPath + "-wal"] {
            if let m = FileMeta.read(p) {
                parts.append("\(m.inode):\(m.size):\(m.mtimeSec).\(m.mtimeNsec)")
            } else {
                parts.append("none")
            }
        }
        return parts.joined(separator: "|")
    }

    private func loadDBThreadsAndEdges() -> ([DBThread], [String: String])? {
        let fp = computeDBFingerprint()
        if fp == lastDBFingerprint, let cached = cachedDBPayload {
            return cached
        }
        guard let reader = SQLiteReader(path: stateDBPath) else { return nil }

        let result: ([DBThread], [String: String])? = reader.withReadTransaction {
            var parentOfChild: [String: String] = [:]
            _ = reader.query("SELECT parent_thread_id, child_thread_id FROM thread_spawn_edges;") { stmt in
                let parent = SQLiteReader.string(stmt, 0)
                let child = SQLiteReader.string(stmt, 1)
                if !parent.isEmpty && !child.isEmpty { parentOfChild[child] = parent }
            }

            var threads: [DBThread] = []
            let sql = """
            SELECT id, rollout_path, updated_at, cwd, title, first_user_message,
                   COALESCE(agent_nickname, ''), source
            FROM threads
            WHERE archived = 0
              AND (trim(title) != '' OR trim(first_user_message) != '')
            ORDER BY updated_at DESC
            LIMIT 120;
            """
            let ok = reader.query(sql) { stmt in
                let id = SQLiteReader.string(stmt, 0)
                guard !id.isEmpty else { return }
                threads.append(DBThread(
                    id: id,
                    rolloutPath: SQLiteReader.string(stmt, 1),
                    updatedAt: Date(timeIntervalSince1970: TimeInterval(SQLiteReader.int64(stmt, 2))),
                    cwd: SQLiteReader.string(stmt, 3),
                    title: SQLiteReader.string(stmt, 4),
                    firstUserMessage: SQLiteReader.string(stmt, 5),
                    agentNickname: SQLiteReader.string(stmt, 6),
                    source: SQLiteReader.string(stmt, 7)
                ))
            }
            guard ok else { return nil }
            return (threads, parentOfChild)
        }

        guard let result else { return nil }
        lastDBFingerprint = fp
        cachedDBPayload = result
        return result
    }

    private func rootParent(of child: String, map: [String: String]) -> String? {
        guard var cur = map[child] else { return nil }
        var hops = 0
        while let next = map[cur], hops < 6 {
            cur = next
            hops += 1
        }
        return cur
    }

    private func refreshSessionIndexIfNeeded() {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: sessionIndexPath),
              let mtime = attrs[.modificationDate] as? Date else { return }
        if cachedIndexMtime == mtime { return }
        guard let content = try? String(contentsOfFile: sessionIndexPath, encoding: .utf8) else { return }
        cachedIndexMtime = mtime

        var map: [String: String] = [:]
        for line in content.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = obj["id"] as? String,
                  let name = obj["thread_name"] as? String,
                  !id.isEmpty, !name.isEmpty else { continue }
            map[id] = name
        }
        threadNameById = map
    }

    private func parseRolloutTail(path: String, meta: FileMeta, now: Date) -> CodexRolloutState? {
        let mtime = meta.mtime
        if let cached = rolloutCache[path], cached.meta == meta {
            if cached.state.status == .running && now.timeIntervalSince(mtime) > 600 {
                let stale = CodexRolloutState(
                    status: .done, currentAction: "已完成",
                    lastAgentMessage: cached.state.lastAgentMessage,
                    startedAt: cached.state.startedAt, completedAt: mtime,
                    durationSec: cached.state.durationSec, cwd: cached.state.cwd
                )
                rolloutCache[path] = CachedRollout(meta: meta, state: stale)
                return stale
            }
            return cached.state
        }

        guard let fh = FileHandle(forReadingAtPath: path) else {
            return rolloutCache[path]?.state
        }
        defer { try? fh.close() }

        guard let lines = FileTailReader.readTailLines(from: fh, fileSize: meta.size, maxBytes: 262_144) else {
            return rolloutCache[path]?.state
        }

        let state = CodexRolloutParser.parse(lines: lines, mtime: mtime, now: now)
        rolloutCache[path] = CachedRollout(meta: meta, state: state)
        return state
    }
}
