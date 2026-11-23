import Darwin
import Foundation

final class ClaudeScanner: @unchecked Sendable {
    private let projectsDir: String

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

    /// Raw transcript evidence cached independently of live hooks and current wall clock `now`,
    /// so hooks never invalidate the file cache and removing/expiring a hook updates status immediately.
    private struct ParsedTranscript {
        let cwd: String
        let customTitle: String
        let aiTitle: String
        let firstPrompt: String
        let lastAction: String
        let isRunning: Bool
        let needsInput: Bool
    }

    private struct CachedTranscript {
        let meta: FileMeta
        let parsed: ParsedTranscript
    }

    private var cache: [String: CachedTranscript] = [:]

    init(projectsDir: String? = nil) {
        if let projectsDir {
            self.projectsDir = projectsDir
        } else {
            let envDir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let claudeHome = (envDir?.isEmpty == false)
                ? (envDir! as NSString).expandingTildeInPath
                : "\(NSHomeDirectory())/.claude"
            self.projectsDir = "\(claudeHome)/projects"
        }
    }

    func scan(lookbackHours: Double = 24, now: Date = Date(), preloadedHooks: [String: LiveHookRecord]? = nil) -> [AgentSession] {
        let cutoff = now.addingTimeInterval(-lookbackHours * 3600)
        let hookMap = preloadedHooks ?? LiveHookRecord.loadAll(forAgent: "claude")

        var results: [AgentSession] = []
        var emitted: Set<String> = []
        var seenPaths: Set<String> = []

        // 1. Scan ~/.claude/projects/*/*.jsonl (zero-config!)
        let fm = FileManager.default
        if let projectFolders = try? fm.contentsOfDirectory(atPath: projectsDir) {
            for folder in projectFolders where !folder.hasPrefix(".") {
                let folderPath = (projectsDir as NSString).appendingPathComponent(folder)
                guard let files = try? fm.contentsOfDirectory(atPath: folderPath) else { continue }
                for file in files where file.hasSuffix(".jsonl") && !file.hasPrefix("agent-") {
                    let full = (folderPath as NSString).appendingPathComponent(file)
                    guard let meta = FileMeta.read(full) else { continue }
                    let mtime = meta.mtime
                    let sessionId = String(file.dropLast(6))
                    let hook = hookMap[sessionId]
                    guard mtime >= cutoff || (hook?.updatedAt ?? .distantPast) >= cutoff else { continue }
                    seenPaths.insert(full)
                    if let parsed = loadOrParseTranscript(path: full, meta: meta) {
                        results.append(buildSession(
                            sessionId: sessionId,
                            mtime: mtime,
                            transcript: parsed,
                            hook: hook,
                            now: now
                        ))
                        emitted.insert(sessionId)
                    }
                }
            }
        }

        // Bounded cache eviction
        if cache.count > seenPaths.count + 24 {
            cache = cache.filter { seenPaths.contains($0.key) }
        }

        // 2. Include hook-only Claude Code sessions not yet visible in projectsDir
        for (sid, hook) in hookMap where !emitted.contains(sid) {
            guard hook.updatedAt >= cutoff else { continue }
            let project = ProjectNameHelper.projectName(from: hook.workspacePaths.first ?? hook.cwd)
            let rawTitle = !hook.title.isEmpty ? hook.title : (!hook.firstUserInput.isEmpty ? hook.firstUserInput : hook.lastUserInput)
            let title = ProjectNameHelper.cleanOneLine(rawTitle.isEmpty ? (project.isEmpty ? "Claude 会话" : project) : rawTitle, maxLength: 78)

            let status: SessionStatus
            if hook.state == "needs_input" && now.timeIntervalSince(hook.updatedAt) < 1200 { status = .needsInput }
            else if hook.state == "running" && now.timeIntervalSince(hook.updatedAt) < 180 { status = .running }
            else if hook.state == "error" { status = .error }
            else if hook.state == "canceled" { status = .canceled }
            else if hook.state == "done" { status = .done }
            else { continue }

            results.append(AgentSession(
                id: "claude:\(sid)",
                rawId: sid,
                kind: .claude,
                title: title,
                project: project.isEmpty ? "Claude" : project,
                cwd: hook.cwd,
                isCLI: false,
                status: status,
                currentAction: status == .needsInput
                    ? (hook.action.isEmpty ? "等待你的审批或回复" : hook.action)
                    : (status == .running ? (hook.action.isEmpty ? "思考与执行中…" : hook.action) : "已完成"),
                detailSummary: "",
                startedAt: hook.turnStartedAt,
                updatedAt: hook.updatedAt,
                completedAt: (status == .running || status == .needsInput) ? nil : (hook.completedAt ?? hook.updatedAt),
                durationSec: (status == .running || status == .needsInput) ? nil : hook.durationSec,
                activeSubagents: 0,
                isUnread: false
            ))
        }

        return results
    }

