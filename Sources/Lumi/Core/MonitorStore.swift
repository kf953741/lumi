import AppKit
import ApplicationServices
import Foundation
import os
import UserNotifications

@MainActor
final class MonitorStore: ObservableObject {
    @Published private(set) var allSessions: [AgentSession] = []
    @Published var selectedFilter: AgentFilter = .all

    @Published var displayMode: DisplayMode {
        didSet {
            UserDefaults.standard.set(displayMode.rawValue, forKey: "displayMode")
            onDisplayModeChanged?(displayMode)
        }
    }
    @Published var mascotTheme: MascotTheme {
        didSet { UserDefaults.standard.set(mascotTheme.rawValue, forKey: "mascotTheme") }
    }
    @Published var alwaysOnTop: Bool {
        didSet {
            UserDefaults.standard.set(alwaysOnTop, forKey: "alwaysOnTop")
            onWindowLevelChanged?(alwaysOnTop)
        }
    }
    @Published var hoverToExpand: Bool {
        didSet { UserDefaults.standard.set(hoverToExpand, forKey: "hoverToExpand") }
    }
    @Published var soundEnabled: Bool {
        didSet { UserDefaults.standard.set(soundEnabled, forKey: "soundEnabled") }
    }
    @Published var notificationsEnabled: Bool {
        didSet { UserDefaults.standard.set(notificationsEnabled, forKey: "notificationsEnabled") }
    }
    @Published var hideCLISessions: Bool {
        didSet { UserDefaults.standard.set(hideCLISessions, forKey: "hideCLISessions") }
    }
    @Published var selectedSound: String {
        didSet { UserDefaults.standard.set(selectedSound, forKey: "selectedSound") }
    }
    @Published var selectedScreenName: String {
        didSet {
            UserDefaults.standard.set(selectedScreenName, forKey: "selectedScreenName")
            onScreenChanged?()
        }
    }
    @Published var launchAtLogin: Bool {
        didSet { LaunchAgentManager.setEnabled(launchAtLogin) }
    }
    @Published var autoJumpAntigravity: Bool {
        didSet { UserDefaults.standard.set(autoJumpAntigravity, forKey: "autoJumpAntigravity") }
    }
    @Published var accessibilityGranted: Bool = AXIsProcessTrusted()
    @Published var jumpHintMessage: String? = nil

    @Published var lastRefreshAt: Date = Date()
    @Published var hookStatus: [AgentKind: Bool] = [:]

    // Mascot interactive state
    @Published private(set) var celebratingUntil: Date = .distantPast
    @Published private(set) var pokedUntil: Date = .distantPast
    @Published private(set) var dizzyUntil: Date = .distantPast
    private var recentPokeTimestamps: [Date] = []

    static let availableSounds = ["Glass", "Hero", "Ping", "Pop", "Purr", "Submarine", "Funk"]

    var onDisplayModeChanged: ((DisplayMode) -> Void)?
    var onWindowLevelChanged: ((Bool) -> Void)?
    var onScreenChanged: (() -> Void)?
    var onCountsChanged: ((Int, Int, MascotMood) -> Void)?
    var onCompletionMoment: (() -> Void)?

    private let agyScanner = AntigravityScanner()
    private let codexScanner = CodexScanner()
    private let claudeScanner = ClaudeScanner()
    private let extraScanner = ExtraAgentsScanner()
    private let scanQueue = DispatchQueue(label: "cc.bigsmart.lumi.scan", qos: .utility)
    private let jumpLogger = Logger(subsystem: "cc.bigsmart.Lumi", category: "jump")
    private var timer: Timer?
    private var activityToken: NSObjectProtocol?
    private var scanInFlight = false
    private var lastJumpKey: String = ""
    private var lastJumpAt: Date = .distantPast
    private var jumpHintWork: DispatchWorkItem?

    private let statePath: String
    private var ackedAt: [String: TimeInterval] = [:]
    private var previousStatus: [String: SessionStatus] = [:]
    private var liveStartedAt: [String: Date] = [:]
    /// Debounces transient running -> idle blips (e.g. subagent handoffs / queued follow-ups):
    /// a session must stay continuously finished for 4.5s before popping a completion alert.
    private var pendingFinishSince: [String: Date] = [:]
    private var notifiedCompletedAt: [String: TimeInterval] = [:]
    private let completionDebounceSeconds: TimeInterval = 4.5
    private var didInitialScan = false
    private let launchTime = Date()

