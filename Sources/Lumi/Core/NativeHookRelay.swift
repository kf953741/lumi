import Darwin
import Foundation

/// Native zero-dependency hook relay executed via `Lumi --hook --agent <agent> [EventName]`.
/// Eliminates the `/usr/bin/python3` Xcode Command Line Tools dependency on clean macOS machines,
/// runs in <5 ms, uses per-session `flock` locking, enforces 0700/0600 permissions, and always exits 0.
enum NativeHookRelay {
    static func shouldHandle(arguments: [String]) -> Bool {
        arguments.dropFirst().contains("--hook")
    }

    static func defaultLiveDir() -> String {
        LiveHookRecord.defaultLiveDir
    }

    static func run(arguments: [String], liveDir: String = defaultLiveDir()) {
        let (agent, eventArg) = parseArgs(arguments)
        let stdinData = FileHandle.standardInput.readDataToEndOfFile()
        let result = processPayload(
            agent: agent,
            eventArg: eventArg,
            stdinData: stdinData,
            liveDir: liveDir,
            now: Date().timeIntervalSince1970
        )
        if let out = result.stdoutResponse, let data = out.data(using: .utf8) {
            FileHandle.standardOutput.write(data)
        }
    }

    struct ProcessResult: Equatable {
        let wrotePath: String?
        let stdoutResponse: String?
    }

    static func parseArgs(_ args: [String]) -> (agent: String, eventArg: String) {
        var agent = "antigravity"
        var eventArg = ""
        var i = 0
        while i < args.count {
            let arg = args[i]
            if arg == "--hook" {
                i += 1
            } else if arg == "--agent", i + 1 < args.count {
                agent = args[i + 1].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                i += 2
            } else {
                eventArg = arg.trimmingCharacters(in: .whitespacesAndNewlines)
                i += 1
            }
        }
        return (agent, eventArg)
    }

    static func normalizeEvent(_ raw: String, payload: [String: Any] = [:]) -> String {
        switch raw {
        case "PreInvocation", "BeforeAgent", "session.busy", "beforeSubmitPrompt":
            return "UserPromptSubmit"
        case "BeforeTool", "BeforeToolSelection", "beforeShellExecution", "beforeMCPExecution", "beforeReadFile":
            return "PreToolUse"
        case "AfterTool", "PostInvocation", "afterFileEdit", "afterShellExecution":
            return "PostToolUse"
        case "AfterAgent", "stop", "session.idle":
            return "Stop"
        case "PermissionRequest", "Elicitation", "permission.asked":
            return "NeedsInput"
        case "Notification":
            return "Notification"
        case "session.status":
            let statusType: String = {
                if let statusObj = payload["status"] as? [String: Any], let t = statusObj["type"] as? String {
                    return t.lowercased()
                }
                if let props = payload["properties"] as? [String: Any],
                   let statusObj = props["status"] as? [String: Any],
                   let t = statusObj["type"] as? String {
                    return t.lowercased()
                }
                return (payload["status"] as? String ?? "").lowercased()
            }()
            if statusType == "busy" || statusType == "retry" || statusType == "running" {
                return "UserPromptSubmit"
            }
            if statusType == "idle" {
                return "Stop"
            }
            return raw
        default:
            return raw
        }
    }

    static func processPayload(
        agent: String,
        eventArg: String,
        stdinData: Data,
        liveDir: String,
        now: TimeInterval
    ) -> ProcessResult {
        var payload: [String: Any] = [:]
        if !stdinData.isEmpty,
           let obj = try? JSONSerialization.jsonObject(with: stdinData) as? [String: Any] {
            payload = obj
        }

        let rawEvent = firstNonEmptyString([
            payload["hookEventName"],
            payload["hook_event_name"],
            eventArg
        ])
        let normEvent = normalizeEvent(rawEvent, payload: payload)

        let sessionId = firstNonEmptyString([
            payload["conversationId"],
            payload["session_id"],
            payload["conversation_id"],
            payload["thread_id"],
            payload["generation_id"]
        ])

        var writtenPath: String? = nil
        if !sessionId.isEmpty {
            writtenPath = writeState(
                agent: agent,
                sessionId: sessionId,
                rawEvent: rawEvent,
                normEvent: normEvent,
                payload: payload,
                liveDir: liveDir,
                now: now
            )
        }

        let response: String?
        switch agent {
        case "antigravity":
            if rawEvent == "PreToolUse" {
                response = "{\"decision\":\"allow\"}\n"
            } else if rawEvent == "Stop" {
                response = "{\"decision\":\"stop\"}\n"
            } else {
                response = "{}\n"
            }
        case "gemini":
            response = "{}\n"
        case "cursor":
            // Cursor hook schema requires explicit permission/continue fields for pre-hooks
            // (returning `{}` to beforeShellExecution/beforeMCPExecution/beforeReadFile causes Cursor to block!).
            if rawEvent == "beforeShellExecution" || rawEvent == "beforeMCPExecution" || rawEvent == "beforeReadFile" {
                response = "{\"permission\":\"allow\"}\n"
            } else if rawEvent == "beforeSubmitPrompt" {
                response = "{\"continue\":true}\n"
            } else {
                response = "{}\n"
            }
        default:
            response = nil
        }

        return ProcessResult(wrotePath: writtenPath, stdoutResponse: response)
    }

