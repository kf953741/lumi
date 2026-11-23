import AppKit
import ApplicationServices
import Foundation

/// Inspects live Antigravity UI windows via macOS Accessibility (only while an Antigravity
/// agent is active — 0% idle CPU) to catch in-app confirmation prompts that do not emit hooks
/// (e.g., "Allow the browser agent to download a file?", browser origin approvals, command
/// permission dialogs, and interactive Submit/Skip prompts).
enum AntigravityAXPromptDetector {
    private static var configuredPIDs: Set<pid_t> = []
    private static let lock = NSLock()

    static func extractConversationId(from urlString: String) -> String? {
        guard let range = urlString.range(of: "/c/") else { return nil }
        let tail = urlString[range.upperBound...]
        let cid = tail.prefix { ch in
            ch.isLetter || ch.isNumber || ch == "-" || ch == "_"
        }
        return cid.count >= 8 ? String(cid) : nil
    }

    /// Pure classifier for active confirmation/approval prompt cards (zero false positives on
    /// normal Antigravity chat chrome, which only exposes `Cancel (⌃C)`, `Copy`, `Stop execution`, etc.).
    static func classifyPrompt(buttons: [String], texts: [String]) -> String? {
        let normButtons = buttons.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

        let hasSubmit = normButtons.contains { b in
            b == "submit" || b.hasPrefix("submit ") || b.hasPrefix("submit↵") || b.hasPrefix("submit\n") || b == "提交"
        }
        let hasSkip = normButtons.contains { b in
            b == "skip" || b.hasPrefix("skip ") || b == "跳过"
        }

        let hasApprove = normButtons.contains { b in
            b == "allow"
                || b == "always allow"
                || b == "allow once"
                || b == "allow for this session"
                || b.hasPrefix("yes, allow")
                || b.hasPrefix("allow this")
                || b == "approve"
                || b == "accept"
                || b == "accept all"
                || b == "run command"
                || b == "proceed"
                || b == "允许"
                || b == "同意"
                || b == "始终允许"
                || b == "确认允许"
        }
        let hasReject = normButtons.contains { b in
            b == "deny"
                || b == "reject"
                || b == "decline"
                || b == "skip"
                || b == "no"
                || b.hasPrefix("no (")
                || b.hasPrefix("no,")
                || b == "拒绝"
                || b == "不同意"
                || b == "跳过"
        }

        guard (hasSubmit && hasSkip) || (hasApprove && hasReject) else {
            return nil
        }

        // Extract the clearest human-readable prompt heading (search closest to bottom composer first)
        let candidates = texts.reversed().compactMap { raw -> String? in
            let s = ProjectNameHelper.cleanOneLine(raw, maxLength: 72)
            guard s.count >= 6 else { return nil }
            let low = s.lowercased()
            if low.hasPrefix("ask anything") || low.hasPrefix("load older") { return nil }
            return s
        }

        if let explicit = candidates.first(where: { s in
            let low = s.lowercased()
            return low.hasPrefix("allow ")
                || low.contains("browser agent to")
                || low.contains("wants to ")
                || low.contains("permission")
                || low.contains("approval")
                || low.hasPrefix("run ")
                || s.contains("允许")
                || s.contains("确认")
                || s.contains("批准")
        }) {
            return explicit
        }
        if let question = candidates.first(where: { $0.hasSuffix("?") || $0.hasSuffix("？") }) {
            return question
        }
        return "等待你的审批或回复"
    }

