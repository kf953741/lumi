import Foundation

final class ClaudeScanner: @unchecked Sendable {
    private let projectsDir: String

    private struct CachedClaudeSession {
        let size: UInt64
        let mtime: Date
        let session: AgentSession
    }

    private var cache: [String: CachedClaudeSession] = [:]

    init() {
        self.projectsDir = "\(NSHomeDirectory())/.claude/projects"
    }

    func scan(lookbackHours: Double = 24) -> [AgentSession] {
        let now = Date()
        let cutoff = now.addingTimeInterval(-lookbackHours * 3600)
        let hookMap = LiveHookRecord.loadAll(forAgent: "claude")

        var results: [AgentSession] = []
        var emitted: Set<String> = []

        // 1. Scan ~/.claude/projects/*/*.jsonl (zero-config!)
        let fm = FileManager.default
        if let projectFolders = try? fm.contentsOfDirectory(atPath: projectsDir) {
            for folder in projectFolders where !folder.hasPrefix(".") {
                let folderPath = (projectsDir as NSString).appendingPathComponent(folder)
                guard let files = try? fm.contentsOfDirectory(atPath: folderPath) else { continue }
                for file in files where file.hasSuffix(".jsonl") && !file.hasPrefix("agent-") {
                    let full = (folderPath as NSString).appendingPathComponent(file)
                    guard let attrs = try? fm.attributesOfItem(atPath: full),
                          let mtime = attrs[.modificationDate] as? Date,
                          mtime >= cutoff,
                          let sizeNum = attrs[.size] as? NSNumber else { continue }
                    let sessionId = String(file.dropLast(6))
                    let hook = hookMap[sessionId]
                    if let parsed = parseTranscript(
                        path: full,
                        sessionId: sessionId,
                        size: sizeNum.uint64Value,
                        mtime: mtime,
                        hook: hook,
                        now: now
                    ) {
                        results.append(parsed)
                        emitted.insert(sessionId)
                    }
                }
            }
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
            else { status = .done }

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
                durationSec: hook.durationSec,
                activeSubagents: 0,
                isUnread: false
            ))
        }

        return results
    }

    private func parseTranscript(
        path: String,
        sessionId: String,
        size: UInt64,
        mtime: Date,
        hook: LiveHookRecord?,
        now: Date
    ) -> AgentSession? {
        if let cached = cache[path], cached.size == size, cached.mtime == mtime, hook == nil {
            if cached.session.status == .running && now.timeIntervalSince(mtime) > 180 {
                let done = AgentSession(
                    id: cached.session.id, rawId: cached.session.rawId, kind: .claude,
                    title: cached.session.title, project: cached.session.project, cwd: cached.session.cwd,
                    isCLI: false, status: .done, currentAction: "已完成", detailSummary: "",
                    startedAt: cached.session.startedAt, updatedAt: mtime, completedAt: mtime,
                    durationSec: cached.session.durationSec, activeSubagents: 0, isUnread: false
                )
                cache[path] = CachedClaudeSession(size: size, mtime: mtime, session: done)
                return done
            }
            return cached.session
        }

        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }

        // Read first 16KB for initial user prompt/cwd if file is large
        var cwd = ""
        var firstPrompt = ""
        if size > 131_072 {
            let headData = fh.readData(ofLength: 16_384)
            if let headText = String(data: headData, encoding: .utf8) {
                for line in headText.components(separatedBy: .newlines) where !line.isEmpty {
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
        }

        let tailBytes: UInt64 = 131_072
        let offset = size > tailBytes ? (size - tailBytes) : 0
        do { try fh.seek(toOffset: offset) } catch { return nil }
        let data = fh.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        var lines = text.components(separatedBy: .newlines)
        if offset > 0 && !lines.isEmpty { lines.removeFirst() }

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

        if isRunningFromTranscript && now.timeIntervalSince(mtime) > 180 {
            isRunningFromTranscript = false
            lastAction = "已完成"
        }
        if needsInputFromTranscript && now.timeIntervalSince(mtime) > 1200 {
            needsInputFromTranscript = false
        }

        let effectiveCwd = !cwd.isEmpty ? cwd : (hook?.cwd ?? "")
        let project = ProjectNameHelper.projectName(from: effectiveCwd)

        let rawTitle = !customTitle.isEmpty ? customTitle
            : (!aiTitle.isEmpty ? aiTitle
               : (!(hook?.title.isEmpty ?? true) ? (hook?.title ?? "")
                  : (!firstPrompt.isEmpty ? firstPrompt : (hook?.firstUserInput ?? project))))
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
                action = hook.action
                completedAt = hook.completedAt ?? hook.updatedAt
            } else if hook.state == "canceled" {
                status = .canceled
                completedAt = hook.completedAt ?? hook.updatedAt
            } else if hook.state == "done" {
                status = .done
                action = "已完成"
                completedAt = hook.completedAt ?? mtime
            }
            if let s = hook.turnStartedAt { startedAt = s }
        }

        let session = AgentSession(
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
            completedAt: completedAt,
            durationSec: hook?.durationSec,
            activeSubagents: 0,
            isUnread: false
        )
        cache[path] = CachedClaudeSession(size: size, mtime: mtime, session: session)
        return session
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
