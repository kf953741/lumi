import AppKit
import ApplicationServices
import Darwin
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

/// Multi-locale UI string matcher for macOS Gemini Desktop (`com.google.GeminiMacOS`).
/// Merges built-in EN + ZH-Hans baselines with strings dynamically loaded from the user's
/// installed `Gemini.app` `.lproj/App.strings` and `Shared.strings` so Lumi works across all ~70 macOS locales.
struct GeminiLocaleStrings: Sendable {
    let nonChatWindowTitles: Set<String>
    let bareChatTitles: Set<String>
    let titlePrefixes: [String]
    let stopResponseButtons: Set<String>
    let stopTaskButtons: Set<String>
    let strongApproveButtons: Set<String>
    let dismissButtons: Set<String>
    let waitingTexts: Set<String>
    let runningTaskTexts: Set<String>
    let runningResponseTexts: Set<String>
    let sidebarInProgress: [String]
    let sidebarNeedsAttention: [String]
    let sidebarReady: [String]
    let sidebarPinned: [String]

    static let live: GeminiLocaleStrings = loadFromInstalledApp()

    static func baseline() -> GeminiLocaleStrings {
        GeminiLocaleStrings(
            nonChatWindowTitles: [
                "用量限额", "外观", "快捷键", "个性化智能服务", "gemini 的声音", "speak to window",
                "任务", "关于", "扩展程序", "调试", "设置", "账号关联", "发送反馈", "报告问题",
                "登录 gemini", "gemini 新用户引导",
                "settings", "usage limits", "appearance", "shortcuts", "keyboard shortcuts",
                "about", "extensions", "debug", "account linking", "send feedback",
                "report an issue", "gemini sign in", "gemini onboarding"
            ],
            bareChatTitles: ["gemini", "gemini 迷你对话", "gemini mini chat"],
            titlePrefixes: [
                "Gemini 迷你对话 - ", "Gemini 迷你对话 — ", "Gemini 迷你对话 – ",
                "Gemini Mini Chat - ", "Gemini Mini Chat — ", "Gemini Mini Chat – ",
                "Gemini - ", "Gemini — ", "Gemini – "
            ],
            stopResponseButtons: ["停止回答", "stop response", "停止生成", "stop generating"],
            stopTaskButtons: ["停止任务", "stop task"],
            strongApproveButtons: ["允许一次", "allow once", "允许在此对话中使用", "allow for this chat"],
            dismissButtons: ["暂不", "not now", "拒绝", "deny", "取消", "cancel"],
            waitingTexts: [
                "正在等待你输入", "waiting for your input",
                "正在等待输入", "waiting for input",
                "gemini 需要你协助完成此步骤", "gemini needs your help with this step",
                "gemini 需要你在"
            ],
            runningTaskTexts: [
                "正在处理中", "正在处理中…", "working on it", "working on it…",
                "正在初始化任务", "正在初始化任务…", "initializing task", "initializing task…"
            ],
            runningResponseTexts: [
                "正在等待 gemini 回答", "waiting for gemini response",
                "正在生成微件…", "generating widget…"
            ],
            sidebarInProgress: ["进行中", "In progress"],
            sidebarNeedsAttention: ["需要注意", "Needs attention"],
            sidebarReady: ["准备就绪", "Ready"],
            sidebarPinned: ["已固定", "Pinned"]
        )
    }

    static func loadFromInstalledApp(appURL overrideURL: URL? = nil) -> GeminiLocaleStrings {
        let base = baseline()
        let appURL = overrideURL
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: GeminiDesktopScanner.bundleID)
            ?? (FileManager.default.fileExists(atPath: "/Applications/Gemini.app") ? URL(fileURLWithPath: "/Applications/Gemini.app") : nil)
        guard let appURL, let bundle = Bundle(url: appURL) else { return base }

        func loc(_ key: String, table: String = "App") -> String? {
            let sentinel = "__LUMI_MISSING__"
            let val = bundle.localizedString(forKey: key, value: sentinel, table: table)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !val.isEmpty, val != sentinel, val != key else { return nil }
            return val
        }