    static func detectPendingPrompts() -> [String: String] {
        guard AXIsProcessTrusted() else { return [:] }
        let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.antigravity")
        guard !runningApps.isEmpty else { return [:] }

        var detected: [String: String] = [:]

        for app in runningApps {
            let pid = app.processIdentifier
            let axApp = AXUIElementCreateApplication(pid)

            lock.lock()
            let needsEnable = !configuredPIDs.contains(pid)
            if needsEnable { configuredPIDs.insert(pid) }
            lock.unlock()
            if needsEnable {
                AXUIElementSetAttributeValue(axApp, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            }

            var winsRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &winsRef) == .success,
                  let windows = winsRef as? [AXUIElement] else {
                continue
            }

            for win in windows {
                let webAreas = findLocalUIWebAreas(in: win, depth: 0)
                for area in webAreas {
                    var urlRef: CFTypeRef?
                    AXUIElementCopyAttributeValue(area, kAXURLAttribute as CFString, &urlRef)
                    let urlStr = (urlRef as? URL)?.absoluteString ?? (urlRef as? String ?? "")
                    let activeConvId = extractConversationId(from: urlStr)

                    var buttons: [String] = []
                    var texts: [String] = []
                    var sidebarWaiting: [String: String] = [:]
                    var visited = 0

                    walkUI(
                        area,
                        depth: 0,
                        visited: &visited,
                        buttons: &buttons,
                        texts: &texts,
                        sidebarWaiting: &sidebarWaiting
                    )

                    for (cid, msg) in sidebarWaiting {
                        if detected[cid] == nil { detected[cid] = msg }
                    }
                    if let cid = activeConvId,
                       let prompt = classifyPrompt(buttons: buttons, texts: texts) {
                        detected[cid] = prompt
                    }
                }
            }
        }
        return detected
    }

    private static func findLocalUIWebAreas(in el: AXUIElement, depth: Int) -> [AXUIElement] {
        if depth > 12 { return [] }
        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &roleRef)
        if (roleRef as? String) == "AXWebArea" {
            var urlRef: CFTypeRef?
            AXUIElementCopyAttributeValue(el, kAXURLAttribute as CFString, &urlRef)
            let u = (urlRef as? URL)?.absoluteString ?? (urlRef as? String ?? "")
            if u.contains("127.0.0.1") || u.contains("localhost") {
                return [el]
            }
            return []
        }
        var out: [AXUIElement] = []
        var childrenRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &childrenRef) == .success,
           let children = childrenRef as? [AXUIElement] {
            for c in children {
                out.append(contentsOf: findLocalUIWebAreas(in: c, depth: depth + 1))
            }
        }
        return out
    }

    private static func collectDirectText(from el: AXUIElement, maxDepth: Int = 2) -> String {
        var parts: [String] = []
        func gather(_ node: AXUIElement, d: Int) {
            if d > maxDepth || parts.count >= 6 { return }
            var tRef: CFTypeRef?; var dRef: CFTypeRef?; var vRef: CFTypeRef?
            AXUIElementCopyAttributeValue(node, kAXTitleAttribute as CFString, &tRef)
            AXUIElementCopyAttributeValue(node, kAXDescriptionAttribute as CFString, &dRef)
            AXUIElementCopyAttributeValue(node, kAXValueAttribute as CFString, &vRef)
            for c in [tRef as? String, dRef as? String, vRef as? String] {
                if let s = c?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
                    parts.append(s)
                    break
                }
            }
            var kidsRef: CFTypeRef?
            if d < maxDepth,
               AXUIElementCopyAttributeValue(node, kAXChildrenAttribute as CFString, &kidsRef) == .success,
               let kids = kidsRef as? [AXUIElement] {
                for k in kids { gather(k, d: d + 1) }
            }
        }
        gather(el, d: 0)
        return parts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func walkUI(
        _ el: AXUIElement,
        depth: Int,
        visited: inout Int,
        buttons: inout [String],
        texts: inout [String],
        sidebarWaiting: inout [String: String]
    ) {
        if visited >= 1400 || depth > 28 { return }
        visited += 1

        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &roleRef)
        let role = roleRef as? String ?? ""

        if role == "AXButton" {
            let label = collectDirectText(from: el, maxDepth: 2)
            if !label.isEmpty {
                buttons.append(label)
            }
        } else if role == "AXStaticText" || role == "AXHeading" {
            var valRef: CFTypeRef?; var titleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &valRef)
            AXUIElementCopyAttributeValue(el, kAXTitleAttribute as CFString, &titleRef)
            if let s = (valRef as? String ?? titleRef as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !s.isEmpty, s.count <= 140 {
                texts.append(s)
            }
        } else if role == "AXLink" {
            var urlRef: CFTypeRef?
            AXUIElementCopyAttributeValue(el, kAXURLAttribute as CFString, &urlRef)
            let urlStr = (urlRef as? URL)?.absoluteString ?? (urlRef as? String ?? "")
            if let cid = extractConversationId(from: urlStr) {
                let combined = collectDirectText(from: el, maxDepth: 2).lowercased()
                if combined.contains("needs approval")
                    || combined.contains("waiting for approval")
                    || combined.contains("action required")
                    || combined.contains("requires approval")
                    || combined.contains("needs input")
                    || combined.contains("等待确认")
                    || combined.contains("需要批准") {
                    sidebarWaiting[cid] = "等待你的审批或回复"
                }
            }
        }

        var childrenRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &childrenRef) == .success,
           let children = childrenRef as? [AXUIElement] {
            for c in children {
                walkUI(c, depth: depth + 1, visited: &visited, buttons: &buttons, texts: &texts, sidebarWaiting: &sidebarWaiting)
                if visited >= 1400 { break }
            }
        }
    }
}