    private func loadOrParseTranscript(path: String, meta: FileMeta) -> ParsedTranscript? {
        if let cached = cache[path], cached.meta == meta {
            return cached.parsed
        }

        guard let fh = FileHandle(forReadingAtPath: path) else {
            return cache[path]?.parsed
        }
        defer { try? fh.close() }

        // Read first 16KB for initial user prompt/cwd if file is large (UTF-8 boundary safe)
        var cwd = ""
        var firstPrompt = ""
        if meta.size > 131_072 {
            for line in FileTailReader.readHeadLines(from: fh, maxBytes: 16_384) {
                guard let d = line.data(using: .utf8),
                      let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
                if cwd.isEmpty, let c = o["cwd"] as? String { cwd = c }
                if firstPrompt.isEmpty, (o["type"] as? String) == "user",
                   let msg = o["message"] as? [String: Any] {
                    firstPrompt = extractText(from: msg["content"])
                }
                if !cwd.isEmpty && !firstPrompt.isEmpty { break }
            }
        }

        guard let lines = FileTailReader.readTailLines(from: fh, fileSize: meta.size, maxBytes: 131_072) else {
            return cache[path]?.parsed
        }

        var customTitle = ""
        var aiTitle = ""
        var lastAction = ""
        var isRunningFromTranscript = false
        var needsInputFromTranscript = false

        for line in lines where !line.isEmpty {
            guard let d = line.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
            if cwd.isEmpty, let c = o["cwd"] as? String { cwd = c }
            let t = o["type"] as? String ?? ""
            if t == "custom-title", let ct = o["customTitle"] as? String, !ct.isEmpty {
                customTitle = ct
            } else if t == "ai-title", let at = o["aiTitle"] as? String, !at.isEmpty {
                aiTitle = at
            } else if t == "user", let msg = o["message"] as? [String: Any] {
                let txt = extractText(from: msg["content"])
                if firstPrompt.isEmpty && !txt.isEmpty { firstPrompt = txt }
                isRunningFromTranscript = true
                needsInputFromTranscript = false
                lastAction = "思考规划中…"
            } else if t == "assistant", let msg = o["message"] as? [String: Any] {
                if let blocks = msg["content"] as? [[String: Any]] {
                    var hasToolUse = false
                    var asksUser = false
                    for b in blocks {
                        let bt = b["type"] as? String ?? ""
                        if bt == "tool_use" {
                            hasToolUse = true
                            let name = b["name"] as? String ?? ""
                            if name.lowercased() == "askuserquestion" || name.lowercased() == "ask_question" {
                                asksUser = true
                                lastAction = "等待你确认/回答"
                            } else {
                                let inputStr: String
                                if let inp = b["input"], let jd = try? JSONSerialization.data(withJSONObject: inp),
                                   let js = String(data: jd, encoding: .utf8) {
                                    inputStr = js
                                } else {
                                    inputStr = ""
                                }
                                lastAction = ToolActionFormatter.describe(name: name, rawInput: inputStr)
                            }
                        }
                    }
                    needsInputFromTranscript = asksUser
                    isRunningFromTranscript = !asksUser && (hasToolUse || (msg["stop_reason"] == nil))
                    if !hasToolUse && (msg["stop_reason"] as? String) == "end_turn" {
                        isRunningFromTranscript = false
                        needsInputFromTranscript = false
                        lastAction = "已完成"
                    }
                }
            }
        }

        let parsed = ParsedTranscript(
            cwd: cwd,
            customTitle: customTitle,
            aiTitle: aiTitle,
            firstPrompt: firstPrompt,
            lastAction: lastAction,
            isRunning: isRunningFromTranscript,
            needsInput: needsInputFromTranscript
        )
        cache[path] = CachedTranscript(meta: meta, parsed: parsed)
        return parsed
    }