        var nonChat = base.nonChatWindowTitles
        for k in [
            "SETTINGS_STATE_USAGE_LIMITS", "SETTINGS_STATE_APPEARANCE", "SETTINGS_STATE_EXTENSIONS",
            "SETTINGS_STATE_ABOUT", "SETTINGS_STATE_DEBUG", "OMNICHAT_WINDOW_SETTINGS_TITLE",
            "ACCOUNT_LINKING_WINDOW_TITLE", "FEEDBACK_WINDOW_TITLE", "REPORT_ISSUE_WINDOW_TITLE",
            "LOGIN_WINDOW_TITLE", "ONBOARDING_WINDOW_TITLE"
        ] {
            if let v = loc(k) { nonChat.insert(v.lowercased()) }
        }

        var bare = base.bareChatTitles
        var prefixes = base.titlePrefixes
        if let mini = loc("MINICHAT_WINDOW_TITLE") {
            bare.insert(mini.lowercased())
            for sep in [" - ", " — ", " – "] {
                let p = "\(mini)\(sep)"
                if !prefixes.contains(p) { prefixes.insert(p, at: 0) }
            }
        }

        var stopResp = base.stopResponseButtons
        if let v = loc("CHAT_INPUT_STOP_RESPONSE") { stopResp.insert(v.lowercased()) }
        if let v = loc("IMAGE_EDITOR_INPUT_BOX_STOP_BUTTON", table: "Shared") { stopResp.insert(v.lowercased()) }

        var stopTask = base.stopTaskButtons
        if let v = loc("VIRTUAL_DISPLAY_STOP_TASK") { stopTask.insert(v.lowercased()) }

        var strongApprove = base.strongApproveButtons
        for k in [
            "InlineConfirmationAllowOnceButton", "ComputerUsePermissionAllowOnce",
            "InlineConfirmationAllowForThisChatButton", "ComputerUsePermissionAllowForChat"
        ] {
            if let v = loc(k) { strongApprove.insert(v.lowercased()) }
        }

        var dismiss = base.dismissButtons
        if let v = loc("InlineConfirmationNotNowButton") { dismiss.insert(v.lowercased()) }

        var waiting = base.waitingTexts
        for k in ["PROCESSING_TIMELINE_WAITING_FOR_INPUT", "PROCESSING_TIMELINE_WAITING_FOR_INPUT_INLINE"] {
            if let v = loc(k) { waiting.insert(v.lowercased()) }
        }

        var runTask = base.runningTaskTexts
        for k in ["PROCESSING_TIMELINE_AGENT_WORKING_V2", "PROCESSING_TIMELINE_AGENT_WORKING_BASE_V2", "TASK_LIST_INITIALIZING_TASK"] {
            if let v = loc(k) { runTask.insert(v.lowercased()) }
        }

        var runResp = base.runningResponseTexts
        if let v = loc("STREAM_TO_CURSOR_STATUS_WAITING_FOR_RESPONSE") { runResp.insert(v.lowercased()) }

        func appendUnique(_ arr: [String], _ val: String?) -> [String] {
            guard let val, !arr.contains(where: { $0.caseInsensitiveCompare(val) == .orderedSame }) else { return arr }
            return arr + [val]
        }

        return GeminiLocaleStrings(
            nonChatWindowTitles: nonChat,
            bareChatTitles: bare,
            titlePrefixes: prefixes,
            stopResponseButtons: stopResp,
            stopTaskButtons: stopTask,
            strongApproveButtons: strongApprove,
            dismissButtons: dismiss,
            waitingTexts: waiting,
            runningTaskTexts: runTask,
            runningResponseTexts: runResp,
            sidebarInProgress: appendUnique(base.sidebarInProgress, loc("SIDEBAR_TASK_BADGE_IN_PROGRESS")),
            sidebarNeedsAttention: appendUnique(base.sidebarNeedsAttention, loc("SIDEBAR_TASK_BADGE_NEEDS_ATTENTION")),
            sidebarReady: appendUnique(base.sidebarReady, loc("SIDEBAR_TASK_BADGE_READY")),
            sidebarPinned: appendUnique(base.sidebarPinned, loc("SIDEBAR_PINNED_SECTION_TITLE"))
        )
    }
}