final class AntigravityScanner: @unchecked Sendable {
    private let dbPath: String
    private var lastKnownSessions: [AgentSession] = []
    private var lastDBFingerprint: String = ""
    private var cachedDBPayload: ([DBConversation], [String: String])?

    private struct DBConversation {
        let id: String
        let title: String
        let preview: String
        let status: String
        let source: String
        let workspaceURIs: String
        let nestingDepth: Int
        let parentId: String
        let notFullyIdle: Bool
        let lastModified: Date
        let lastUserInput: Date?
    }

    private let isoFracFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private let isoBasicFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    init() {
        self.dbPath = "\(NSHomeDirectory())/.gemini/antigravity/conversation_summaries.db"
    }

    func scan(lookbackHours: Double = 24) -> [AgentSession] {
        guard FileManager.default.fileExists(atPath: dbPath) else {
            lastKnownSessions = []
            return []
        }
        let now = Date()
        let cutoff = now.addingTimeInterval(-lookbackHours * 3600)
        guard let (dbRows, parentTable) = loadDBRowsAndParents() else {
            // Preserve last known sessions on transient SQLite lock/error instead of wiping UI
            return lastKnownSessions
        }
        let hookMap = LiveHookRecord.loadAll(forAgent: "antigravity")

        var byId: [String: DBConversation] = [:]
        for row in dbRows { byId[row.id] = row }

        // Only inspect Antigravity's macOS Accessibility tree while at least one agent is active (0% idle CPU)
        let hasAnyActive = dbRows.contains { $0.status == "CASCADE_RUN_STATUS_RUNNING" || $0.notFullyIdle }
            || hookMap.values.contains { ($0.state == "running" || $0.state == "needs_input") && now.timeIntervalSince($0.updatedAt) < 60 }
        let rawAXPrompts: [String: String] = hasAnyActive ? AntigravityAXPromptDetector.detectPendingPrompts() : [:]

        // Helper to resolve any subagent/conversation ID up to its root top-level conversation ID
        func rootConversationId(for id: String) -> String {
            var cur = id
            var hops = 0
            while !cur.isEmpty && hops < 6 {
                let p = byId[cur]?.parentId.isEmpty == false ? byId[cur]!.parentId : (parentTable[cur] ?? "")
                if !p.isEmpty { cur = p } else { break }
                hops += 1
            }
            return cur
        }

        // Map live AX prompts (including subagent tabs) to their root conversation ID
        var axNeedsInputByRoot: [String: String] = [:]
        for (cid, prompt) in rawAXPrompts {
            let root = rootConversationId(for: cid)
            if !root.isEmpty {
                axNeedsInputByRoot[root] = prompt
            }
        }

        // Roll up active child subagents (and any child `needs_input` prompts!) onto their root parent conversation
        var activeSubagents: [String: Int] = [:]
        var activeSubagentAction: [String: (Date, String)] = [:]
        var subagentNeedsInput: [String: (Date, String)] = [:]
        for row in dbRows {
            let explicitParent = !row.parentId.isEmpty ? row.parentId : (parentTable[row.id] ?? "")
            guard !explicitParent.isEmpty || row.nestingDepth > 0 else { continue }
            let hook = hookMap[row.id]
            let isChildNeedsInput = (hook?.state == "needs_input" && now.timeIntervalSince(hook?.updatedAt ?? .distantPast) < 1200)
            let isRunning = row.status == "CASCADE_RUN_STATUS_RUNNING"
                || row.notFullyIdle
                || isChildNeedsInput
                || (hook?.state == "running" && now.timeIntervalSince(hook?.updatedAt ?? .distantPast) < 45)
            guard isRunning else { continue }

            let root = rootConversationId(for: explicitParent)
            if !root.isEmpty {
                activeSubagents[root, default: 0] += 1
                if isChildNeedsInput, let hook {
                    let msg = hook.action.isEmpty ? "等待你的审批或回复" : hook.action
                    if let existing = subagentNeedsInput[root] {
                        if hook.updatedAt > existing.0 { subagentNeedsInput[root] = (hook.updatedAt, msg) }
                    } else {
                        subagentNeedsInput[root] = (hook.updatedAt, msg)
                    }
                } else if let hook, hook.state == "running", !hook.action.isEmpty,
                          now.timeIntervalSince(hook.updatedAt) < 120 {
                    if let existing = activeSubagentAction[root] {
                        if hook.updatedAt > existing.0 {
                            activeSubagentAction[root] = (hook.updatedAt, hook.action)
                        }
                    } else {
                        activeSubagentAction[root] = (hook.updatedAt, hook.action)
                    }
                }
            }
        }

        var results: [AgentSession] = []

        for row in dbRows {
            // Strictly exclude ALL child subagents (both via nesting_depth/parent_conversation_id AND conversation_parents table)
            if row.nestingDepth > 0 || !row.parentId.isEmpty || parentTable[row.id] != nil {
                continue
            }
            let subCount = activeSubagents[row.id] ?? 0
            let promptFromAX = axNeedsInputByRoot[row.id]
            let promptFromSubagent = subagentNeedsInput[row.id]?.1
            let dbSaysRunning = (row.status == "CASCADE_RUN_STATUS_RUNNING") || row.notFullyIdle || (subCount > 0) || (promptFromAX != nil)
            guard row.lastModified >= cutoff || dbSaysRunning else { continue }
            let session = buildSession(
                db: row,
                hook: hookMap[row.id],
                subCount: subCount,
                subAction: activeSubagentAction[row.id]?.1,
                livePrompt: promptFromAX ?? promptFromSubagent,
                now: now
            )
            results.append(session)
        }

        // NOTE: Do NOT emit hook-only Antigravity sessions absent from conversation_summaries.db.
        // Subagents and ephemeral helpers fire hooks before DB checkpointing; waiting for the verified
        // top-level DB row (nesting_depth == 0) guarantees subagents never leak as fake completions.
        lastKnownSessions = results
        return results
    }

