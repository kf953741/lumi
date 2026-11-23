import AppKit
import ApplicationServices
import Foundation

struct GeminiAXButton: Equatable, Sendable {
    let identifier: String
    let title: String
    let description: String
}

struct GeminiSidebarTask: Equatable, Sendable {
    let title: String
    let status: SessionStatus
    let action: String
}

/// Pure, unit-testable classifier for macOS Gemini Desktop (`com.google.GeminiMacOS`)
/// Accessibility windows, sidebar task badges, and `googlegemini://conversation/<id>` deep links.
enum GeminiDesktopClassifier {
    private static let nonChatWindowTitles: Set<String> = [
        "用量限额", "外观", "快捷键", "个性化智能服务", "gemini 的声音", "speak to window",
        "任务", "关于", "扩展程序", "调试", "设置", "账号关联", "发送反馈", "报告问题",
        "登录 gemini", "gemini 新用户引导",
        "settings", "usage limits", "appearance", "shortcuts", "keyboard shortcuts",
        "about", "extensions", "debug", "account linking", "send feedback",
        "report an issue", "gemini sign in", "gemini onboarding"
    ]

    private static let titlePrefixes: [String] = [
        "Gemini 迷你对话 - ",
        "Gemini 迷你对话 — ",
        "Gemini 迷你对话 – ",
        "Gemini Mini Chat - ",
        "Gemini Mini Chat — ",
        "Gemini Mini Chat – ",
        "Gemini - ",
        "Gemini — ",
        "Gemini – "
    ]

    private static let bareChatTitles: Set<String> = [
        "gemini", "gemini 迷你对话", "gemini mini chat"
    ]

    /// Extracts the conversation title from a Gemini Desktop window title.
    /// Returns `nil` if the window is a non-chat window (e.g., Settings / Usage Limits).
    /// Returns `""` if it is a valid Gemini chat window without a specific title yet (e.g., New Chat).
    static func extractChatTitle(fromWindowTitle raw: String, hasChatControls: Bool = false) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()