    private func buildSession(
        sessionId: String,
        mtime: Date,
        transcript: ParsedTranscript,
        hook: LiveHookRecord?,
        now: Date
    ) -> AgentSession {
        var isRunningFromTranscript = transcript.isRunning
        var needsInputFromTranscript = transcript.needsInput
        var lastAction = transcript.lastAction

        if isRunningFromTranscript && now.timeIntervalSince(mtime) > 180 {
            isRunningFromTranscript = false
            lastAction = "已完成"
        }
        if needsInputFromTranscript && now.timeIntervalSince(mtime) > 1200 {
            needsInputFromTranscript = false
            lastAction = "已完成"
        }

        let effectiveCwd = !transcript.cwd.isEmpty ? transcript.cwd : (hook?.cwd ?? "")
        let project = ProjectNameHelper.projectName(from: effectiveCwd)

        let rawTitle = !transcript.customTitle.isEmpty ? transcript.customTitle
            : (!transcript.aiTitle.isEmpty ? transcript.aiTitle
               : (!(hook?.title.isEmpty ?? true) ? (hook?.title ?? "")
                  : (!transcript.firstPrompt.isEmpty ? transcript.firstPrompt : (hook?.firstUserInput ?? project))))
        let title = ProjectNameHelper.cleanOneLine(rawTitle.isEmpty ? "Claude 会话" : rawTitle, maxLength: 78)

        var status: SessionStatus = needsInputFromTranscript ? .needsInput : (isRunningFromTranscript ? .running : .done)
        var action = lastAction.isEmpty ? (status == .running ? "执行中…" : "已完成") : lastAction
        var completedAt: Date? = (status == .running || status == .needsInput) ? nil : mtime
        var startedAt: Date? = hook?.turnStartedAt

        if let hook, hook.updatedAt.timeIntervalSince(mtime) > -2 {
            if hook.state == "needs_input" && now.timeIntervalSince(hook.updatedAt) < 1200 {
                status = .needsInput
                if !hook.action.isEmpty { action = hook.action }
                completedAt = nil
            } else if hook.state == "running" && now.timeIntervalSince(hook.updatedAt) < 180 {
                status = .running
                if !hook.action.isEmpty { action = hook.action }
                completedAt = nil
            } else if hook.state == "error" {
                status = .error
                action = hook.action.isEmpty ? "执行出错" : hook.action
                completedAt = hook.completedAt ?? hook.updatedAt
            } else if hook.state == "canceled" {
                status = .canceled
                action = "已手动停止"
                completedAt = hook.completedAt ?? hook.updatedAt
            } else if hook.state == "done" {
                status = .done
                action = "已完成"
                completedAt = hook.completedAt ?? mtime
            }
            if let s = hook.turnStartedAt { startedAt = s }
        }

        let isActive = (status == .running || status == .needsInput)
        return AgentSession(
            id: "claude:\(sessionId)",
            rawId: sessionId,
            kind: .claude,
            title: title,
            project: project.isEmpty ? "Claude" : project,
            cwd: effectiveCwd,
            isCLI: false,
            status: status,
            currentAction: action,
            detailSummary: "",
            startedAt: startedAt,
            updatedAt: max(mtime, hook?.updatedAt ?? .distantPast),
            completedAt: isActive ? nil : completedAt,
            durationSec: isActive ? nil : hook?.durationSec,
            activeSubagents: 0,
            isUnread: false
        )
    }

    private func extractText(from content: Any?) -> String {
        if let s = content as? String { return s }
        if let arr = content as? [[String: Any]] {
            for item in arr {
                if (item["type"] as? String) == "text", let t = item["text"] as? String, !t.isEmpty {
                    return t
                }
            }
        }
        return ""
    }
}