    private func buildSession(db: DBConversation, hook: LiveHookRecord?, subCount: Int, subAction: String?, livePrompt: String?, now: Date) -> AgentSession {
        let isCLI = db.source.contains("CLI")
        let wsPath = parseFirstWorkspaceURI(db.workspaceURIs)
            ?? hook?.workspacePaths.first
            ?? hook?.cwd
            ?? ""
        let project = ProjectNameHelper.projectName(from: wsPath)

        let rawTitle: String
        if !db.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            rawTitle = db.title
        } else if !db.preview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            rawTitle = db.preview
        } else if let h = hook, !h.firstUserInput.isEmpty {
            rawTitle = h.firstUserInput
        } else if let h = hook, !h.lastUserInput.isEmpty {
            rawTitle = h.lastUserInput
        } else {
            rawTitle = project.isEmpty ? "对话 \(db.id.prefix(6))" : project
        }
        let cleanTitle = ProjectNameHelper.cleanOneLine(rawTitle, maxLength: 78)

        let dbSaysRunning = (db.status == "CASCADE_RUN_STATUS_RUNNING") || db.notFullyIdle || (subCount > 0)
        let hookFresher = hook.map { $0.updatedAt.timeIntervalSince(db.lastModified) > 1.5 } ?? false
        let hookRunningRecent = hook.map { $0.state == "running" && now.timeIntervalSince($0.updatedAt) < 300 } ?? false
        let hookNeedsInput = hook.map { $0.state == "needs_input" && now.timeIntervalSince($0.updatedAt) < 1200 } ?? false

        // Live AX prompt or explicit needs_input hook ALWAYS takes priority so approvals never hide behind "running".
        let status: SessionStatus
        if livePrompt != nil || (hookNeedsInput && (dbSaysRunning || hookFresher)) {
            status = .needsInput
        } else if dbSaysRunning {
            status = .running
        } else if hookRunningRecent && hookFresher {
            status = .running
        } else if let hook, hook.state == "error" && abs(hook.updatedAt.timeIntervalSince(db.lastModified)) < 30 {
            status = .error
        } else if let hook, hook.state == "canceled" && abs(hook.updatedAt.timeIntervalSince(db.lastModified)) < 30 {
            status = .canceled
        } else {
            status = .done
        }

        let action: String
        if status == .needsInput {
            if let livePrompt, !livePrompt.isEmpty {
                action = livePrompt == "等待你的审批或回复" ? livePrompt : "等待确认 · \(livePrompt)"
            } else {
                action = hook?.action.isEmpty == false ? (hook?.action ?? "等待你的审批或回复") : "等待你的审批或回复"
            }
        } else if status == .running {
            if let hook, !hook.action.isEmpty, hook.state == "running", now.timeIntervalSince(hook.updatedAt) < 120 {
                action = hook.action
            } else if let subAction, !subAction.isEmpty {
                action = "子任务 · \(subAction)"
            } else if subCount > 0 {
                action = "等待 \(subCount) 个子 Agent 执行…"
            } else if db.notFullyIdle && db.status != "CASCADE_RUN_STATUS_RUNNING" {
                action = "后台任务运行中…"
            } else {
                action = "思考与执行中…"
            }
        } else if status == .error {
            action = hook?.action.isEmpty == false ? (hook?.action ?? "执行出错") : "执行出错"
        } else if status == .canceled {
            action = "已手动停止"
        } else {
            action = "已完成"
        }

        let updatedAt = max(db.lastModified, hook?.updatedAt ?? .distantPast)
        let startedAt: Date? = hook?.turnStartedAt ?? db.lastUserInput
        let completedAt: Date?
        if status == .running {
            completedAt = nil
        } else if let hc = hook?.completedAt, abs(hc.timeIntervalSince(db.lastModified)) < 45 {
            completedAt = max(hc, db.lastModified)
        } else {
            completedAt = db.lastModified
        }

        var durationSec: TimeInterval? = hook?.durationSec
        if durationSec == nil, let comp = completedAt, let start = db.lastUserInput {
            let diff = comp.timeIntervalSince(start)
            if diff >= 1 && diff < 14_400 { durationSec = diff }
        }

        return AgentSession(
            id: "antigravity:\(db.id)",
            rawId: db.id,
            kind: .antigravity,
            title: cleanTitle,
            project: project.isEmpty ? "独立对话" : project,
            cwd: wsPath,
            isCLI: isCLI,
            status: status,
            currentAction: action,
            detailSummary: "",
            startedAt: startedAt,
            updatedAt: updatedAt,
            completedAt: completedAt,
            durationSec: durationSec,
            activeSubagents: subCount,
            isUnread: false
        )
    }

    private func computeDBFingerprint() -> String {
        var parts: [String] = []
        for p in [dbPath, dbPath + "-wal"] {
            var st = stat()
            if stat(p, &st) == 0 {
                parts.append("\(st.st_size):\(st.st_mtimespec.tv_sec).\(st.st_mtimespec.tv_nsec)")
            } else {
                parts.append("none")
            }
        }
        return parts.joined(separator: "|")
    }

    private func loadDBRowsAndParents() -> ([DBConversation], [String: String])? {
        let fp = computeDBFingerprint()
        if fp == lastDBFingerprint, let cached = cachedDBPayload {
            return cached
        }
        guard let reader = SQLiteReader(path: dbPath) else { return nil }

        var parentMap: [String: String] = [:]
        _ = reader.query("SELECT conversation_id, parent_id FROM conversation_parents;") { stmt in
            let cid = SQLiteReader.string(stmt, 0)
            let pid = SQLiteReader.string(stmt, 1)
            if !cid.isEmpty && !pid.isEmpty { parentMap[cid] = pid }
        }

        var rows: [DBConversation] = []
        let sql = """
        SELECT conversation_id, title, preview, status, source, workspace_uris,
               nesting_depth, parent_conversation_id, not_fully_idle,
               last_modified_time, last_user_input_time
        FROM conversation_summaries
        WHERE killed = 0
        ORDER BY (status = 'CASCADE_RUN_STATUS_RUNNING' OR not_fully_idle != 0) DESC,
                 last_modified_time DESC
        LIMIT 160;
        """
        let ok = reader.query(sql) { stmt in
            let id = SQLiteReader.string(stmt, 0)
            guard !id.isEmpty else { return }
            rows.append(DBConversation(
                id: id,
                title: SQLiteReader.string(stmt, 1),
                preview: SQLiteReader.string(stmt, 2),
                status: SQLiteReader.string(stmt, 3),
                source: SQLiteReader.string(stmt, 4),
                workspaceURIs: SQLiteReader.string(stmt, 5),
                nestingDepth: SQLiteReader.int(stmt, 6),
                parentId: SQLiteReader.string(stmt, 7),
                notFullyIdle: SQLiteReader.int(stmt, 8) != 0,
                lastModified: parseSQLiteDate(SQLiteReader.string(stmt, 9)) ?? .distantPast,
                lastUserInput: parseSQLiteDate(SQLiteReader.string(stmt, 10))
            ))
        }
        guard ok else { return nil }
        lastDBFingerprint = fp
        cachedDBPayload = (rows, parentMap)
        return (rows, parentMap)
    }

    private func parseFirstWorkspaceURI(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("["),
           let data = trimmed.data(using: .utf8),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [String],
           let first = arr.first, !first.isEmpty {
            return first
        }
        return trimmed
    }

    /// Lock-free ASCII parser for SQLite ISO timestamps (`YYYY-MM-DD[T ]HH:MM:SS[.ffffff][Z|+HH:MM|-HH:MM]`).
    private func parseSQLiteDate(_ raw: String) -> Date? {
        guard !raw.isEmpty else { return nil }
        let bytes = Array(raw.utf8)
        let n = bytes.count
        if n >= 19,
           bytes[4] == 45, bytes[7] == 45, (bytes[10] == 84 || bytes[10] == 32),
           bytes[13] == 58, bytes[16] == 58 {
            @inline(__always)
            func digits(_ i: Int, _ len: Int) -> Int? {
                guard i + len <= n else { return nil }
                var v = 0
                for k in 0..<len {
                    let c = Int(bytes[i + k]) - 48
                    if c < 0 || c > 9 { return nil }
                    v = v * 10 + c
                }
                return v
            }
            if let year = digits(0, 4),
               let month = digits(5, 2), month >= 1, month <= 12,
               let day = digits(8, 2), day >= 1, day <= 31,
               let hour = digits(11, 2), hour <= 23,
               let minute = digits(14, 2), minute <= 59,
               let second = digits(17, 2), second <= 60 {
                var idx = 19
                var frac = 0.0
                if idx < n && bytes[idx] == 46 { // '.'
                    idx += 1
                    var scale = 0.1
                    while idx < n {
                        let c = Int(bytes[idx]) - 48
                        if c < 0 || c > 9 { break }
                        frac += Double(c) * scale
                        scale *= 0.1
                        idx += 1
                    }
                }
                var tzOffsetSec = 0
                var tzOk = true
                if idx == n || (idx == n - 1 && bytes[idx] == 90) { // bare UTC or 'Z'
                    tzOffsetSec = 0
                } else if (bytes[idx] == 43 || bytes[idx] == 45) { // '+' or '-'
                    let sign = bytes[idx] == 43 ? 1 : -1
                    idx += 1
                    if idx + 5 == n && bytes[idx + 2] == 58,
                       let tzh = digits(idx, 2), let tzm = digits(idx + 3, 2) {
                        tzOffsetSec = sign * (tzh * 3600 + tzm * 60)
                    } else if idx + 4 == n,
                              let tzh = digits(idx, 2), let tzm = digits(idx + 2, 2) {
                        tzOffsetSec = sign * (tzh * 3600 + tzm * 60)
                    } else {
                        tzOk = false
                    }
                } else {
                    tzOk = false
                }
                if tzOk {
                    let y = month <= 2 ? year - 1 : year
                    let era = (y >= 0 ? y : y - 399) / 400
                    let yoe = y - era * 400
                    let mAdj = month + (month > 2 ? -3 : 9)
                    let doy = (153 * mAdj + 2) / 5 + day - 1
                    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
                    let days = era * 146097 + doe - 719468
                    let secs = Double(days * 86400 + hour * 3600 + minute * 60 + second - tzOffsetSec) + frac
                    return Date(timeIntervalSince1970: secs)
                }
            }
        }
        let normalized = raw.replacingOccurrences(of: " ", with: "T")
        if let d = isoFracFormatter.date(from: normalized) { return d }
        return isoBasicFormatter.date(from: normalized)
    }
}