    init() {
        let d = UserDefaults.standard
        d.register(defaults: [
            "displayMode": DisplayMode.notch.rawValue,
            "mascotTheme": MascotTheme.nebula.rawValue,
            "alwaysOnTop": true,
            "hoverToExpand": true,
            "soundEnabled": true,
            "notificationsEnabled": true,
            "hideCLISessions": true,
            "selectedSound": "Glass",
            "selectedScreenName": "auto",
            "autoJumpAntigravity": true
        ])
        self.displayMode = DisplayMode(rawValue: d.string(forKey: "displayMode") ?? "") ?? .notch
        self.mascotTheme = MascotTheme(rawValue: d.string(forKey: "mascotTheme") ?? "") ?? .nebula
        self.alwaysOnTop = d.bool(forKey: "alwaysOnTop")
        self.hoverToExpand = d.bool(forKey: "hoverToExpand")
        self.soundEnabled = d.bool(forKey: "soundEnabled")
        self.notificationsEnabled = d.bool(forKey: "notificationsEnabled")
        self.hideCLISessions = d.bool(forKey: "hideCLISessions")
        self.selectedSound = d.string(forKey: "selectedSound") ?? "Glass"
        self.selectedScreenName = d.string(forKey: "selectedScreenName") ?? "auto"
        self.launchAtLogin = LaunchAgentManager.isEnabled
        self.autoJumpAntigravity = d.bool(forKey: "autoJumpAntigravity")

        let dir = "\(NSHomeDirectory())/.lumi"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        self.statePath = "\(dir)/read_state.json"
        loadAckState()
        refreshHookStatus()
    }

    func start() {
        HookInstaller.ensureHookScriptInstalled()
        if activityToken == nil {
            // Prevent macOS App Nap from throttling our 1.5s background monitor timer while allowing idle system sleep
            activityToken = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
                reason: "Monitor live AI coding agents"
            )
        }
        refreshNow()
        timer?.invalidate()
        let t = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshNow() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func refreshNow() {
        refreshAccessibilityStatus()
        guard !scanInFlight else { return }
        scanInFlight = true
        let agy = agyScanner
        let codex = codexScanner
        let claude = claudeScanner
        let extra = extraScanner
        scanQueue.async { [weak self] in
            let combined = agy.scan(lookbackHours: 24)
                + codex.scan(lookbackHours: 24)
                + claude.scan(lookbackHours: 24)
                + extra.scan(lookbackHours: 24)
            Task { @MainActor [weak self] in
                self?.scanInFlight = false
                self?.applyScanned(combined)
            }
        }
    }

    func refreshHookStatus() {
        var map: [AgentKind: Bool] = [:]
        for kind in AgentKind.allCases {
            map[kind] = HookInstaller.isInstalled(for: kind)
        }
        hookStatus = map
    }