    private static func writeState(
        agent: String,
        sessionId: String,
        rawEvent: String,
        normEvent: String,
        payload: [String: Any],
        liveDir: String,
        now: TimeInterval
    ) -> String? {
        let fm = FileManager.default
        let parentDir = (liveDir as NSString).deletingLastPathComponent
        try? fm.createDirectory(atPath: parentDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? fm.createDirectory(atPath: liveDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        _ = chmod(liveDir, 0o700)

        let safeId = sanitizeFileToken(sessionId)
        let path = (liveDir as NSString).appendingPathComponent("\(agent)__\(safeId).json")
        let lockPath = (liveDir as NSString).appendingPathComponent(".\(agent)__\(safeId).lock")

        let lockFD = open(lockPath, O_CREAT | O_RDWR, 0o600)
        guard lockFD >= 0, flock(lockFD, LOCK_EX) == 0 else {
            if lockFD >= 0 { close(lockFD) }
            return nil
        }
        defer {
            _ = flock(lockFD, LOCK_UN)
            close(lockFD)
        }

        var prev: [String: Any] = [:]
        if let existingData = try? Data(contentsOf: URL(fileURLWithPath: path)),
           let loaded = try? JSONSerialization.jsonObject(with: existingData) as? [String: Any] {
            prev = loaded
        }

        var rec = prev
        rec["agent"] = agent
        rec["sessionId"] = sessionId
        rec["event"] = normEvent
        rec["rawEvent"] = rawEvent
        rec["updatedAt"] = now

        var cwd = firstNonEmptyString([payload["cwd"]])
        let wsRaw = (payload["workspacePaths"] as? [Any]) ?? (payload["workspace_roots"] as? [Any]) ?? []
        let ws = wsRaw.compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if !ws.isEmpty {
            rec["workspacePaths"] = ws
            if cwd.isEmpty { cwd = ws[0] }
        }
        if !cwd.isEmpty {
            rec["cwd"] = cwd
        }
        let transcriptPath = firstNonEmptyString([payload["transcriptPath"], payload["transcript_path"]])
        if !transcriptPath.isEmpty {
            rec["transcriptPath"] = transcriptPath
        }

        let userInput = cleanLine(firstNonEmptyString([
            payload["lastUserInput"],
            payload["prompt"],
            payload["user_prompt"]
        ]), limit: 180)
        if !userInput.isEmpty {
            rec["lastUserInput"] = userInput
            if firstNonEmptyString([rec["firstUserInput"]]).isEmpty {
                rec["firstUserInput"] = userInput
            }
        }

        let title = cleanLine(firstNonEmptyString([payload["title"], payload["session_title"]]), limit: 90)
        if !title.isEmpty {
            rec["title"] = title
        }

        var tName = ""
        var tArgs: [String: Any] = [:]
        if let toolCall = payload["toolCall"] as? [String: Any] {
            tName = firstNonEmptyString([toolCall["name"]])
            tArgs = toolCall["args"] as? [String: Any] ?? [:]
        } else {
            tName = firstNonEmptyString([payload["tool_name"], payload["toolName"]])
            tArgs = (payload["tool_input"] as? [String: Any]) ?? (payload["toolInput"] as? [String: Any]) ?? [:]
        }
        // Cursor hook payloads pass command/file_path at top-level
        if tName.isEmpty {
            if rawEvent == "beforeShellExecution" || rawEvent == "afterShellExecution" {
                tName = "shell"
                if let cmd = payload["command"] as? String { tArgs["command"] = cmd }
            } else if rawEvent == "afterFileEdit" {
                tName = "edit_file"
                if let fp = payload["file_path"] as? String { tArgs["file_path"] = fp }
            } else if rawEvent == "beforeReadFile" {
                tName = "read_file"
                if let fp = payload["file_path"] as? String { tArgs["file_path"] = fp }
            }
        }
        let tLabel = summarizeTool(name: tName, args: tArgs)

        switch normEvent {
        case "SessionStart":
            if rec["state"] == nil { rec["state"] = "idle" }

        case "UserPromptSubmit":
            let prevState = prev["state"] as? String ?? ""
            let prevStart = (prev["turnStartedAt"] as? NSNumber)?.doubleValue ?? 0
            if prevState != "running" || prevStart <= 0 {
                rec["turnStartedAt"] = now
            }
            rec["state"] = "running"
            rec["action"] = "思考规划中…"
            rec["terminationReason"] = ""
            rec["error"] = ""
            rec.removeValue(forKey: "completedAt")
            rec.removeValue(forKey: "durationSec")
            rec.removeValue(forKey: "fullyIdle")

        case "PreToolUse":
            let curStart = (rec["turnStartedAt"] as? NSNumber)?.doubleValue ?? 0
            if curStart <= 0 {
                rec["turnStartedAt"] = now
                rec.removeValue(forKey: "completedAt")
                rec.removeValue(forKey: "durationSec")
                rec["terminationReason"] = ""
                rec["error"] = ""
            }
            let lowName = tName.lowercased()
            if lowName == "ask_question" || lowName == "askuserquestion" {
                rec["state"] = "needs_input"
                rec["action"] = "等待你确认/回答"
            } else {
                rec["state"] = "running"
                if !tName.isEmpty { rec["toolName"] = tName }
                if !tLabel.isEmpty {
                    rec["action"] = tLabel
                    rec["lastToolLabel"] = tLabel
                }
            }

        case "NeedsInput":
            rec["state"] = "needs_input"
            rec["action"] = tLabel.isEmpty ? "等待你的审批或回复" : "等待确认 · \(tLabel)"

        case "Notification":
            let ntype = firstNonEmptyString([payload["notification_type"], payload["type"]]).lowercased()
            let nmsg = cleanLine(firstNonEmptyString([payload["message"], payload["title"]]), limit: 48)
            let lowMsg = nmsg.lowercased()
            if ntype.contains("permission")
                || ntype.contains("elicitation")
                || ntype.contains("input")
                || lowMsg.contains("approval")
                || lowMsg.contains("permission")
                || lowMsg.contains("waiting") {
                rec["state"] = "needs_input"
                rec["action"] = nmsg.isEmpty ? "等待你的审批或回复" : "等待确认 · \(nmsg)"
            }

        case "PostToolUse":
            rec["state"] = "running"
            if !tLabel.isEmpty { rec["lastToolLabel"] = tLabel }
            rec["action"] = "整理结果中…"

        case "Interrupt":
            rec["state"] = "canceled"
            rec["action"] = "已手动停止"
            rec["completedAt"] = now
            rec["turnStartedAt"] = 0

        case "Stop":
            let rawReason = firstNonEmptyString([payload["terminationReason"], payload["status"]])
            let upperReason = rawReason.uppercased()
            let err = cleanLine(firstNonEmptyString([payload["error"]]), limit: 160)
            let fullyIdle = (payload["fullyIdle"] as? Bool) ?? true
            rec["terminationReason"] = rawReason
            rec["fullyIdle"] = fullyIdle
            rec["error"] = err

            let turnStart = (rec["turnStartedAt"] as? NSNumber)?.doubleValue ?? 0
            if upperReason == "ERROR" || upperReason == "FAILED" || !err.isEmpty {
                rec["completedAt"] = now
                if turnStart > 0 { rec["durationSec"] = max(0.0, now - turnStart) }
                rec["state"] = "error"
                rec["action"] = err.isEmpty ? "执行出错" : "执行出错 · \(err)"
                rec["turnStartedAt"] = 0
            } else if upperReason == "USER_CANCELED" || upperReason == "ABORTED" || upperReason == "CANCELED" || upperReason == "CANCELLED" {
                rec["completedAt"] = now
                rec["state"] = "canceled"
                rec["action"] = "已手动停止"
                rec["turnStartedAt"] = 0
            } else if !fullyIdle {
                rec["state"] = "running"
                rec["action"] = "等待后台任务/子 Agent 完成…"
            } else {
                rec["completedAt"] = now
                if turnStart > 0 { rec["durationSec"] = max(0.0, now - turnStart) }
                rec["state"] = "done"
                rec["action"] = "已完成"
                rec["turnStartedAt"] = 0
            }

        default:
            break
        }

        guard let outData = try? JSONSerialization.data(withJSONObject: rec, options: []) else { return nil }
        let tmpPath = "\(path).tmp.\(getpid()).\(UUID().uuidString.prefix(8))"
        let fd = open(tmpPath, O_CREAT | O_WRONLY | O_TRUNC, 0o600)
        guard fd >= 0 else { return nil }
        let wroteAll = outData.withUnsafeBytes { rawBuf -> Bool in
            guard let base = rawBuf.baseAddress else { return true }
            var remaining = rawBuf.count
            var offset = 0
            while remaining > 0 {
                let n = write(fd, base.advanced(by: offset), remaining)
                if n <= 0 { return false }
                offset += n
                remaining -= n
            }
            return true
        }
        close(fd)
        guard wroteAll else {
            unlink(tmpPath)
            return nil
        }
        if rename(tmpPath, path) != 0 {
            unlink(tmpPath)
            return nil
        }
        return path
    }

    private static func firstNonEmptyString(_ candidates: [Any?]) -> String {
        for c in candidates {
            if let s = c as? String {
                let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { return t }
            }
        }
        return ""
    }

    private static func sanitizeFileToken(_ raw: String) -> String {
        String(raw.unicodeScalars.map { scalar -> Character in
            let v = scalar.value
            let ok = (v >= 48 && v <= 57) || (v >= 65 && v <= 90) || (v >= 97 && v <= 122) || v == 46 || v == 95 || v == 45
            return ok ? Character(scalar) : "_"
        })
    }

    private static func cleanLine(_ text: String, limit: Int) -> String {
        guard !text.isEmpty else { return "" }
        var s = text
        if let start = s.range(of: "<USER_REQUEST>"),
           let end = s.range(of: "</USER_REQUEST>", range: start.upperBound..<s.endIndex) {
            s = String(s[start.upperBound..<end.lowerBound])
        }
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if s.count > limit {
            s = String(s.prefix(max(1, limit - 1))) + "…"
        }
        return s
    }

    private static func summarizeTool(name: String, args: [String: Any]) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let low = trimmed.lowercased()
        func str(_ keys: [String]) -> String {
            firstNonEmptyString(keys.map { args[$0] })
        }

        if ["read_file", "view_file", "read"].contains(low) {
            let p = str(["Path", "AbsolutePath", "file_path", "path"])
            let base = p.isEmpty ? "" : (p as NSString).lastPathComponent
            return base.isEmpty ? "读取文件" : "读取 \(base)"
        }
        if ["write_file", "edit_file", "edit", "write", "multiedit", "replace_file_content", "multi_replace_file_content"].contains(low) {
            let p = str(["Path", "TargetFile", "file_path", "path"])
            let base = p.isEmpty ? "" : (p as NSString).lastPathComponent
            return base.isEmpty ? "修改文件" : "编辑 \(base)"
        }
        if low.contains("apply_edits") || low.contains("apply_patch") {
            if let edits = args["edits"] as? [[String: Any]], !edits.isEmpty {
                let firstPath = (edits[0]["path"] as? String) ?? ""
                let first = firstPath.isEmpty ? "" : (firstPath as NSString).lastPathComponent
                let suffix = edits.count > 1 ? " 等 \(edits.count) 个文件" : ""
                return first.isEmpty ? "批量编辑 \(edits.count) 个文件" : "批量编辑 \(first)\(suffix)"
            }
            return "应用代码补丁"
        }
        if ["run_command", "bash", "exec", "shell", "execute_command", "run_shell_command"].contains(low) {
            let summary = cleanLine(str(["toolSummary", "description"]), limit: 42)
            if !summary.isEmpty { return "执行 · \(summary)" }
            let cmd = cleanLine(str(["CommandLine", "command", "cmd"]), limit: 46)
            return cmd.isEmpty ? "运行终端命令" : "运行 `\(cmd)`"
        }
        if low.contains("run_checks") {
            let summary = cleanLine(str(["toolSummary"]), limit: 42)
            return summary.isEmpty ? "运行并行检查" : "并行检查 · \(summary)"
        }
        if low.contains("search") || ["grep", "glob", "find_by_name", "batch_search"].contains(low) {
            let summary = cleanLine(str(["toolSummary", "query", "pattern"]), limit: 38)
            if low.contains("web") {
                return summary.isEmpty ? "联网搜索" : "联网搜索 · \(summary)"
            }
            return summary.isEmpty ? "检索代码" : "检索 · \(summary)"
        }
        if low.contains("subagent") || low == "task" || low == "agent" {
            let role = cleanLine(str(["Role", "description", "TypeName"]), limit: 32)
            return role.isEmpty ? "派发子 Agent" : "派发子 Agent · \(role)"
        }
        if low.contains("browser") || low.contains("playwright") {
            return "操作浏览器"
        }
        if low == "ask_question" || low == "askuserquestion" {
            return "等待你确认/回答"
        }

        let summary = cleanLine(str(["toolSummary"]), limit: 36)
        if !summary.isEmpty { return "\(trimmed) · \(summary)" }
        return trimmed.isEmpty ? "" : "调用 \(trimmed)"
    }
}