/// Pure, unit-testable classifier for macOS Gemini Desktop (`com.google.GeminiMacOS`)
/// Accessibility windows, sidebar task badges, and `googlegemini://conversation/<id>` deep links.
enum GeminiDesktopClassifier {
    static func extractChatTitle(
        fromWindowTitle raw: String,
        hasChatControls: Bool = false,
        locale: GeminiLocaleStrings = .live
    ) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()

        if locale.nonChatWindowTitles.contains(lower) {
            return nil
        }
        for prefix in locale.titlePrefixes {
            if trimmed.hasPrefix(prefix) {
                return String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        if locale.bareChatTitles.contains(lower) {
            return ""
        }
        if hasChatControls {
            return trimmed
        }
        return nil
    }

    static func parseSidebarTaskRow(_ rawLabel: String, locale: GeminiLocaleStrings = .live) -> GeminiSidebarTask? {
        let s = rawLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }

        let separators = ["，", ", ", "、", " "]
        let groups: [([String], SessionStatus, String)] = [
            (locale.sidebarInProgress, .running, "后台任务进行中…"),
            (locale.sidebarNeedsAttention, .needsInput, "需要你的确认或协助"),
            (locale.sidebarReady, .done, "任务已完成")
        ]

        let lower = s.lowercased()
        for (tokens, status, action) in groups {
            for token in tokens where !token.isEmpty {
                for sep in separators {
                    let suffix = "\(sep)\(token)"
                    if lower.hasSuffix(suffix.lowercased()) {
                        var titlePart = String(s.dropLast(suffix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                        titlePart = cleanSidebarTitle(titlePart, locale: locale)
                        guard !titlePart.isEmpty else { return nil }
                        return GeminiSidebarTask(title: titlePart, status: status, action: action)
                    }
                }
            }
        }
        return nil
    }

    static func cleanSidebarTitle(_ raw: String, locale: GeminiLocaleStrings = .live) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let separators = ["，", ", ", "、"]
        for token in locale.sidebarPinned where !token.isEmpty {
            for sep in separators {
                let ps = "\(sep)\(token)"
                if s.lowercased().hasSuffix(ps.lowercased()) {
                    s = String(s.dropLast(ps.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }
        if (s.hasPrefix("“") && s.hasSuffix("”"))
            || (s.hasPrefix("\"") && s.hasSuffix("\""))
            || (s.hasPrefix("「") && s.hasSuffix("」")) {
            s = String(s.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return s
    }

    static func classifyWindow(
        buttons: [GeminiAXButton],
        statusTexts: [String],
        locale: GeminiLocaleStrings = .live
    ) -> (status: SessionStatus, action: String) {
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
        let hasStrongApprove = lowerLabels.contains { locale.strongApproveButtons.contains($0) }
        let hasGenericAllow = lowerLabels.contains { $0 == "允许" || $0 == "allow" }
        let hasDismissChoice = lowerLabels.contains { locale.dismissButtons.contains($0) }

        let waitingText = shortTexts.first { txt in
            let low = txt.lowercased()
            if locale.waitingTexts.contains(low) { return true }
            return locale.waitingTexts.contains { $0.count >= 10 && low.contains($0) }
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
            if locale.stopResponseButtons.contains(low) {
                return (.running, "生成回答中…")
            }
            if locale.stopTaskButtons.contains(low) {
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
            if locale.runningTaskTexts.contains(low) {
                return (.running, "执行桌面任务中…")
            }
            if locale.runningResponseTexts.contains(low) {
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

    /// Collision-safe normalized key: keeps clean prefix + FNV-1a 32-bit hash suffix for long titles
    /// so two chats sharing the same 48-char prefix never merge into one entry.
    static func normalizedKey(from title: String) -> String {
        let full = ProjectNameHelper.cleanOneLine(title, maxLength: 512).lowercased()
        guard !full.isEmpty else { return "active-chat" }
        if full.count <= 48 {
            return full
        }
        return "\(full.prefix(48))#\(fnv1a32Hex(full))"
    }

    private static func fnv1a32Hex(_ str: String) -> String {
        var hash: UInt32 = 2166136261
        for byte in str.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16777619
        }
        return String(format: "%08x", hash)
    }
}

/// Zero-config live monitor for the native macOS Gemini Desktop app (`com.google.GeminiMacOS`).
final class GeminiDesktopScanner: @unchecked Sendable {
    static let bundleID = "com.google.GeminiMacOS"

    struct InspectedWindow: Equatable, Sendable {
        let title: String
        let status: SessionStatus
        let action: String
        let sidebarTasks: [GeminiSidebarTask]
        let sawSidebar: Bool

        init(title: String, status: SessionStatus, action: String, sidebarTasks: [GeminiSidebarTask], sawSidebar: Bool = false) {
            self.title = title
            self.status = status
            self.action = action
            self.sidebarTasks = sidebarTasks
            self.sawSidebar = sawSidebar
        }
    }

    enum WindowObservation: Equatable, Sendable {
        case ok([InspectedWindow])
        case unavailable
    }

    private enum ChatOrigin {
        case window
        case sidebar
    }

    private struct TrackedChat {
        let key: String
        var title: String
        var status: SessionStatus
        var action: String
        var origin: ChatOrigin
        var isUntitled: Bool
        var startedAt: Date?
        var updatedAt: Date
        var completedAt: Date?
        var durationSec: TimeInterval?
        var conversationId: String?
        var unobservedSince: Date?
    }

    private struct RecentDBChat {
        let chatUUID: String
        let robinConversationId: String
        let updatedAt: Date
    }

    private let cachesRoot: String
    private let runningAppProvider: @Sendable () -> (pid: pid_t, isActive: Bool)?
    private let windowObserver: @Sendable (pid_t) -> WindowObservation
    private let lock = NSLock()
    private var trackedChats: [String: TrackedChat] = [:]
    private var sessionDeepLinks: [String: URL] = [:]
    private var didFirstScan = false
    private var lastAXScanAt: Date = .distantPast
    private var lastDBStamp: String = ""
    private var cachedDBChat: RecentDBChat?
    private var cachedDBAmbiguous: Bool = false

    private static let untitledDisplayTitle = "Gemini 桌面对话"
    private static let untitledKey = GeminiDesktopClassifier.normalizedKey(from: untitledDisplayTitle)

    private static let axBatchAttributes: CFArray = [
        kAXRoleAttribute,
        kAXIdentifierAttribute,
        kAXTitleAttribute,
        kAXDescriptionAttribute,
        kAXChildrenAttribute
    ] as CFArray

    init(
        cachesRoot: String = "\(NSHomeDirectory())/Library/Caches/com.google.GeminiMacOS/Gemini",
        runningAppProvider: (@Sendable () -> (pid: pid_t, isActive: Bool)?)? = nil,
        windowObserver: (@Sendable (pid_t) -> WindowObservation)? = nil
    ) {
        self.cachesRoot = cachesRoot
        self.runningAppProvider = runningAppProvider ?? {
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).first else {
                return nil
            }
            return (app.processIdentifier, app.isActive)
        }
        self.windowObserver = windowObserver ?? { pid in
            guard AXIsProcessTrusted() else { return .unavailable }
            return Self.inspectWindowsLive(pid: pid)
        }
    }

    func deepLinkURL(forSessionId sessionId: String) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        return sessionDeepLinks[sessionId]
    }

    func scan(lookbackHours: Double = 24, now: Date = Date()) -> [AgentSession] {
        let cutoff = now.addingTimeInterval(-lookbackHours * 3600)
        guard let runningApp = runningAppProvider() else {
            return snapshotWhenClosed(cutoff: cutoff, now: now)
        }

        let dbStamp = computeDBStamp()
        lock.lock()
        let dbChanged = (dbStamp != lastDBStamp)
        let hasTrackedActive = trackedChats.values.contains { $0.status == .running || $0.status == .needsInput }
        let axAge = now.timeIntervalSince(lastAXScanAt)
        let cachedDB = cachedDBChat
        let cachedAmbig = cachedDBAmbiguous
        let wasFirstScanDone = didFirstScan
        lock.unlock()

        let recentDB: RecentDBChat?
        let dbAmbiguous: Bool
        if dbChanged || !wasFirstScanDone {
            let read = readMostRecentDBChat()
            if read.ok {
                lock.lock()
                lastDBStamp = dbStamp
                cachedDBChat = read.chat
                cachedDBAmbiguous = read.ambiguous
                lock.unlock()
                recentDB = read.chat
                dbAmbiguous = read.ambiguous
            } else {
                // Do not commit fingerprint on transient SQLite lock/failure
                recentDB = cachedDB
                dbAmbiguous = cachedAmbig
            }
        } else {
            recentDB = cachedDB
            dbAmbiguous = cachedAmbig
        }

        // Adaptive AX polling: scan immediately when active, frontmost, or DB changed;
        // throttle background idle polling to every 6s to keep CPU & Mach IPC near 0%.
        let shouldRunAX = !wasFirstScanDone || hasTrackedActive || dbChanged || runningApp.isActive || axAge >= 6.0
        guard shouldRunAX else {
            lock.lock()
            defer { lock.unlock() }
            return buildSessionsLocked()
        }

        let observation = windowObserver(runningApp.pid)

        lock.lock()
        defer { lock.unlock() }

        didFirstScan = true
        lastAXScanAt = now

        // CRITICAL: If Accessibility permission was revoked or AX IPC failed transiently,
        // NEVER fabricate `.done` completions for tracked active chats.
        guard case .ok(let windows) = observation else {
            return buildSessionsLocked()
        }

        // Adopt untitled new-chat rename (`"Gemini"` -> generated title) before diffing,
        // preventing phantom `"Gemini 桌面对话 已完成"` alerts when Gemini names a fresh conversation!
        let hasUntitledWindowNow = windows.contains { $0.title.isEmpty }
        if !hasUntitledWindowNow,
           let untitled = trackedChats[Self.untitledKey],
           (untitled.status == .running || untitled.status == .needsInput),
           now.timeIntervalSince(untitled.updatedAt) < 120 {
            let novelNamedWindows = windows.filter { win in
                guard !win.title.isEmpty else { return false }
                let k = GeminiDesktopClassifier.normalizedKey(from: win.title)
                return trackedChats[k] == nil
            }
            if let adoptedWin = novelNamedWindows.first(where: { $0.status == .running || $0.status == .needsInput })
                ?? (novelNamedWindows.count == 1 ? novelNamedWindows.first : nil) {
                let newKey = GeminiDesktopClassifier.normalizedKey(from: adoptedWin.title)
                trackedChats.removeValue(forKey: Self.untitledKey)
                trackedChats[newKey] = TrackedChat(
                    key: newKey,
                    title: adoptedWin.title,
                    status: untitled.status,
                    action: untitled.action,
                    origin: .window,
                    isUntitled: false,
                    startedAt: untitled.startedAt,
                    updatedAt: untitled.updatedAt,
                    completedAt: nil,
                    durationSec: nil,
                    conversationId: untitled.conversationId,
                    unobservedSince: nil
                )
            }
        }

        var seenActiveKeys = Set<String>()
        var seenWindowKeys = Set<String>()
        var sidebarTasks: [GeminiSidebarTask] = []

        let activeOrTransitioningWindowCount = windows.reduce(0) { acc, win in
            let title = win.title.isEmpty ? Self.untitledDisplayTitle : win.title
            let key = GeminiDesktopClassifier.normalizedKey(from: title)
            let isActive = (win.status == .running || win.status == .needsInput)
            let wasActive = trackedChats[key].map { $0.status == .running || $0.status == .needsInput } ?? false
            return acc + ((isActive || wasActive) ? 1 : 0)
        }

        let singleUnambiguousConvId: String? = {
            guard !dbAmbiguous, activeOrTransitioningWindowCount == 1,
                  let db = recentDB, abs(now.timeIntervalSince(db.updatedAt)) <= 90 else {
                return nil
            }
            let cid = db.robinConversationId.isEmpty ? db.chatUUID : db.robinConversationId
            return cid.isEmpty ? nil : cid
        }()

        // 1. Process all open Gemini Desktop chat windows
        for win in windows {
            sidebarTasks.append(contentsOf: win.sidebarTasks)
            let isUntitled = win.title.isEmpty
            let displayTitle = isUntitled ? Self.untitledDisplayTitle : win.title
            let key = GeminiDesktopClassifier.normalizedKey(from: displayTitle)
            seenWindowKeys.insert(key)

            let isActive = (win.status == .running || win.status == .needsInput)
            if isActive { seenActiveKeys.insert(key) }

            let canBindConvId: String? = {
                guard let cid = singleUnambiguousConvId else { return nil }
                // Never steal a conversationId already bound to a different chat
                let alreadyOwnedByOther = trackedChats.values.contains { $0.key != key && $0.conversationId == cid }
                return alreadyOwnedByOther ? nil : cid
            }()

            if var existing = trackedChats[key] {
                existing.title = displayTitle
                existing.origin = .window
                existing.isUntitled = isUntitled
                existing.unobservedSince = nil
                if isActive {
                    if let cid = canBindConvId { existing.conversationId = cid }
                    if existing.status != .running && existing.status != .needsInput {
                        existing.startedAt = now
                    }
                    existing.status = win.status
                    existing.action = win.action
                    existing.updatedAt = now
                    existing.completedAt = nil
                    existing.durationSec = nil
                } else if existing.status == .running || existing.status == .needsInput {
                    if let cid = canBindConvId, existing.conversationId == nil {
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
                // Never synthesize a `.done` entry when the user merely views an already-idle historical chat.
                trackedChats[key] = TrackedChat(
                    key: key,
                    title: displayTitle,
                    status: win.status,
                    action: win.action,
                    origin: .window,
                    isUntitled: isUntitled,
                    startedAt: now,
                    updatedAt: now,
                    completedAt: nil,
                    durationSec: nil,
                    conversationId: canBindConvId,
                    unobservedSince: nil
                )
            }
        }

        // 2. Process background sidebar tasks (and let stronger sidebar active/needsInput badges
        //    override an idle `.done` open window for the same chat!)
        var seenSidebarKeys = Set<String>()
        for task in sidebarTasks {
            let key = GeminiDesktopClassifier.normalizedKey(from: task.title)
            guard !seenSidebarKeys.contains(key) else { continue }
            seenSidebarKeys.insert(key)

            let isActive = (task.status == .running || task.status == .needsInput)
            if seenWindowKeys.contains(key) {
                if isActive {
                    seenActiveKeys.insert(key)
                    if var existing = trackedChats[key], existing.status == .done || (existing.status == .running && task.status == .needsInput) {
                        if existing.status == .done { existing.startedAt = now }
                        existing.status = task.status
                        existing.action = task.action
                        existing.updatedAt = now
                        existing.completedAt = nil
                        existing.durationSec = nil
                        trackedChats[key] = existing
                    } else if trackedChats[key] == nil {
                        trackedChats[key] = TrackedChat(
                            key: key, title: task.title, status: task.status, action: task.action,
                            origin: .window, isUntitled: false, startedAt: now, updatedAt: now,
                            completedAt: nil, durationSec: nil, conversationId: nil, unobservedSince: nil
                        )
                    }
                }
                continue
            }

            if isActive { seenActiveKeys.insert(key) }

            if var existing = trackedChats[key] {
                existing.title = task.title
                existing.origin = .sidebar
                existing.unobservedSince = nil
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
                    origin: .sidebar,
                    isUntitled: false,
                    startedAt: now,
                    updatedAt: now,
                    completedAt: nil,
                    durationSec: nil,
                    conversationId: nil,
                    unobservedSince: nil
                )
            } else if task.status == .done {
                // Historical `Ready` badge newly revealed by scrolling/expanding sidebar:
                // record as historical (read), NEVER stamp `now` as a fake fresh completion!
                let ts = now.addingTimeInterval(-1200)
                trackedChats[key] = TrackedChat(
                    key: key,
                    title: task.title,
                    status: .done,
                    action: task.action,
                    origin: .sidebar,
                    isUntitled: false,
                    startedAt: nil,
                    updatedAt: ts,
                    completedAt: ts,
                    durationSec: nil,
                    conversationId: nil,
                    unobservedSince: nil
                )
            }
        }

        // 3. Handle previously active chats no longer observed in open windows or sidebar tasks.
        //    Require an explicit observed terminal state (open window going idle or sidebar `Ready` badge)
        //    before alerting completion — never promote a scrolled-out/closed/unobserved chat to `.done`!
        for (key, var chat) in trackedChats where (chat.status == .running || chat.status == .needsInput) && !seenActiveKeys.contains(key) {
            if chat.isUntitled {
                trackedChats.removeValue(forKey: key)
                continue
            }
            let firstMissing = chat.unobservedSince ?? now
            chat.unobservedSince = firstMissing
            if now.timeIntervalSince(firstMissing) >= 12.0 {
                trackedChats.removeValue(forKey: key)
            } else {
                trackedChats[key] = chat
            }
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
        // App quit while chats were active -> never fabricate fake `.done` completion alerts!
        for (key, chat) in trackedChats where chat.status == .running || chat.status == .needsInput {
            trackedChats.removeValue(forKey: key)
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
                    parts.append("\(entry)/\(suffix):\(st.st_ino):\(st.st_size):\(st.st_mtimespec.tv_sec).\(st.st_mtimespec.tv_nsec)")
                }
            }
        }
        return parts.joined(separator: "|")
    }

    private func readMostRecentDBChat() -> (chat: RecentDBChat?, ambiguous: Bool, ok: Bool) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: cachesRoot) else {
            return (nil, false, true)
        }
        var best: RecentDBChat?
        var recentAccountsCount = 0
        var allOk = true
        let now = Date()

        for entry in entries where entry.hasPrefix("user") {
            let dbPath = "\(cachesRoot)/\(entry)/ChatInfo2.store"
            guard fm.fileExists(atPath: dbPath) else { continue }
            guard let reader = SQLiteReader(path: dbPath) else {
                allOk = false
                continue
            }

            var accountLatest: RecentDBChat?
            let queryOk = reader.query("""
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
                accountLatest = RecentDBChat(chatUUID: chatUUID, robinConversationId: robinId, updatedAt: updatedAt)
            }
            if !queryOk {
                allOk = false
                continue
            }
            if let latest = accountLatest {
                if abs(now.timeIntervalSince(latest.updatedAt)) <= 90 {
                    recentAccountsCount += 1
                }
                if best == nil || latest.updatedAt > best!.updatedAt {
                    best = latest
                }
            }
        }
        return (best, recentAccountsCount > 1, allOk)
    }

    // MARK: - macOS Accessibility Inspection & Exact Conversation Navigation

    private static func inspectWindowsLive(pid: pid_t) -> WindowObservation {
        let appElem = AXUIElementCreateApplication(pid)
        var winsRef: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(appElem, kAXWindowsAttribute as CFString, &winsRef)
        guard err == .success, let windows = winsRef as? [AXUIElement] else {
            return .unavailable
        }

        var results: [InspectedWindow] = []
        for win in windows {
            let rawTitle = axString(win, kAXTitleAttribute) ?? ""
            let subrole = axString(win, kAXSubroleAttribute) ?? ""
            if !subrole.isEmpty && subrole != "AXStandardWindow" && subrole != "AXFloatingWindow" && subrole != "AXDialog" {
                continue
            }

            var buttons: [GeminiAXButton] = []
            var statusTexts: [String] = []
            var sidebarTasks: [GeminiSidebarTask] = []
            var hasChatControls = false
            var sawSidebar = false

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
                let title = vals[2] as? String ?? ""
                let desc = vals[3] as? String ?? ""

                let nowInSidebar = inSidebar
                    || role == "AXOutline"
                    || ident.hasPrefix("sidebar")
                    || desc == "边栏"
                    || desc.lowercased() == "sidebar"
                if nowInSidebar { sawSidebar = true }

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
                    continue
                } else if role == "AXStaticText" {
                    if !nowInSidebar {
                        let val = axString(el, kAXValueAttribute) ?? title
                        let trimmed = val.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty && trimmed.count <= 110 {
                            statusTexts.append(trimmed)
                        }
                    }
                    continue
                } else if role == "AXImage" || role == "AXLink" {
                    continue
                }

                if !nowInSidebar && depth >= 7 && (role == "AXScrollArea" || ident == "content") {
                    continue
                }

                if depth < 10, let children = vals[4] as? [AXUIElement] {
                    let slice = (nowInSidebar && children.count > 60) ? Array(children.prefix(60)) : children
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
                sidebarTasks: sidebarTasks,
                sawSidebar: sawSidebar
            ))
        }

        return .ok(results)
    }

    static func tryRaiseOrSelectConversation(pid: pid_t, title: String) -> Bool {
        let needle = GeminiDesktopClassifier.normalizedKey(from: title)
        guard !needle.isEmpty, needle != "active-chat", needle != untitledKey else { return false }

        let appElem = AXUIElementCreateApplication(pid)
        var winsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElem, kAXWindowsAttribute as CFString, &winsRef) == .success,
              let windows = winsRef as? [AXUIElement] else {
            return false
        }

        // 1. Raise window directly if a UNIQUE open Gemini window matches this chat
        let matchingWindows = windows.filter { win in
            let rawTitle = axString(win, kAXTitleAttribute) ?? ""
            if let extracted = GeminiDesktopClassifier.extractChatTitle(fromWindowTitle: rawTitle),
               !extracted.isEmpty,
               GeminiDesktopClassifier.normalizedKey(from: extracted) == needle {
                return true
            }
            return false
        }
        if matchingWindows.count == 1, let win = matchingWindows.first {
            if AXUIElementPerformAction(win, kAXRaiseAction as CFString) == .success {
                return true
            }
        }

        // 2. Otherwise find a UNIQUE matching conversation button in the sidebar and click it via kAXPressAction
        var matchingSidebarButtons: [(AXUIElement, AXUIElement)] = []
        for win in windows {
            var queue: [(AXUIElement, Int, Bool)] = [(win, 0, false)]
            var visited = 0
            while !queue.isEmpty && visited < 220 {
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
                        matchingSidebarButtons.append((win, el))
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
                    let slice = (nowInSidebar && children.count > 60) ? Array(children.prefix(60)) : children
                    for child in slice {
                        queue.append((child, depth + 1, nowInSidebar))
                    }
                }
            }
        }
        if matchingSidebarButtons.count == 1, let (win, el) = matchingSidebarButtons.first {
            _ = AXUIElementPerformAction(win, kAXRaiseAction as CFString)
            return AXUIElementPerformAction(el, kAXPressAction as CFString) == .success
        }
        return false
    }

    private static func axString(_ el: AXUIElement, _ attr: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &ref) == .success else { return nil }
        return ref as? String
    }
}