    func toggleHook(for kind: AgentKind) -> String? {
        do {
            if HookInstaller.isInstalled(for: kind) {
                try HookInstaller.uninstall(for: kind)
            } else {
                try HookInstaller.install(for: kind)
            }
            refreshHookStatus()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: - Derived Collections & Mood

    var filteredSessions: [AgentSession] {
        allSessions.filter { s in
            if hideCLISessions && s.isCLI { return false }
            return selectedFilter.matches(s.kind)
        }
    }

    var runningSessions: [AgentSession] {
        filteredSessions
            .filter { $0.status == .running }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    var unreadCompletedSessions: [AgentSession] {
        filteredSessions
            .filter { !$0.isCLI && ($0.status == .done || $0.status == .error) && $0.isUnread }
            .sorted { ($0.completedAt ?? $0.updatedAt) > ($1.completedAt ?? $1.updatedAt) }
    }

    var recentReadSessions: [AgentSession] {
        filteredSessions
            .filter { !$0.isCLI && $0.status != .running && !$0.isUnread }
            .sorted { ($0.completedAt ?? $0.updatedAt) > ($1.completedAt ?? $1.updatedAt) }
            .prefix(12)
            .map { $0 }
    }

    var totalRunningCount: Int {
        allSessions.filter { !(hideCLISessions && $0.isCLI) && $0.status == .running }.count
    }

    var totalUnreadCount: Int {
        allSessions.filter { !$0.isCLI && ($0.status == .done || $0.status == .error) && $0.isUnread }.count
    }

    var hasUnreadError: Bool {
        allSessions.contains { !$0.isCLI && $0.status == .error && $0.isUnread }
    }

    var mascotMood: MascotMood {
        let now = Date()
        if dizzyUntil > now { return .dizzy }
        if pokedUntil > now { return .poked }
        if celebratingUntil > now { return .celebrating }
        if hasUnreadError { return .error }
        if totalRunningCount > 0 { return .working }
        if totalUnreadCount > 0 { return .waitingUnread }
        return .sleeping
    }

    var mascotStatusText: String {
        switch mascotMood {
        case .dizzy: return "哎呀，转晕啦 @ @"
        case .poked: return "嘿嘿，我在盯盘呢~"
        case .celebrating: return "耶！有对话完成啦！"
        case .error: return "有对话执行出错了"
        case .working: return "\(totalRunningCount) 个对话正在干活"
        case .waitingUnread: return "\(totalUnreadCount) 个对话已完工等你查看"
        case .sleeping: return "全部空闲，摸鱼打盹中…"
        }
    }

    // MARK: - Interactive Actions

    func pokeMascot() {
        let now = Date()
        recentPokeTimestamps = recentPokeTimestamps.filter { now.timeIntervalSince($0) < 2.2 }
        recentPokeTimestamps.append(now)

        if recentPokeTimestamps.count >= 4 {
            dizzyUntil = now.addingTimeInterval(2.8)
            pokedUntil = .distantPast
            recentPokeTimestamps.removeAll()
            if soundEnabled { NSSound(named: NSSound.Name("Pop"))?.play() }
        } else {
            pokedUntil = now.addingTimeInterval(1.6)
            if soundEnabled { NSSound(named: NSSound.Name("Tink"))?.play() }
        }
        notifyCounts()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.9) { [weak self] in
            self?.objectWillChange.send()
            self?.notifyCounts()
        }
    }

    func markRead(_ session: AgentSession) {
        let ts = max((session.completedAt ?? session.updatedAt).timeIntervalSince1970, Date().timeIntervalSince1970)
        ackedAt[session.id] = ts
        saveAckState()
        if let idx = allSessions.firstIndex(where: { $0.id == session.id }) {
            allSessions[idx].isUnread = false
        }
        notifyCounts()
    }

    func markRead(byId id: String) {
        let nowTs = Date().timeIntervalSince1970
        if let idx = allSessions.firstIndex(where: { $0.id == id }) {
            let comp = (allSessions[idx].completedAt ?? allSessions[idx].updatedAt).timeIntervalSince1970
            ackedAt[id] = max(comp, nowTs)
            allSessions[idx].isUnread = false
        } else {
            ackedAt[id] = nowTs
        }
        saveAckState()
        notifyCounts()
    }

    func markAllRead() {
        let nowTs = Date().timeIntervalSince1970
        for i in allSessions.indices where allSessions[i].isUnread {
            let comp = (allSessions[i].completedAt ?? allSessions[i].updatedAt).timeIntervalSince1970
            ackedAt[allSessions[i].id] = max(comp, nowTs)
            allSessions[i].isUnread = false
        }
        saveAckState()
        notifyCounts()
    }

    func refreshAccessibilityStatus() {
        let granted = AXIsProcessTrusted()
        if accessibilityGranted != granted {
            accessibilityGranted = granted
        }
    }

    func requestAccessibilityPermission() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.refreshAccessibilityStatus()
        }
    }

    func openSession(byId id: String) {
        if let session = allSessions.first(where: { $0.id == id }) {
            _ = openSession(session)
        }
    }