        if nonChatWindowTitles.contains(lower) {
            return nil
        }
        for prefix in titlePrefixes {
            if trimmed.hasPrefix(prefix) {
                return String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        if bareChatTitles.contains(lower) {
            return ""
        }
        if hasChatControls {
            return trimmed
        }
        return nil
    }

    /// Parses a Gemini Desktop sidebar row Accessibility description containing an official task badge
    /// (`SIDEBAR_ROW_TASK_BADGE_ACCESSIBILITY_LABEL`: `"%1$@, %2$@"` / `"“%1$@”，%2$@"`).
    static func parseSidebarTaskRow(_ rawLabel: String) -> GeminiSidebarTask? {
        let s = rawLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }

        let suffixes: [(suffix: String, status: SessionStatus, action: String)] = [
            ("，进行中", .running, "后台任务进行中…"),
            (", 进行中", .running, "后台任务进行中…"),
            (", In progress", .running, "后台任务进行中…"),
            (", in progress", .running, "后台任务进行中…"),
            ("，需要注意", .needsInput, "需要你的确认或协助"),
            (", 需要注意", .needsInput, "需要你的确认或协助"),
            (", Needs attention", .needsInput, "需要你的确认或协助"),
            (", needs attention", .needsInput, "需要你的确认或协助"),
            ("，准备就绪", .done, "任务已完成"),
            (", 准备就绪", .done, "任务已完成"),
            (", Ready", .done, "任务已完成"),
            (", ready", .done, "任务已完成")
        ]

        let lower = s.lowercased()
        for item in suffixes {
            let sufLower = item.suffix.lowercased()
            if lower.hasSuffix(sufLower) {
                var titlePart = String(s.dropLast(item.suffix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                titlePart = cleanSidebarTitle(titlePart)
                guard !titlePart.isEmpty else { return nil }
                return GeminiSidebarTask(title: titlePart, status: item.status, action: item.action)
            }
        }
        return nil
    }

    static func cleanSidebarTitle(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let pinnedSuffixes = ["，已固定", ", 已固定", ", Pinned", ", pinned"]
        for ps in pinnedSuffixes {
            if s.lowercased().hasSuffix(ps.lowercased()) {
                s = String(s.dropLast(ps.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        if (s.hasPrefix("“") && s.hasSuffix("”")) || (s.hasPrefix("\"") && s.hasSuffix("\"")) {
            s = String(s.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return s
    }

    /// Classifies an open Gemini Desktop chat window's live state from its AX buttons and short status labels.
    static func classifyWindow(buttons: [GeminiAXButton], statusTexts: [String]) -> (status: SessionStatus, action: String) {
        let normButtons: [(id: String, label: String)] = buttons.map { btn in
            let id = btn.identifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let label = [btn.description, btn.title]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty } ?? ""
            return (id, label)
        }
        let lowerLabels = normButtons.map { $0.label.lowercased() }
        let shortTexts = statusTexts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.count <= 110 }

        // 1. Needs Input / Inline Confirmation / Computer Use Approval (highest priority)
        let strongApproveButtons = ["允许一次", "allow once", "允许在此对话中使用", "allow for this chat"]
        let hasStrongApprove = lowerLabels.contains { lbl in
            strongApproveButtons.contains(lbl)
        }
        let hasGenericAllow = lowerLabels.contains { $0 == "允许" || $0 == "allow" }
        let hasDismissChoice = lowerLabels.contains { $0 == "暂不" || $0 == "not now" || $0 == "拒绝" || $0 == "deny" || $0 == "取消" || $0 == "cancel" }

        let waitingText = shortTexts.first { txt in
            let low = txt.lowercased()
            return low.contains("正在等待你输入")
                || low.contains("waiting for your input")
                || low == "正在等待输入"
                || low == "waiting for input"
                || low.contains("gemini 需要你协助完成此步骤")
                || low.contains("gemini needs your help with this step")
                || low.contains("gemini 需要你在")
        }

        if hasStrongApprove || (hasGenericAllow && hasDismissChoice) || waitingText != nil {
            let promptText = waitingText ?? shortTexts.first { txt in
                let low = txt.lowercased()
                return (low.hasPrefix("allow ") || low.hasPrefix("let gemini ") || low.contains("允许 gemini") || low.contains("是否允许"))
                    && (txt.hasSuffix("?") || txt.hasSuffix("？"))
            }
            if let promptText {
                let clean = ProjectNameHelper.cleanOneLine(promptText, maxLength: 36)
                if !clean.isEmpty {
                    return (.needsInput, "等待确认 · \(clean)")
                }
            }
            return (.needsInput, "等待你的审批或回复")
        }

        // 2. Running / Generating Response / Active Task
        let mediaExcludedTokens = ["record", "mic", "audio", "voice", "video", "screen", "reload", "录音", "麦克风", "共享屏幕", "语音"]
        for btn in normButtons {
            let low = btn.label.lowercased()
            let combined = "\(btn.id) \(low)"
            if mediaExcludedTokens.contains(where: { combined.contains($0) }) {
                continue
            }
            if low == "停止回答" || low == "stop response" || low == "停止生成" || low == "stop generating" {
                return (.running, "生成回答中…")
            }
            if low == "停止任务" || low == "stop task" {
                return (.running, "执行桌面任务中…")
            }
            if btn.id.contains("inputstopbutton")
                || btn.id == "stop_button"
                || btn.id == "stop-response-button"
                || btn.id == "textstopbuttonid" {
                return (.running, "生成回答中…")
            }
            if low == "停止" || low == "stop" {
                return (.running, "执行桌面任务中…")
            }
        }

        for txt in shortTexts {
            let low = txt.lowercased()
            if low == "正在处理中" || low == "正在处理中…" || low == "working on it" || low == "working on it…"
                || low == "正在初始化任务" || low == "正在初始化任务…" || low == "initializing task" || low == "initializing task…" {
                return (.running, "执行桌面任务中…")
            }
            if low == "正在等待 gemini 回答" || low == "waiting for gemini response"
                || low == "正在生成微件…" || low == "generating widget…" {
                return (.running, "生成回答中…")
            }
        }

        return (.done, "已完成")
    }

    /// Builds Gemini Desktop's official `googlegemini://conversation/<conversationId>` deep link.
    static func deepLinkURL(conversationId: String) -> URL? {
        let trimmed = conversationId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/"), !trimmed.contains(" ") else { return nil }
        return URL(string: "googlegemini://conversation/\(trimmed)")
    }

    static func normalizedKey(from title: String) -> String {
        let cleaned = ProjectNameHelper.cleanOneLine(title, maxLength: 72).lowercased()
        return cleaned.isEmpty ? "active-chat" : cleaned
    }
}

/// Zero-config live monitor for the native macOS Gemini Desktop app (`com.google.GeminiMacOS`).
/// Combines:
/// - Live macOS Accessibility inspection of open Gemini chat windows & sidebar task badges
///   (`停止回答`/`Stop response`, `允许一次`/`Allow once`, `进行中`/`需要注意的是`/`准备就绪`)
/// - Read-only WAL-safe `ChatInfo2.store` timestamp & conversation-ID correlation
///   (`~/Library/Caches/com.google.GeminiMacOS/Gemini/user*/ChatInfo2.store`)
final class GeminiDesktopScanner: @unchecked Sendable {
    static let bundleID = "com.google.GeminiMacOS"

    private let cachesRoot: String
    private let lock = NSLock()
    private var trackedChats: [String: TrackedChat] = [:]
    private var sessionDeepLinks: [String: URL] = [:]
    private var didFirstScan = false
    private var lastAXScanAt: Date = .distantPast
    private var lastDBStamp: String = ""
    private var cachedDBChat: RecentDBChat?

    private static let axBatchAttributes: CFArray = [
        kAXRoleAttribute,
        kAXIdentifierAttribute,
        kAXTitleAttribute,
        kAXDescriptionAttribute,
        kAXChildrenAttribute
    ] as CFArray

    private struct TrackedChat {
        let key: String
        var title: String
        var status: SessionStatus
        var action: String
        var startedAt: Date?
        var updatedAt: Date
        var completedAt: Date?
        var durationSec: TimeInterval?
        var conversationId: String?
    }

    private struct RecentDBChat {
        let chatUUID: String
        let robinConversationId: String
        let updatedAt: Date
    }

    private struct InspectedWindow {
        let title: String
        let status: SessionStatus
        let action: String
        let sidebarTasks: [GeminiSidebarTask]
    }

    init(cachesRoot: String = "\(NSHomeDirectory())/Library/Caches/com.google.GeminiMacOS/Gemini") {
        self.cachesRoot = cachesRoot
    }

    func deepLinkURL(forSessionId sessionId: String) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        return sessionDeepLinks[sessionId]
    }

    func scan(lookbackHours: Double = 24, now: Date = Date()) -> [AgentSession] {
        let cutoff = now.addingTimeInterval(-lookbackHours * 3600)
        let runningApp = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).first

        guard let runningApp else {
            return snapshotWhenClosed(cutoff: cutoff, now: now)
        }

        let dbStamp = computeDBStamp()
        lock.lock()
        let dbChanged = (dbStamp != lastDBStamp)
        let hasTrackedActive = trackedChats.values.contains { $0.status == .running || $0.status == .needsInput }
        let axAge = now.timeIntervalSince(lastAXScanAt)
        let cachedDB = cachedDBChat
        let wasFirstScanDone = didFirstScan
        lock.unlock()

        let recentDB: RecentDBChat?
        if dbChanged || !wasFirstScanDone {
            let fresh = readMostRecentDBChat()
            lock.lock()
            lastDBStamp = dbStamp
            cachedDBChat = fresh
            lock.unlock()
            recentDB = fresh
        } else {
            recentDB = cachedDB
        }

        // Adaptive AX polling: scan immediately when active, frontmost, or DB changed;
        // throttle background idle polling to every 6s to keep CPU & Mach IPC near 0%.
        let isFrontmost = runningApp.isActive
        let shouldRunAX = !wasFirstScanDone || hasTrackedActive || dbChanged || isFrontmost || axAge >= 6.0
        guard shouldRunAX else {
            lock.lock()
            defer { lock.unlock() }
            return buildSessionsLocked()
        }

        let windows = AXIsProcessTrusted() ? inspectWindows(pid: runningApp.processIdentifier) : []

        lock.lock()
        defer { lock.unlock() }

        let isFirst = !didFirstScan
        didFirstScan = true
        lastAXScanAt = now

        var seenActiveKeys = Set<String>()
        var seenWindowKeys = Set<String>()
        var sidebarTasks: [GeminiSidebarTask] = []

        // 1. Process all open Gemini Desktop chat windows
        for win in windows {
            sidebarTasks.append(contentsOf: win.sidebarTasks)
            let displayTitle = win.title.isEmpty ? "Gemini 桌面对话" : win.title
            let key = GeminiDesktopClassifier.normalizedKey(from: displayTitle)
            seenWindowKeys.insert(key)

            let isActive = (win.status == .running || win.status == .needsInput)
            if isActive { seenActiveKeys.insert(key) }

            let matchedConvId: String? = {
                // Only bind ChatInfo2's most recent conversation ID to a chat we actually observe running/finishing now
                if let db = recentDB, abs(now.timeIntervalSince(db.updatedAt)) <= 90 {
                    return db.robinConversationId.isEmpty ? db.chatUUID : db.robinConversationId
                }
                return nil
            }()

            if var existing = trackedChats[key] {
                existing.title = displayTitle
                if isActive {
                    if let cid = matchedConvId {
                        existing.conversationId = cid
                    }
                    if existing.status != .running && existing.status != .needsInput {
                        existing.startedAt = now
                    }
                    existing.status = win.status
                    existing.action = win.action
                    existing.updatedAt = now
                    existing.completedAt = nil
                    existing.durationSec = nil
                } else if existing.status == .running || existing.status == .needsInput {
                    if let cid = matchedConvId, existing.conversationId == nil {
                        existing.conversationId = cid
                    }
                    existing.status = .done
                    existing.action = "已完成"
                    existing.completedAt = now
                    existing.updatedAt = now
                    if let st = existing.startedAt {
                        existing.durationSec = max(1, now.timeIntervalSince(st))
                    }
                }
                trackedChats[key] = existing
            } else if isActive {
                // Never synthesize a `.done` entry when the user merely clicks/views an already-idle historical chat.
                trackedChats[key] = TrackedChat(
                    key: key,
                    title: displayTitle,
                    status: win.status,
                    action: win.action,
                    startedAt: now,
                    updatedAt: now,
                    completedAt: nil,
                    durationSec: nil,
                    conversationId: matchedConvId
                )
            }
        }

        // 2. Process background sidebar tasks (chats NOT currently open in an active window)
        var seenSidebarKeys = Set<String>()
        for task in sidebarTasks {
            let key = GeminiDesktopClassifier.normalizedKey(from: task.title)
            guard !seenWindowKeys.contains(key), !seenSidebarKeys.contains(key) else { continue }
            seenSidebarKeys.insert(key)

            let isActive = (task.status == .running || task.status == .needsInput)
            if isActive { seenActiveKeys.insert(key) }

            if var existing = trackedChats[key] {
                existing.title = task.title
                if isActive {
                    if existing.status != .running && existing.status != .needsInput {
                        existing.startedAt = now
                    }
                    existing.status = task.status
                    existing.action = task.action
                    existing.updatedAt = now
                    existing.completedAt = nil
                    existing.durationSec = nil
                } else if existing.status == .running || existing.status == .needsInput {
                    existing.status = .done
                    existing.action = task.action
                    existing.completedAt = now
                    existing.updatedAt = now
                    if let st = existing.startedAt {
                        existing.durationSec = max(1, now.timeIntervalSince(st))
                    }
                }
                trackedChats[key] = existing
            } else if isActive {
                trackedChats[key] = TrackedChat(
                    key: key,
                    title: task.title,
                    status: task.status,
                    action: task.action,
                    startedAt: now,
                    updatedAt: now,
                    completedAt: nil,
                    durationSec: nil,
                    conversationId: nil
                )
            } else if task.status == .done {
                // Sidebar `Ready` / `准备就绪` badge: avoid spam on initial scan, alert if newly appearing mid-session
                let ts = isFirst ? now.addingTimeInterval(-1200) : now
                trackedChats[key] = TrackedChat(
                    key: key,
                    title: task.title,
                    status: .done,
                    action: task.action,
                    startedAt: nil,
                    updatedAt: ts,
                    completedAt: ts,
                    durationSec: nil,
                    conversationId: nil
                )
            }
        }

        // 3. Any previously running/needsInput chat that vanished from both windows & sidebar tasks finished cleanly
        for (key, var chat) in trackedChats where (chat.status == .running || chat.status == .needsInput) && !seenActiveKeys.contains(key) {
            chat.status = .done
            chat.action = "已完成"
            chat.completedAt = now
            chat.updatedAt = now
            if let st = chat.startedAt {
                chat.durationSec = max(1, now.timeIntervalSince(st))
            }
            trackedChats[key] = chat
        }

        // Prune expired entries
        trackedChats = trackedChats.filter { _, chat in
            chat.status == .running || chat.status == .needsInput || chat.updatedAt >= cutoff
        }

        return buildSessionsLocked()
    }

    private func snapshotWhenClosed(cutoff: Date, now: Date) -> [AgentSession] {
        lock.lock()
        defer { lock.unlock() }
        for (key, var chat) in trackedChats where chat.status == .running || chat.status == .needsInput {
            chat.status = .done
            chat.action = "已完成"
            chat.completedAt = now
            chat.updatedAt = now
            trackedChats[key] = chat
        }
        trackedChats = trackedChats.filter { _, chat in chat.updatedAt >= cutoff }
        return buildSessionsLocked()
    }

    private func buildSessionsLocked() -> [AgentSession] {
        var links: [String: URL] = [:]
        let sessions: [AgentSession] = trackedChats.values.map { chat in
            let sessionId = "gemini:desktop:\(chat.key)"
            if let cid = chat.conversationId, let url = GeminiDesktopClassifier.deepLinkURL(conversationId: cid) {
                links[sessionId] = url
            }
            return AgentSession(
                id: sessionId,
                rawId: chat.conversationId ?? chat.key,
                kind: .gemini,
                title: chat.title,
                project: "Gemini 桌面版",
                cwd: "",
                isCLI: false,
                status: chat.status,
                currentAction: chat.action,
                detailSummary: "",
                startedAt: chat.startedAt,
                updatedAt: chat.updatedAt,
                completedAt: chat.completedAt,
                durationSec: chat.durationSec,
                activeSubagents: 0,
                isUnread: false
            )
        }
        sessionDeepLinks = links
        return sessions
    }

    // MARK: - Read-Only ChatInfo2.store WAL Correlation

    private func computeDBStamp() -> String {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: cachesRoot) else { return "" }
        var parts: [String] = []
        for entry in entries.sorted() where entry.hasPrefix("user") {
            for suffix in ["ChatInfo2.store", "ChatInfo2.store-wal"] {
                let p = "\(cachesRoot)/\(entry)/\(suffix)"
                var st = stat()
                if stat(p, &st) == 0 {
                    parts.append("\(entry)/\(suffix):\(st.st_size):\(st.st_mtimespec.tv_sec).\(st.st_mtimespec.tv_nsec)")
                }
            }
        }
        return parts.joined(separator: "|")
    }

    private func readMostRecentDBChat() -> RecentDBChat? {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: cachesRoot) else { return nil }
        var best: RecentDBChat?

        for entry in entries where entry.hasPrefix("user") {
            let dbPath = "\(cachesRoot)/\(entry)/ChatInfo2.store"
            guard fm.fileExists(atPath: dbPath), let reader = SQLiteReader(path: dbPath) else { continue }

            // Use ZLASTUPDATEDTIME (true server conversation update time), NOT ZCHATMESSAGESTOREDMODEL.ZCREATEDTIME
            // (which is merely the local cache download timestamp when the user views an old uncached chat).
            reader.query("""
                SELECT ZCHATUUID,
                       COALESCE(ZROBINCONVERSATIONID, ''),
                       ZLASTUPDATEDTIME
                FROM ZCHATINFOSTOREDMODEL
                ORDER BY ZLASTUPDATEDTIME DESC
                LIMIT 1;
                """) { stmt in
                let chatUUID = SQLiteReader.string(stmt, 0)
                let robinId = SQLiteReader.string(stmt, 1)
                let coreDataTs = SQLiteReader.double(stmt, 2)
                guard !chatUUID.isEmpty, coreDataTs > 0 else { return }
                let updatedAt = Date(timeIntervalSinceReferenceDate: coreDataTs)
                if best == nil || updatedAt > best!.updatedAt {
                    best = RecentDBChat(chatUUID: chatUUID, robinConversationId: robinId, updatedAt: updatedAt)
                }
            }
        }
        return best
    }

    // MARK: - macOS Accessibility Inspection & Exact Conversation Navigation

    private func inspectWindows(pid: pid_t) -> [InspectedWindow] {
        let appElem = AXUIElementCreateApplication(pid)
        var winsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElem, kAXWindowsAttribute as CFString, &winsRef) == .success,
              let windows = winsRef as? [AXUIElement] else {
            return []
        }

        var results: [InspectedWindow] = []
        for win in windows {
            let rawTitle = Self.axString(win, kAXTitleAttribute) ?? ""
            let subrole = Self.axString(win, kAXSubroleAttribute) ?? ""
            if !subrole.isEmpty && subrole != "AXStandardWindow" && subrole != "AXFloatingWindow" && subrole != "AXDialog" {
                continue
            }

            var buttons: [GeminiAXButton] = []
            var statusTexts: [String] = []
            var sidebarTasks: [GeminiSidebarTask] = []
            var hasChatControls = false

            var queue: [(AXUIElement, Int, Bool)] = [(win, 0, false)]
            var visited = 0
            while !queue.isEmpty && visited < 180 {
                let (el, depth, inSidebar) = queue.removeFirst()
                visited += 1

                // Single batched Mach IPC per AX element (5x faster than separate CopyAttributeValue calls)
                var valsRef: CFArray?
                guard AXUIElementCopyMultipleAttributeValues(el, Self.axBatchAttributes, [], &valsRef) == .success,
                      let vals = valsRef as? [AnyObject], vals.count == 5 else {
                    continue
                }
                let role = vals[0] as? String ?? ""
                let ident = vals[1] as? String ?? ""
                let title = vals[2] as? String ?? ""
                let desc = vals[3] as? String ?? ""

                let nowInSidebar = inSidebar
                    || role == "AXOutline"
                    || ident.hasPrefix("sidebar")
                    || desc == "边栏"
                    || desc.lowercased() == "sidebar"

                if ident == "collapse_button" || ident == "newChat_button" || ident == "mic_button" || ident == "sidebar_toggle" || ident == "copy-button" {
                    hasChatControls = true
                }

                if role == "AXButton" {
                    let label = !desc.isEmpty ? desc : title
                    if nowInSidebar, let task = GeminiDesktopClassifier.parseSidebarTaskRow(label) {
                        sidebarTasks.append(task)
                    } else if !nowInSidebar {
                        buttons.append(GeminiAXButton(identifier: ident, title: title, description: desc))
                    }
                    continue // Leaf control — no need to walk button children
                } else if role == "AXStaticText" {
                    if !nowInSidebar {
                        let val = Self.axString(el, kAXValueAttribute) ?? title
                        let trimmed = val.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty && trimmed.count <= 110 {
                            statusTexts.append(trimmed)
                        }
                    }
                    continue
                } else if role == "AXImage" || role == "AXLink" {
                    continue
                }

                // Prune deep chat answer prose scroll views while keeping toolbar, composer & confirmation cards
                if !nowInSidebar && depth >= 7 && (role == "AXScrollArea" || ident == "content") {
                    continue
                }

                if depth < 10, let children = vals[4] as? [AXUIElement] {
                    let slice = (nowInSidebar && children.count > 28) ? Array(children.prefix(28)) : children
                    for child in slice {
                        queue.append((child, depth + 1, nowInSidebar))
                    }
                }
            }

            guard let chatTitle = GeminiDesktopClassifier.extractChatTitle(fromWindowTitle: rawTitle, hasChatControls: hasChatControls) else {
                continue
            }

            let classified = GeminiDesktopClassifier.classifyWindow(buttons: buttons, statusTexts: statusTexts)
            results.append(InspectedWindow(
                title: chatTitle,
                status: classified.status,
                action: classified.action,
                sidebarTasks: sidebarTasks
            ))
        }

        return results
    }

    /// Raises an existing Gemini window showing `title`, or selects the matching row in Gemini's sidebar.
    /// Returns `true` if the conversation was already open or switched via Accessibility.
    static func tryRaiseOrSelectConversation(pid: pid_t, title: String) -> Bool {
        let needle = GeminiDesktopClassifier.normalizedKey(from: title)
        guard !needle.isEmpty, needle != "active-chat", needle != "gemini 桌面对话" else { return false }

        let appElem = AXUIElementCreateApplication(pid)
        var winsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElem, kAXWindowsAttribute as CFString, &winsRef) == .success,
              let windows = winsRef as? [AXUIElement] else {
            return false
        }

        // 1. Raise window directly if any open Gemini window is already showing this chat
        for win in windows {
            let rawTitle = axString(win, kAXTitleAttribute) ?? ""
            if let extracted = GeminiDesktopClassifier.extractChatTitle(fromWindowTitle: rawTitle),
               !extracted.isEmpty,
               GeminiDesktopClassifier.normalizedKey(from: extracted) == needle {
                AXUIElementPerformAction(win, kAXRaiseAction as CFString)
                return true
            }
        }

        // 2. Otherwise find the matching conversation button in the sidebar and click it via kAXPressAction
        for win in windows {
            var queue: [(AXUIElement, Int, Bool)] = [(win, 0, false)]
            var visited = 0
            while !queue.isEmpty && visited < 180 {
                let (el, depth, inSidebar) = queue.removeFirst()
                visited += 1
                var valsRef: CFArray?
                guard AXUIElementCopyMultipleAttributeValues(el, axBatchAttributes, [], &valsRef) == .success,
                      let vals = valsRef as? [AnyObject], vals.count == 5 else {
                    continue
                }
                let role = vals[0] as? String ?? ""
                let ident = vals[1] as? String ?? ""
                let desc = vals[3] as? String ?? ""
                let nowInSidebar = inSidebar || role == "AXOutline" || desc == "边栏" || desc.lowercased() == "sidebar" || ident.hasPrefix("sidebar")

                if nowInSidebar && role == "AXButton" {
                    let candidateTitle: String = {
                        if let task = GeminiDesktopClassifier.parseSidebarTaskRow(desc) {
                            return task.title
                        }
                        return GeminiDesktopClassifier.cleanSidebarTitle(desc)
                    }()
                    if !candidateTitle.isEmpty && GeminiDesktopClassifier.normalizedKey(from: candidateTitle) == needle {
                        AXUIElementPerformAction(win, kAXRaiseAction as CFString)
                        return AXUIElementPerformAction(el, kAXPressAction as CFString) == .success
                    }
                    continue
                }
                if role == "AXButton" || role == "AXStaticText" || role == "AXImage" || role == "AXLink" {
                    continue
                }
                if !nowInSidebar && depth >= 7 && (role == "AXScrollArea" || ident == "content") {
                    continue
                }

                if depth < 10, let children = vals[4] as? [AXUIElement] {
                    let slice = (nowInSidebar && children.count > 28) ? Array(children.prefix(28)) : children
                    for child in slice {
                        queue.append((child, depth + 1, nowInSidebar))
                    }
                }
            }
        }
        return false
    }

    private static func axString(_ el: AXUIElement, _ attr: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &ref) == .success else { return nil }
        return ref as? String
    }
}