    func showJumpHint(_ message: String, duration: TimeInterval = 6.0) {
        jumpHintWork?.cancel()
        jumpHintMessage = message
        let work = DispatchWorkItem { [weak self] in
            self?.jumpHintMessage = nil
        }
        jumpHintWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    func dismissJumpHint() {
        jumpHintWork?.cancel()
        jumpHintMessage = nil
    }

    /// Jumps to the target app and (when supported) the exact conversation.
    /// Returns `true` if a jump/navigation was executed, or `false` if blocked by missing Accessibility permission
    /// while Antigravity is already open (so the caller can keep the panel visible to show the permission hint).
    @discardableResult
    func openSession(_ session: AgentSession) -> Bool {
        let now = Date()
        if lastJumpKey == session.id && now.timeIntervalSince(lastJumpAt) < 0.9 {
            jumpLogger.info("Debounced duplicate jump click for \(session.id, privacy: .public)")
            return true
        }
        lastJumpKey = session.id
        lastJumpAt = now

        switch session.kind {
        case .codex:
            dismissJumpHint()
            NSApp.keyWindow?.resignKey()
            jumpLogger.info("Jumping to Codex thread \(session.rawId, privacy: .public)")
            if !session.rawId.isEmpty,
               let url = URL(string: "codex://threads/\(session.rawId)") {
                NSWorkspace.shared.open(url)
                activateApp(bundleIDs: session.kind.targetBundleIDs)
                return true
            }
            openApp(for: .codex)
            return true

        case .antigravity:
            refreshAccessibilityStatus()
            let trusted = accessibilityGranted
            let queryTitle = Self.cleanSearchQuery(from: session.title)
            let alreadyFront = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.google.antigravity"
            jumpLogger.info("Jumping to Antigravity id=\(session.rawId, privacy: .public) trusted=\(trusted) autoJump=\(self.autoJumpAntigravity) alreadyFront=\(alreadyFront) query=\(queryTitle, privacy: .public)")

            if autoJumpAntigravity && !trusted {
                showJumpHint("未获得辅助功能权限，无法自动切到该对话；请在系统设置中点「-」删掉旧项后重新「+」添加 Lumi")
                if !alreadyFront {
                    activateApp(bundleIDs: session.kind.targetBundleIDs)
                }
                return !alreadyFront
            }

            dismissJumpHint()
            NSApp.keyWindow?.resignKey()
            let shouldAutoLocate = autoJumpAntigravity && trusted && !queryTitle.isEmpty
            activateApp(bundleIDs: session.kind.targetBundleIDs) { [weak self] in
                guard let self, shouldAutoLocate else { return }
                self.waitForFrontmostAndLocate(bundleID: "com.google.antigravity", titleQuery: queryTitle, project: session.project, attempt: 0)
            }
            return true

        default:
            dismissJumpHint()
            NSApp.keyWindow?.resignKey()
            openApp(for: session.kind)
            return true
        }
    }

    func openApp(for kind: AgentKind) {
        activateApp(bundleIDs: kind.targetBundleIDs)
    }

    private func activateApp(bundleIDs: [String], onActivated: (() -> Void)? = nil) {
        for bundleID in bundleIDs {
            if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
                running.activate()
            }
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                let cfg = NSWorkspace.OpenConfiguration()
                cfg.activates = true
                NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, _ in
                    if let onActivated {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14, execute: onActivated)
                    }
                }
                return
            }
        }
        onActivated?()
    }

    private func waitForFrontmostAndLocate(bundleID: String, titleQuery: String, project: String, attempt: Int) {
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if front == bundleID || attempt >= 12 {
            jumpLogger.info("Antigravity focus ready (front=\(front ?? "nil", privacy: .public), attempt=\(attempt)); running Cmd+K locate")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) { [weak self] in
                self?.locateAntigravityConversation(titleQuery: titleQuery, project: project)
            }
            return
        }
        if attempt == 4, let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            running.activate()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.waitForFrontmostAndLocate(bundleID: bundleID, titleQuery: titleQuery, project: project, attempt: attempt + 1)
        }
    }

    /// Locates the exact Antigravity conversation:
    /// 1) Raises an existing Antigravity window if its title matches directly.
    /// 2) Otherwise uses Antigravity's official `Cmd + K` Conversations Palette with the exact title
    ///    (clearing any stale query with `Cmd + A`, pasting via `Cmd + V`, waiting for FTS5 search results,
    ///    pressing `Return`, and cleanly restoring the user's clipboard).
    private func locateAntigravityConversation(titleQuery: String, project: String) {
        // 1. Check if a separate Antigravity window already has this exact conversation open
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.antigravity").first {
            if Self.tryRaiseMatchingAXWindow(pid: app.processIdentifier, query: titleQuery) {
                jumpLogger.info("Raised matching Antigravity AX window directly")
                return
            }
        }

        // 2. Use official Cmd+K (Search Conversations) -> Cmd+A -> paste exact title -> wait FTS5 -> Enter -> restore clipboard
        let pb = NSPasteboard.general
        let savedString = pb.string(forType: .string)

        // Cmd + K (keyCode 40)
        Self.postKey(40, flags: .maskCommand)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) { [weak self] in
            // Cmd + A (keyCode 0) to clear any previous search text
            Self.postKey(0, flags: .maskCommand)

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
                pb.clearContents()
                pb.setString(titleQuery, forType: .string)
                let afterSetChangeCount = pb.changeCount
                // Cmd + V (keyCode 9)
                Self.postKey(9, flags: .maskCommand)

                // Wait for React input debounce + language_server FTS5 query + list re-render
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) { [weak self] in
                    // Return (keyCode 36) to open the #1 exact-title match
                    Self.postKey(36, flags: [])
                    self?.jumpLogger.info("Sent Return in Antigravity Cmd+K palette")

                    // Cleanly restore previous clipboard content if user hasn't copied something else
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        if let savedString, pb.changeCount == afterSetChangeCount {
                            pb.clearContents()
                            pb.setString(savedString, forType: .string)
                        }
                    }
                }
            }
        }
    }

    private nonisolated static func cleanSearchQuery(from rawTitle: String) -> String {
        var s = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("…") || s.hasSuffix(".") {
            s.removeLast()
        }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty || s == "独立对话" || s == "新对话" { return "" }
        // Keep clean prefix up to 48 chars without cutting an English word in half
        if s.count > 48 {
            let cut = String(s.prefix(48))
            if let lastSpace = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: lastSpace) > 20 {
                return String(cut[..<lastSpace])
            }
            return cut
        }
        return s
    }

    private nonisolated static func tryRaiseMatchingAXWindow(pid: pid_t, query: String) -> Bool {
        let appElem = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElem, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement], windows.count > 1 else {
            return false
        }
        let needle = query.lowercased()
        for win in windows {
            var titleRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(win, kAXTitleAttribute as CFString, &titleRef) == .success,
               let title = titleRef as? String,
               title.lowercased().contains(needle) {
                AXUIElementPerformAction(win, kAXRaiseAction as CFString)
                return true
            }
        }
        return false
    }

    private nonisolated static func postKey(_ keyCode: CGKeyCode, flags: CGEventFlags) {
        guard let src = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false) else { return }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cgSessionEventTap)
        usleep(14_000)
        up.post(tap: .cgSessionEventTap)
    }

    func playSound(_ name: String? = nil) {
        NSSound(named: NSSound.Name(name ?? selectedSound))?.play()
    }

    func sendTestNotification() {
        celebratingUntil = Date().addingTimeInterval(3.8)
        if soundEnabled { playSound() }
        onCompletionMoment?()
        postNotification(
            id: "test-\(UUID().uuidString)",
            sessionId: nil,
            deepLink: nil,
            title: "✅ [Lumi] 提醒测试成功",
            subtitle: "独立对话完成时会这样提醒你",
            body: "已完成项会常驻在待查看列表，点完跳过去会自动标为已读。",
            bundleID: AgentKind.antigravity.targetBundleIDs.first ?? ""
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
            self?.objectWillChange.send()
            self?.notifyCounts()
        }
    }

    // MARK: - State Machine

    private func applyScanned(_ scanned: [AgentSession]) {
        let isFirst = !didInitialScan
        didInitialScan = true
        let now = Date()
        var newlyFinished: [AgentSession] = []
        var processed: [AgentSession] = []
        var ackDirty = false

        for raw in scanned {
            var s = raw
            let prev = previousStatus[s.id]

            if s.status == .running {
                // Cancel any pending completion debounce if the conversation resumed!
                pendingFinishSince.removeValue(forKey: s.id)
                if liveStartedAt[s.id] == nil {
                    liveStartedAt[s.id] = s.startedAt ?? now
                }
                let effectiveStart = s.startedAt ?? liveStartedAt[s.id]
                s = AgentSession(
                    id: s.id, rawId: s.rawId, kind: s.kind, title: s.title,
                    project: s.project, cwd: s.cwd, isCLI: s.isCLI, status: s.status,
                    currentAction: s.currentAction, detailSummary: s.detailSummary,
                    startedAt: effectiveStart, updatedAt: s.updatedAt,
                    completedAt: nil, durationSec: nil,
                    activeSubagents: s.activeSubagents, isUnread: false
                )
            } else {
                var dur = s.durationSec
                if dur == nil, let start = liveStartedAt[s.id] {
                    dur = max(1, now.timeIntervalSince(start))
                }

                let compDate = s.completedAt ?? s.updatedAt
                let compTs = compDate.timeIntervalSince1970

                if isFirst && ackedAt[s.id] == nil && now.timeIntervalSince(compDate) > 900 {
                    ackedAt[s.id] = compTs
                    ackDirty = true
                }

                let lastAck = ackedAt[s.id] ?? 0
                let rawIsUnread = !s.isCLI && (s.status == .done || s.status == .error) && (compTs > lastAck + 1.0)
                let alreadyNotified = (notifiedCompletedAt[s.id] ?? 0) >= compTs - 1.0

                // Require a continuous settle window before treating a freshly-stopped running turn as done,
                // preventing premature popups during multi-step handoffs or subagent wakeups.
                var settling = false
                if !isFirst && rawIsUnread && !alreadyNotified {
                    if prev == .running || pendingFinishSince[s.id] != nil || compDate > launchTime {
                        if pendingFinishSince[s.id] == nil {
                            pendingFinishSince[s.id] = now
                        }
                        if let since = pendingFinishSince[s.id], now.timeIntervalSince(since) < completionDebounceSeconds {
                            settling = true
                        }
                    }
                }

                if settling {
                    // Keep showing gently as running ("收尾确认中…") until settle window passes
                    s = AgentSession(
                        id: s.id, rawId: s.rawId, kind: s.kind, title: s.title,
                        project: s.project, cwd: s.cwd, isCLI: s.isCLI, status: .running,
                        currentAction: "收尾确认中…", detailSummary: s.detailSummary,
                        startedAt: s.startedAt ?? liveStartedAt[s.id], updatedAt: s.updatedAt,
                        completedAt: nil, durationSec: nil,
                        activeSubagents: s.activeSubagents, isUnread: false
                    )
                    previousStatus[s.id] = .running
                    processed.append(s)
                    continue
                }

                let confirmedFreshFinish = pendingFinishSince.removeValue(forKey: s.id) != nil
                liveStartedAt.removeValue(forKey: s.id)

                s = AgentSession(
                    id: s.id, rawId: s.rawId, kind: s.kind, title: s.title,
                    project: s.project, cwd: s.cwd, isCLI: s.isCLI, status: s.status,
                    currentAction: s.currentAction, detailSummary: s.detailSummary,
                    startedAt: s.startedAt, updatedAt: s.updatedAt,
                    completedAt: compDate, durationSec: dur,
                    activeSubagents: s.activeSubagents, isUnread: rawIsUnread
                )

                if confirmedFreshFinish && rawIsUnread && !alreadyNotified && !s.isCLI {
                    notifiedCompletedAt[s.id] = compTs
                    newlyFinished.append(s)
                }
            }

            previousStatus[s.id] = s.status
            processed.append(s)
        }

        if ackDirty { saveAckState() }

        let hasRunning = processed.contains { $0.status == .running }
        if processed != allSessions {
            allSessions = processed
            notifyCounts()
        }
        if hasRunning {
            lastRefreshAt = now
        }

        if !newlyFinished.isEmpty {
            celebratingUntil = now.addingTimeInterval(4.5)
            onCompletionMoment?()
            if soundEnabled { playSound() }
            if notificationsEnabled {
                for item in newlyFinished.prefix(3) {
                    let icon = item.status == .error ? "❌" : "✅"
                    let verb = item.status == .error ? "出错" : "已完成"
                    postNotification(
                        id: "\(item.id)-\(Int((item.completedAt ?? now).timeIntervalSince1970))",
                        sessionId: item.id,
                        deepLink: item.kind == .codex ? "codex://threads/\(item.rawId)" : nil,
                        title: "\(icon) [\(item.kind.displayName)] \(item.project) \(verb)",
                        subtitle: item.title,
                        body: "点击直接切换回 \(item.kind.displayName)",
                        bundleID: item.kind.targetBundleIDs.first ?? ""
                    )
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.8) { [weak self] in
                self?.objectWillChange.send()
                self?.notifyCounts()
            }
        }
    }

    private func notifyCounts() {
        onCountsChanged?(totalRunningCount, totalUnreadCount, mascotMood)
    }

    private func postNotification(id: String, sessionId: String?, deepLink: String?, title: String, subtitle: String, body: String, bundleID: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.subtitle = subtitle
        content.body = body
        var info: [String: Any] = ["bundleID": bundleID]
        if let sessionId { info["sessionId"] = sessionId }
        if let deepLink { info["deepLink"] = deepLink }
        content.userInfo = info
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    private func loadAckState() {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: statePath)),
              let dict = try? JSONDecoder().decode([String: TimeInterval].self, from: data) else { return }
        let cutoff = Date().timeIntervalSince1970 - 7 * 86400
        ackedAt = dict.filter { $0.value >= cutoff }
    }

    private func saveAckState() {
        guard let data = try? JSONEncoder().encode(ackedAt) else { return }
        try? data.write(to: URL(fileURLWithPath: statePath), options: .atomic)
    }
}
