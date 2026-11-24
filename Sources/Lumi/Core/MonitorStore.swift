import AppKit
import ApplicationServices
import Foundation
import os
import UserNotifications

@MainActor
final class MonitorStore: ObservableObject {
    @Published private(set) var allSessions: [AgentSession] = []
    @Published var selectedFilter: AgentFilter = .all {
        didSet { recomputeDerived() }
    }
    @Published var activeBoardTab: BentoListTab = .all
    @Published var showRecentSessions: Bool = false

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
        didSet {
            UserDefaults.standard.set(hideCLISessions, forKey: "hideCLISessions")
            recomputeDerived()
            notifyCounts()
        }
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
    private var isRevertingLaunchAtLogin = false
    @Published var launchAtLogin: Bool {
        didSet {
            guard !isRevertingLaunchAtLogin else { return }
            if !LaunchAgentManager.setEnabled(launchAtLogin) {
                isRevertingLaunchAtLogin = true
                launchAtLogin = oldValue
                isRevertingLaunchAtLogin = false
            }
        }
    }
    @Published var autoJumpAntigravity: Bool {
        didSet { UserDefaults.standard.set(autoJumpAntigravity, forKey: "autoJumpAntigravity") }
    }
    @Published var appLanguage: AppLanguage {
        didSet {
            UserDefaults.standard.set(appLanguage.rawValue, forKey: "appLanguage")
            onLanguageChanged?()
            notifyCounts()
        }
    }
    @Published var floatingAppearance: FloatingAppearance {
        didSet { UserDefaults.standard.set(floatingAppearance.rawValue, forKey: "floatingAppearance") }
    }
    @Published var hideAutoPeekInFullscreen: Bool {
        didSet { UserDefaults.standard.set(hideAutoPeekInFullscreen, forKey: "hideAutoPeekInFullscreen") }
    }
    private var isRevertingHotKey = false
    @Published var hotKeyPreset: GlobalHotKeyPreset {
        didSet {
            guard !isRevertingHotKey else { return }
            if let handler = onHotKeyPresetChanged {
                if handler(hotKeyPreset) {
                    hotKeyErrorMessage = nil
                    UserDefaults.standard.set(hotKeyPreset.rawValue, forKey: "hotKeyPreset")
                } else {
                    let failedLabel = hotKeyPreset.label(isEnglish: isEnglish)
                    hotKeyErrorMessage = l10n.hotKeyConflictMessage(failedLabel)
                    isRevertingHotKey = true
                    hotKeyPreset = oldValue
                    isRevertingHotKey = false
                }
            } else {
                UserDefaults.standard.set(hotKeyPreset.rawValue, forKey: "hotKeyPreset")
            }
        }
    }
    @Published var hotKeyErrorMessage: String? = nil
    @Published var dndUntil: Date? {
        didSet {
            if let d = dndUntil {
                UserDefaults.standard.set(d.timeIntervalSince1970, forKey: "dndUntil")
            } else {
                UserDefaults.standard.removeObject(forKey: "dndUntil")
            }
            scheduleDNDTimer()
            notifyCounts()
        }
    }
    @Published var accessibilityGranted: Bool = AXIsProcessTrusted()
    @Published var jumpHintMessage: String? = nil

    var isEnglish: Bool { appLanguage.resolvedIsEnglish }
    var l10n: L10n { L10n(isEnglish: isEnglish) }

    var isDNDActive: Bool {
        guard let until = dndUntil else { return false }
        return until > Date()
    }

    var dndRemainingText: String? {
        guard let until = dndUntil else { return nil }
        let rem = until.timeIntervalSinceNow
        guard rem > 5 else { return nil }
        let mins = max(1, Int(ceil(rem / 60.0)))
        return isEnglish ? "\(mins)m" : "\(mins) 分钟"
    }

    func enableDND(minutes: Int) {
        dndUntil = Date().addingTimeInterval(TimeInterval(minutes * 60))
    }

    func disableDND() {
        dndUntil = nil
    }

    @Published var hookStatus: [AgentKind: Bool] = [:]

    // Precomputed derived collections (recomputed only when allSessions / filter / hideCLISessions change)
    private(set) var filteredSessions: [AgentSession] = []
    private(set) var needsInputSessions: [AgentSession] = []
    private(set) var runningSessions: [AgentSession] = []
    private(set) var unreadCompletedSessions: [AgentSession] = []
    private(set) var recentReadSessions: [AgentSession] = []
    private(set) var totalNeedsInputCount: Int = 0
    private(set) var totalRunningCount: Int = 0
    private(set) var totalUnreadCount: Int = 0
    private(set) var hasUnreadError: Bool = false
    private(set) var collapsedActiveKinds: [AgentKind] = []
    private(set) var singleRunningSession: AgentSession? = nil

    // Mascot interactive state
    @Published private(set) var celebratingUntil: Date = .distantPast
    @Published private(set) var pokedUntil: Date = .distantPast
    @Published private(set) var dizzyUntil: Date = .distantPast
    private var recentPokeTimestamps: [Date] = []

    static let availableSounds = ["Glass", "Hero", "Ping", "Pop", "Purr", "Submarine", "Funk"]

    var onDisplayModeChanged: ((DisplayMode) -> Void)?
    var onWindowLevelChanged: ((Bool) -> Void)?
    var onScreenChanged: (() -> Void)?
    var onLanguageChanged: (() -> Void)?
    var onHotKeyPresetChanged: ((GlobalHotKeyPreset) -> Bool)?
    var onCountsChanged: ((Int, Int, Int, MascotMood) -> Void)?
    var onCompletionMoment: (() -> Void)?

    private let agyScanner = AntigravityScanner()
    private let codexScanner = CodexScanner()
    private let claudeScanner = ClaudeScanner()
    private let t3Scanner = T3CodeScanner()
    private let geminiDesktopScanner = GeminiDesktopScanner()
    private let extraScanner = ExtraAgentsScanner()
    private let scanQueue = DispatchQueue(label: "cc.bigsmart.lumi.scan", qos: .utility)
    private let jumpLogger = Logger(subsystem: "cc.bigsmart.Lumi", category: "jump")
    private var timer: Timer?
    private var dndTimer: Timer?
    private var moodResetWork: DispatchWorkItem?
    private var activityToken: NSObjectProtocol?
    private var scanInFlight = false
    private var pendingRefreshRequested = false
    private var lastJumpKey: String = ""
    private var lastJumpAt: Date = .distantPast
    private var jumpHintWork: DispatchWorkItem?
    private var antigravityJumpToken: UInt64 = 0
    private var pendingJumpWorkItems: [DispatchWorkItem] = []

    private struct PendingClipboardRestore {
        let snapshot: [[NSPasteboard.PasteboardType: Data]]
        let expectedChangeCount: Int
    }
    private var pendingClipboardRestore: PendingClipboardRestore?

    private struct PendingFinish {
        let completedAt: TimeInterval
        let since: Date
        var waitingForCleanRead: Bool = false
    }

    private let statePath: String
    private var ackedAt: [String: TimeInterval] = [:]
    private var previousStatus: [String: SessionStatus] = [:]
    private var liveStartedAt: [String: Date] = [:]
    /// Debounces transient running -> idle blips (e.g. subagent handoffs / queued follow-ups):
    /// a session must stay continuously finished for 4.5s before popping a completion alert.
    private var pendingFinishSince: [String: PendingFinish] = [:]
    private var notifiedCompletedAt: [String: TimeInterval] = [:]
    private var notifiedNeedsInputKey: [String: String] = [:]
    private var lastAlertSoundAt: Date = .distantPast
    private var lastPruneAt: Date = Date()
    private let completionDebounceSeconds: TimeInterval = 4.5
    private var didInitialScan = false
    private let launchTime: Date
    private let suppressSystemSideEffects: Bool
    /// Observable in tests to assert exact completion notification deliveries (distinct from unread list counts).
    internal private(set) var confirmedCompletionIds: [String] = []

    init(statePath overrideStatePath: String? = nil, launchTime: Date = Date(), suppressSystemSideEffects: Bool = false) {
        self.launchTime = launchTime
        self.suppressSystemSideEffects = suppressSystemSideEffects
        let d = UserDefaults.standard
        d.register(defaults: [
            "displayMode": DisplayMode.notch.rawValue,
            "mascotTheme": MascotTheme.ember.rawValue,
            "alwaysOnTop": true,
            "hoverToExpand": true,
            "soundEnabled": true,
            "notificationsEnabled": true,
            "hideCLISessions": true,
            "selectedSound": "Glass",
            "selectedScreenName": "auto",
            "autoJumpAntigravity": true,
            "appLanguage": AppLanguage.system.rawValue,
            "floatingAppearance": FloatingAppearance.charcoal.rawValue,
            "hideAutoPeekInFullscreen": true,
            "hotKeyPreset": GlobalHotKeyPreset.optionL.rawValue
        ])
        // One-time upgrade migration to the new signature warm tangerine Lumi Ember theme
        if d.integer(forKey: "mascotArtVersion") < 2 {
            d.set(2, forKey: "mascotArtVersion")
            d.set(MascotTheme.ember.rawValue, forKey: "mascotTheme")
        }
        self.displayMode = DisplayMode(rawValue: d.string(forKey: "displayMode") ?? "") ?? .notch
        self.mascotTheme = MascotTheme(rawValue: d.string(forKey: "mascotTheme") ?? "") ?? .ember
        self.alwaysOnTop = d.bool(forKey: "alwaysOnTop")
        self.hoverToExpand = d.bool(forKey: "hoverToExpand")
        self.soundEnabled = d.bool(forKey: "soundEnabled")
        self.notificationsEnabled = d.bool(forKey: "notificationsEnabled")
        self.hideCLISessions = d.bool(forKey: "hideCLISessions")
        self.selectedSound = d.string(forKey: "selectedSound") ?? "Glass"
        self.selectedScreenName = d.string(forKey: "selectedScreenName") ?? "auto"
        self.launchAtLogin = LaunchAgentManager.isEnabled
        self.autoJumpAntigravity = d.bool(forKey: "autoJumpAntigravity")
        self.appLanguage = AppLanguage(rawValue: d.string(forKey: "appLanguage") ?? "") ?? .system
        self.floatingAppearance = FloatingAppearance(rawValue: d.string(forKey: "floatingAppearance") ?? "") ?? .charcoal
        self.hideAutoPeekInFullscreen = d.bool(forKey: "hideAutoPeekInFullscreen")
        self.hotKeyPreset = GlobalHotKeyPreset(rawValue: d.string(forKey: "hotKeyPreset") ?? "") ?? .optionL
        let savedDnd = d.double(forKey: "dndUntil")
        self.dndUntil = savedDnd > Date().timeIntervalSince1970 ? Date(timeIntervalSince1970: savedDnd) : nil

        let dir = "\(NSHomeDirectory())/.lumi"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        self.statePath = overrideStatePath ?? "\(dir)/read_state.json"
        loadAckState()
        refreshHookStatus()
        recomputeDerived()
        scheduleDNDTimer()
    }

    private func scheduleDNDTimer() {
        dndTimer?.invalidate()
        dndTimer = nil
        guard !suppressSystemSideEffects, let until = dndUntil else { return }
        let rem = until.timeIntervalSinceNow
        if rem <= 0 {
            dndUntil = nil
            return
        }
        // Tick every 30s (or at exact expiry if sooner) so menu bar tooltip countdown stays live even when idle
        let interval = min(30.0, max(0.5, rem + 0.1))
        let t = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let u = self.dndUntil, u <= Date() {
                    self.dndUntil = nil
                } else {
                    self.notifyCounts()
                    self.scheduleDNDTimer()
                }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        dndTimer = t
    }

    private func scheduleMoodReset(until deadline: Date) {
        moodResetWork?.cancel()
        let delay = max(0.05, deadline.timeIntervalSinceNow + 0.08)
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.objectWillChange.send()
            self.notifyCounts()
            // If another transient mood deadline is still active, reschedule for it
            let nextDeadline = [self.dizzyUntil, self.pokedUntil, self.celebratingUntil]
                .filter { $0 > Date() }
                .min()
            if let nextDeadline {
                self.scheduleMoodReset(until: nextDeadline)
            }
        }
        moodResetWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
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
        if scanInFlight {
            pendingRefreshRequested = true
            return
        }
        scanInFlight = true
        let agy = agyScanner
        let codex = codexScanner
        let claude = claudeScanner
        let t3 = t3Scanner
        let geminiDesktop = geminiDesktopScanner
        let extra = extraScanner
        let hasSettlingT3 = pendingFinishSince.keys.contains { $0.hasPrefix("t3code:") }
        scanQueue.async { [weak self] in
            let now = Date()
            let hooksByAgent = LiveHookRecord.loadAllGrouped()
            let t3Result = t3.scanDetailed(lookbackHours: 24, now: now, forceFresh: hasSettlingT3)
            let underlying = agy.scan(lookbackHours: 24, preloadedHooks: hooksByAgent["antigravity"] ?? [:])
                + codex.scan(lookbackHours: 24, now: now, preloadedHooks: hooksByAgent["codex"] ?? [:])
                + claude.scan(lookbackHours: 24, now: now, preloadedHooks: hooksByAgent["claude"] ?? [:])
                + extra.scan(lookbackHours: 24, preloadedHooksByAgent: hooksByAgent)
            let dedupedUnderlying = underlying.filter { !t3Result.ownsUnderlying($0, now: now) }
            let combined = dedupedUnderlying + t3Result.sessions + geminiDesktop.scan(lookbackHours: 24, now: now)
            let deferKinds: Set<AgentKind> = t3Result.deferAllCompletions ? [.t3code] : []
            let deferSessionIds = t3Result.deferredSessionIds
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.scanInFlight = false
                self.applyScanned(
                    combined,
                    now: now,
                    deferConfirmKinds: deferKinds,
                    deferConfirmSessionIds: deferSessionIds
                )
                if self.pendingRefreshRequested {
                    self.pendingRefreshRequested = false
                    self.refreshNow()
                }
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

    private func recomputeDerived() {
        let visibleAll = allSessions.filter { !(hideCLISessions && $0.isCLI) }
        let filtered = visibleAll.filter { selectedFilter.matches($0.kind) }

        filteredSessions = filtered
        needsInputSessions = filtered
            .filter { $0.status == .needsInput }
            .sorted { $0.updatedAt > $1.updatedAt }
        runningSessions = filtered
            .filter { $0.status == .running }
            .sorted { $0.updatedAt > $1.updatedAt }
        unreadCompletedSessions = filtered
            .filter { !$0.isCLI && ($0.status == .done || $0.status == .error) && $0.isUnread }
            .sorted { ($0.completedAt ?? $0.updatedAt) > ($1.completedAt ?? $1.updatedAt) }
        recentReadSessions = Array(
            filtered
                .filter { !$0.isCLI && $0.status != .running && $0.status != .needsInput && !$0.isUnread }
                .sorted { ($0.completedAt ?? $0.updatedAt) > ($1.completedAt ?? $1.updatedAt) }
                .prefix(12)
        )

        let allNeedsInput = visibleAll.filter { $0.status == .needsInput }
        let allRunning = visibleAll.filter { $0.status == .running }
        let allUnread = allSessions.filter { !$0.isCLI && ($0.status == .done || $0.status == .error) && $0.isUnread }

        totalNeedsInputCount = allNeedsInput.count
        totalRunningCount = allRunning.count
        totalUnreadCount = allUnread.count
        hasUnreadError = allUnread.contains { $0.status == .error }

        var ordered: [AgentKind] = []
        for s in allNeedsInput.sorted(by: { $0.updatedAt > $1.updatedAt }) {
            if !ordered.contains(s.kind) { ordered.append(s.kind) }
        }
        for s in allRunning.sorted(by: { $0.updatedAt > $1.updatedAt }) {
            if !ordered.contains(s.kind) { ordered.append(s.kind) }
        }
        for s in allUnread.sorted(by: { ($0.completedAt ?? $0.updatedAt) > ($1.completedAt ?? $1.updatedAt) }) {
            if !ordered.contains(s.kind) { ordered.append(s.kind) }
        }
        collapsedActiveKinds = Array(ordered.prefix(2))

        if totalNeedsInputCount == 0 && totalRunningCount == 1 && totalUnreadCount == 0 {
            singleRunningSession = allRunning.first
        } else {
            singleRunningSession = nil
        }
    }

    var collapsedLeftEarWidth: CGFloat {
        let count = collapsedActiveKinds.count
        if count >= 2 { return 68 }
        if count == 1 { return 58 }
        return 40
    }

    var collapsedRightEarWidth: CGFloat {
        if totalNeedsInputCount > 0 { return 64 }
        if singleRunningSession != nil { return 68 }
        if totalRunningCount > 0 && totalUnreadCount > 0 { return 68 }
        if totalRunningCount > 0 || totalUnreadCount > 0 { return 48 }
        return 26
    }

    var mascotMood: MascotMood {
        let now = Date()
        if dizzyUntil > now { return .dizzy }
        if pokedUntil > now { return .poked }
        if celebratingUntil > now { return .celebrating }
        if totalNeedsInputCount > 0 { return .needsInput }
        if hasUnreadError { return .error }
        if totalRunningCount > 0 { return .working }
        if totalUnreadCount > 0 { return .waitingUnread }
        return .sleeping
    }

    var mascotStatusText: String {
        switch mascotMood {
        case .dizzy, .poked, .celebrating:
            return l10n.stageCaption(for: mascotMood)
        default:
            return l10n.mascotLongStatus(running: totalRunningCount, unread: totalUnreadCount, needsInput: totalNeedsInputCount)
        }
    }

    // MARK: - Interactive Actions

    func pokeMascot() {
        let now = Date()
        recentPokeTimestamps = recentPokeTimestamps.filter { now.timeIntervalSince($0) < 2.2 }
        recentPokeTimestamps.append(now)

        let deadline: Date
        if recentPokeTimestamps.count >= 4 {
            deadline = now.addingTimeInterval(2.8)
            dizzyUntil = deadline
            pokedUntil = .distantPast
            recentPokeTimestamps.removeAll()
            if soundEnabled { NSSound(named: NSSound.Name("Pop"))?.play() }
        } else {
            deadline = now.addingTimeInterval(1.6)
            pokedUntil = deadline
            if soundEnabled { NSSound(named: NSSound.Name("Tink"))?.play() }
        }
        notifyCounts()
        scheduleMoodReset(until: deadline)
    }

    func markRead(_ session: AgentSession) {
        let compTs = (session.completedAt ?? session.updatedAt).timeIntervalSince1970
        ackedAt[session.id] = max(ackedAt[session.id] ?? 0, compTs)
        saveAckState()
        if let idx = allSessions.firstIndex(where: { $0.id == session.id }) {
            let liveComp = (allSessions[idx].completedAt ?? allSessions[idx].updatedAt).timeIntervalSince1970
            if liveComp <= (ackedAt[session.id] ?? 0) + 0.001 {
                allSessions[idx].isUnread = false
            }
        }
        recomputeDerived()
        notifyCounts()
    }

    func markRead(byId id: String, upTo timestamp: TimeInterval? = nil) {
        if let timestamp {
            ackedAt[id] = max(ackedAt[id] ?? 0, timestamp)
            if let idx = allSessions.firstIndex(where: { $0.id == id }) {
                let liveComp = (allSessions[idx].completedAt ?? allSessions[idx].updatedAt).timeIntervalSince1970
                if liveComp <= (ackedAt[id] ?? 0) + 0.001 {
                    allSessions[idx].isUnread = false
                }
            }
        } else if let idx = allSessions.firstIndex(where: { $0.id == id }) {
            let comp = (allSessions[idx].completedAt ?? allSessions[idx].updatedAt).timeIntervalSince1970
            ackedAt[id] = max(ackedAt[id] ?? 0, comp)
            allSessions[idx].isUnread = false
        } else {
            ackedAt[id] = max(ackedAt[id] ?? 0, Date().timeIntervalSince1970)
        }
        saveAckState()
        recomputeDerived()
        notifyCounts()
    }

    func markAllRead() {
        for i in allSessions.indices where allSessions[i].isUnread {
            let comp = (allSessions[i].completedAt ?? allSessions[i].updatedAt).timeIntervalSince1970
            ackedAt[allSessions[i].id] = max(ackedAt[allSessions[i].id] ?? 0, comp)
            allSessions[i].isUnread = false
        }
        saveAckState()
        recomputeDerived()
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

    @discardableResult
    func openSession(byId id: String) -> Bool {
        if let session = allSessions.first(where: { $0.id == id }) {
            return openSession(session)
        }
        if id.hasPrefix("t3code:") {
            let rawId = String(id.dropFirst("t3code:".count))
            if let url = t3Scanner.deepLinkURL(forThreadId: rawId) {
                dismissJumpHint()
                NSApp.keyWindow?.resignKey()
                jumpLogger.info("Jumping to T3 Code thread (byId fallback) via deep link \(url.absoluteString, privacy: .private)")
                openDeepLink(url, bundleIDs: AgentKind.t3code.targetBundleIDs)
                return true
            }
        }
        return false
    }

    private func deepLinkString(for session: AgentSession) -> String? {
        switch session.kind {
        case .codex:
            return session.rawId.isEmpty ? nil : "codex://threads/\(session.rawId)"
        case .t3code:
            return t3Scanner.deepLinkURL(forThreadId: session.rawId)?.absoluteString
        case .gemini:
            guard session.id.hasPrefix("gemini:desktop:") else { return nil }
            return geminiDesktopScanner.deepLinkURL(forSessionId: session.id)?.absoluteString
        default:
            return nil
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
            jumpLogger.info("Debounced duplicate jump click for \(session.id, privacy: .private)")
            return true
        }

        // Cancel any previously in-flight Antigravity Cmd+K sequence whenever a new jump starts
        cancelPendingAntigravityJump()

        switch session.kind {
        case .codex:
            lastJumpKey = session.id
            lastJumpAt = now
            dismissJumpHint()
            NSApp.keyWindow?.resignKey()
            jumpLogger.info("Jumping to Codex thread \(session.rawId, privacy: .private)")
            if !session.rawId.isEmpty,
               let url = URL(string: "codex://threads/\(session.rawId)") {
                openDeepLink(url, bundleIDs: session.kind.targetBundleIDs)
                return true
            }
            openApp(for: .codex)
            return true

        case .antigravity:
            refreshAccessibilityStatus()
            let trusted = accessibilityGranted
            let queryTitle = Self.cleanSearchQuery(from: session.title)
            let alreadyFront = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.google.antigravity"
            jumpLogger.info("Jumping to Antigravity id=\(session.rawId, privacy: .private) trusted=\(trusted) autoJump=\(self.autoJumpAntigravity) alreadyFront=\(alreadyFront) query=\(queryTitle, privacy: .private)")

            if autoJumpAntigravity && !trusted {
                showJumpHint(l10n.accessibilityStaleHintBanner)
                if !alreadyFront {
                    lastJumpKey = session.id
                    lastJumpAt = now
                    activateApp(bundleIDs: session.kind.targetBundleIDs)
                    return true
                }
                // Blocked by missing Accessibility permission while Antigravity is already front:
                // Do NOT record debounce timestamp so subsequent clicks don't bypass the block and clear unread!
                return false
            }

            lastJumpKey = session.id
            lastJumpAt = now
            dismissJumpHint()
            NSApp.keyWindow?.resignKey()
            let shouldAutoLocate = autoJumpAntigravity && trusted && !queryTitle.isEmpty
            let token = antigravityJumpToken
            activateApp(bundleIDs: session.kind.targetBundleIDs) { [weak self] in
                guard let self, shouldAutoLocate, self.antigravityJumpToken == token else { return }
                self.waitForFrontmostAndLocate(bundleID: "com.google.antigravity", titleQuery: queryTitle, project: session.project, token: token, attempt: 0)
            }
            return true

        case .t3code:
            lastJumpKey = session.id
            lastJumpAt = now
            dismissJumpHint()
            NSApp.keyWindow?.resignKey()
            if let url = t3Scanner.deepLinkURL(forThreadId: session.rawId) {
                jumpLogger.info("Jumping to T3 Code thread via deep link \(url.absoluteString, privacy: .private)")
                openDeepLink(url, bundleIDs: session.kind.targetBundleIDs)
                return true
            }
            jumpLogger.info("Jumping to T3 Code app without deep link rawId=\(session.rawId, privacy: .private)")
            let queryTitle = Self.cleanSearchQuery(from: session.title)
            let targetBids = session.kind.targetBundleIDs
            activateApp(bundleIDs: targetBids) {
                guard !queryTitle.isEmpty else { return }
                let pids = targetBids.compactMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0).first?.processIdentifier }
                DispatchQueue.global(qos: .userInitiated).async {
                    for pid in pids {
                        if Self.tryRaiseMatchingAXWindow(pid: pid, query: queryTitle) {
                            return
                        }
                    }
                }
            }
            return true

        case .gemini:
            lastJumpKey = session.id
            lastJumpAt = now
            dismissJumpHint()
            NSApp.keyWindow?.resignKey()
            if session.id.hasPrefix("gemini:desktop:") {
                let targetTitle = session.title
                let deepLink = geminiDesktopScanner.deepLinkURL(forSessionId: session.id)
                jumpLogger.info("Jumping to Gemini Desktop chat=\(targetTitle, privacy: .private) deepLink=\(deepLink?.absoluteString ?? "nil", privacy: .private)")
                activateApp(bundleIDs: [GeminiDesktopScanner.bundleID]) { [weak self] in
                    let pid = NSRunningApplication.runningApplications(withBundleIdentifier: GeminiDesktopScanner.bundleID).first?.processIdentifier
                    let trusted = AXIsProcessTrusted()
                    DispatchQueue.global(qos: .userInitiated).async {
                        let raised = (pid != nil && trusted)
                            ? GeminiDesktopScanner.tryRaiseOrSelectConversation(pid: pid!, title: targetTitle)
                            : false
                        if !raised, let deepLink {
                            Task { @MainActor [weak self] in
                                self?.openDeepLink(deepLink, bundleIDs: [GeminiDesktopScanner.bundleID])
                            }
                        }
                    }
                }
            } else {
                activateApp(bundleIDs: ["com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.apple.Terminal"])
            }
            return true

        default:
            lastJumpKey = session.id
            lastJumpAt = now
            dismissJumpHint()
            NSApp.keyWindow?.resignKey()
            openApp(for: session.kind)
            return true
        }
    }

    func openApp(for kind: AgentKind) {
        activateApp(bundleIDs: kind.targetBundleIDs)
    }

    private func openDeepLink(_ url: URL, bundleIDs: [String]) {
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        NSWorkspace.shared.open(url, configuration: cfg) { [weak self] app, error in
            if let error {
                self?.jumpLogger.error("Deep link open failed for \(url.absoluteString, privacy: .private): \(error.localizedDescription, privacy: .public)")
                DispatchQueue.main.async {
                    self?.activateApp(bundleIDs: bundleIDs)
                }
                return
            }
            if let app {
                DispatchQueue.main.async {
                    app.activate()
                }
            }
        }
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

    private func restorePendingClipboardIfUnchanged() {
        guard let pending = pendingClipboardRestore else { return }
        pendingClipboardRestore = nil
        let pb = NSPasteboard.general
        if pb.changeCount == pending.expectedChangeCount {
            Self.restorePasteboard(pending.snapshot, to: pb)
        }
    }

    private func cancelPendingAntigravityJump() {
        antigravityJumpToken &+= 1
        for work in pendingJumpWorkItems {
            work.cancel()
        }
        pendingJumpWorkItems.removeAll()
        restorePendingClipboardIfUnchanged()
    }

    private func scheduleJumpStep(after delay: TimeInterval, token: UInt64, block: @escaping () -> Void) {
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.antigravityJumpToken == token else { return }
            block()
        }
        pendingJumpWorkItems.append(work)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func waitForFrontmostAndLocate(bundleID: String, titleQuery: String, project: String, token: UInt64, attempt: Int) {
        guard antigravityJumpToken == token else { return }
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if front == bundleID {
            jumpLogger.info("Antigravity focus ready (attempt=\(attempt)); running Cmd+K locate")
            scheduleJumpStep(after: 0.10, token: token) { [weak self] in
                self?.locateAntigravityConversation(titleQuery: titleQuery, project: project, token: token)
            }
            return
        }
        // CRITICAL: Never send synthetic keystrokes if Antigravity failed to become frontmost!
        if attempt >= 12 {
            jumpLogger.warning("Aborted Antigravity Cmd+K locate: frontmost app is \(front ?? "nil", privacy: .public), not Antigravity")
            return
        }
        if attempt == 4, let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            running.activate()
        }
        scheduleJumpStep(after: 0.05, token: token) { [weak self] in
            self?.waitForFrontmostAndLocate(bundleID: bundleID, titleQuery: titleQuery, project: project, token: token, attempt: attempt + 1)
        }
    }

    private static func snapshotPasteboard(_ pb: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        guard let items = pb.pasteboardItems else { return [] }
        return items.compactMap { item in
            var dict: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    dict[type] = data
                }
            }
            return dict.isEmpty ? nil : dict
        }
    }

    private static func restorePasteboard(_ snapshot: [[NSPasteboard.PasteboardType: Data]], to pb: NSPasteboard) {
        pb.clearContents()
        guard !snapshot.isEmpty else { return }
        let items: [NSPasteboardItem] = snapshot.map { dict in
            let item = NSPasteboardItem()
            for (type, data) in dict {
                item.setData(data, forType: type)
            }
            return item
        }
        pb.writeObjects(items)
    }

    /// Locates the exact Antigravity conversation safely:
    /// 1) Raises an existing Antigravity window if its title matches directly.
    /// 2) Otherwise uses Antigravity's official `Cmd + K` Conversations Palette with strict frontmost
    ///    app verification before EVERY synthetic keystroke and full multi-type clipboard preservation.
    private func locateAntigravityConversation(titleQuery: String, project: String, token: UInt64) {
        let targetBundle = "com.google.antigravity"
        func isTargetFrontmost() -> Bool {
            antigravityJumpToken == token && NSWorkspace.shared.frontmostApplication?.bundleIdentifier == targetBundle
        }
        guard isTargetFrontmost() else { return }

        // 1. Check off-main-thread if a separate Antigravity window already shows this exact conversation
        let agyPID = NSRunningApplication.runningApplications(withBundleIdentifier: targetBundle).first?.processIdentifier
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            if let pid = agyPID, Self.tryRaiseMatchingAXWindow(pid: pid, query: titleQuery) {
                Task { @MainActor [weak self] in
                    self?.jumpLogger.info("Raised matching Antigravity AX window directly")
                }
                return
            }
            Task { @MainActor [weak self] in
                self?.runAntigravityPaletteSequence(titleQuery: titleQuery, token: token, pid: agyPID)
            }
        }
    }

    private func runAntigravityPaletteSequence(titleQuery: String, token: UInt64, pid: pid_t?) {
        let targetBundle = "com.google.antigravity"
        func isTargetFrontmost() -> Bool {
            antigravityJumpToken == token && NSWorkspace.shared.frontmostApplication?.bundleIdentifier == targetBundle
        }
        /// Positively verifies that Antigravity's single-line search palette input (`AXTextField`,
        /// `AXSearchField`, or `AXComboBox`) has focus before sending destructive/submit keys.
        func hasVerifiedSearchFieldFocus() -> Bool {
            guard let pid else { return false }
            let appElem = AXUIElementCreateApplication(pid)
            AXUIElementSetAttributeValue(appElem, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            var focusedRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(appElem, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
                  let focused = focusedRef,
                  CFGetTypeID(focused) == AXUIElementGetTypeID() else {
                return false
            }
            let focusedEl = focused as! AXUIElement
            var roleRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(focusedEl, kAXRoleAttribute as CFString, &roleRef) == .success,
                  let role = roleRef as? String else {
                return false
            }
            return role == "AXTextField" || role == "AXSearchField" || role == "AXComboBox"
        }

        guard isTargetFrontmost() else { return }

        // Cmd + K (keyCode 40)
        Self.postKey(40, flags: .maskCommand)

        scheduleJumpStep(after: 0.30, token: token) { [weak self] in
            guard let self, isTargetFrontmost() else { return }
            guard hasVerifiedSearchFieldFocus() else {
                self.jumpLogger.warning("Aborted Antigravity Cmd+K paste: search palette text field not positively focused")
                return
            }
            // Cmd + A (keyCode 0) to clear any previous search text
            Self.postKey(0, flags: .maskCommand)

            self.scheduleJumpStep(after: 0.06, token: token) { [weak self] in
                guard let self, isTargetFrontmost(), hasVerifiedSearchFieldFocus() else { return }
                // Snapshot clipboard IMMEDIATELY before overwriting so prior user copies are never lost
                let pb = NSPasteboard.general
                let savedPasteboard = Self.snapshotPasteboard(pb)
                pb.clearContents()
                pb.setString(titleQuery, forType: .string)
                self.pendingClipboardRestore = PendingClipboardRestore(
                    snapshot: savedPasteboard,
                    expectedChangeCount: pb.changeCount
                )
                // Cmd + V (keyCode 9)
                Self.postKey(9, flags: .maskCommand)

                // Wait for React input debounce + language_server FTS5 query + list re-render
                self.scheduleJumpStep(after: 0.65, token: token) { [weak self] in
                    guard let self else { return }
                    if isTargetFrontmost() && hasVerifiedSearchFieldFocus() {
                        // Return (keyCode 36) to open the #1 exact-title match
                        Self.postKey(36, flags: [])
                        self.jumpLogger.info("Sent Return in Antigravity Cmd+K palette")
                    } else {
                        self.jumpLogger.warning("Aborted Return key in Antigravity Cmd+K: focus left search palette")
                        self.restorePendingClipboardIfUnchanged()
                        return
                    }

                    // Cleanly restore full previous clipboard content (images, files, RTF, strings)
                    self.scheduleJumpStep(after: 0.35, token: token) { [weak self] in
                        self?.restorePendingClipboardIfUnchanged()
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
        let deadline = Date().addingTimeInterval(3.8)
        celebratingUntil = deadline
        if soundEnabled { playSound() }
        onCompletionMoment?()
        let t = l10n
        postNotification(
            id: "test-\(UUID().uuidString)",
            sessionId: nil,
            deepLink: nil,
            title: t.testNotifTitle,
            subtitle: t.testNotifSubtitle,
            body: t.testNotifBody,
            bundleID: AgentKind.antigravity.targetBundleIDs.first ?? ""
        )
        scheduleMoodReset(until: deadline)
    }

    // MARK: - State Machine

    func applyScanned(
        _ scanned: [AgentSession],
        now: Date = Date(),
        deferConfirmKinds: Set<AgentKind> = [],
        deferConfirmSessionIds: Set<String> = []
    ) {
        let isFirst = !didInitialScan
        didInitialScan = true
        if let until = dndUntil, until <= now {
            dndUntil = nil
        }
        var newlyFinished: [AgentSession] = []
        var newlyNeedsInput: [AgentSession] = []
        var processed: [AgentSession] = []
        var ackDirty = false
        var activeIds = Set<String>()

        for raw in scanned {
            var s = raw
            activeIds.insert(s.id)
            let prev = previousStatus[s.id]

            if s.status == .needsInput {
                pendingFinishSince.removeValue(forKey: s.id)
                if liveStartedAt[s.id] == nil {
                    liveStartedAt[s.id] = s.startedAt ?? now
                }
                let alertKey = "\(Int(s.updatedAt.timeIntervalSince1970))|\(s.currentAction)"
                let alreadyAlerted = (prev == .needsInput && notifiedNeedsInputKey[s.id] == alertKey)
                if !isFirst && !alreadyAlerted && !(hideCLISessions && s.isCLI) {
                    newlyNeedsInput.append(s)
                }
                s = AgentSession(
                    id: s.id, rawId: s.rawId, kind: s.kind, title: s.title,
                    project: s.project, cwd: s.cwd, isCLI: s.isCLI, status: .needsInput,
                    currentAction: s.currentAction, detailSummary: s.detailSummary,
                    startedAt: s.startedAt ?? liveStartedAt[s.id], updatedAt: s.updatedAt,
                    completedAt: nil, durationSec: nil,
                    activeSubagents: s.activeSubagents, isUnread: false
                )
            } else if s.status == .running {
                // Cancel any pending completion debounce & reset needs-input dedupe once the agent resumes!
                pendingFinishSince.removeValue(forKey: s.id)
                notifiedNeedsInputKey.removeValue(forKey: s.id)
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
                notifiedNeedsInputKey.removeValue(forKey: s.id)
                let compDate = s.completedAt ?? s.updatedAt
                let compTs = compDate.timeIntervalSince1970

                var dur = s.durationSec
                if dur == nil, let start = liveStartedAt[s.id] {
                    dur = max(1, compDate.timeIntervalSince(start))
                }

                // Auto-ack historical completions whenever a session is seen for the first time (`prev == nil`),
                // or when a pre-launch completion exits a transient state without ever having run post-launch.
                let isStalePreLaunch = (!isFirst && compDate < launchTime && (ackedAt[s.id] ?? 0) < compTs)
                if (ackedAt[s.id] == nil && prev == nil && now.timeIntervalSince(compDate) > 900) || isStalePreLaunch {
                    ackedAt[s.id] = max(ackedAt[s.id] ?? 0, compTs)
                    ackDirty = true
                }

                let lastAck = ackedAt[s.id] ?? 0
                let rawIsUnread = !s.isCLI && (s.status == .done || s.status == .error) && (compTs > lastAck + 0.001)
                let alreadyNotified = (notifiedCompletedAt[s.id] ?? 0) >= compTs - 0.001

                // Require a continuous settle window keyed by (sessionId, completedAt) before treating a
                // freshly-stopped running/needsInput turn as done, preventing premature popups during handoffs.
                // Also pause completion confirmation only for affected kinds/sessionIds during transient DB failures.
                var settling = false
                if !isFirst && rawIsUnread && !alreadyNotified {
                    let existingPending = pendingFinishSince[s.id]
                    let isFreshTransition = (prev == .running || prev == .needsInput || existingPending != nil || compDate > launchTime)
                    if isFreshTransition {
                        let deferThis = deferConfirmKinds.contains(s.kind) || deferConfirmSessionIds.contains(s.id)
                        if deferThis {
                            pendingFinishSince[s.id] = PendingFinish(completedAt: compTs, since: now, waitingForCleanRead: true)
                            settling = true
                        } else {
                            let pending: PendingFinish
                            if let existingPending,
                               !existingPending.waitingForCleanRead,
                               abs(existingPending.completedAt - compTs) <= 1.0 {
                                pending = existingPending
                            } else {
                                // Restart full 4.5s settle window on first clean read after any transient DB failure
                                pending = PendingFinish(completedAt: compTs, since: now, waitingForCleanRead: false)
                                pendingFinishSince[s.id] = pending
                            }
                            if now.timeIntervalSince(pending.since) < completionDebounceSeconds {
                                settling = true
                            }
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
                    newlyFinished.append(s)
                    confirmedCompletionIds.append(s.id)
                }
            }

            previousStatus[s.id] = s.status
            processed.append(s)
        }

        // Never let a pending settle timer carry over across a scan where the session disappeared!
        pendingFinishSince = pendingFinishSince.filter { activeIds.contains($0.key) }

        // Periodic bounded-memory eviction for long-running sessions.
        // CRITICAL: Never evict `ackedAt` for sessions still present in `activeIds`, otherwise an
        // older (>7d) completed session whose ack timestamp was pruned would resurrect as unread!
        if now.timeIntervalSince(lastPruneAt) > 600 {
            lastPruneAt = now
            previousStatus = previousStatus.filter { activeIds.contains($0.key) }
            liveStartedAt = liveStartedAt.filter { activeIds.contains($0.key) }
            pendingFinishSince = pendingFinishSince.filter { activeIds.contains($0.key) }
            notifiedNeedsInputKey = notifiedNeedsInputKey.filter { activeIds.contains($0.key) }
            let cutoff7d = now.timeIntervalSince1970 - 7 * 86400
            let beforeCount = ackedAt.count
            ackedAt = ackedAt.filter { activeIds.contains($0.key) || $0.value >= cutoff7d }
            if ackedAt.count != beforeCount { ackDirty = true }
            notifiedCompletedAt = notifiedCompletedAt.filter { activeIds.contains($0.key) || $0.value >= cutoff7d }
        }

        if ackDirty { saveAckState() }

        if processed != allSessions {
            allSessions = processed
            recomputeDerived()
            notifyCounts()
        }

        guard !suppressSystemSideEffects else {
            for item in newlyNeedsInput {
                notifiedNeedsInputKey[item.id] = "\(Int(item.updatedAt.timeIntervalSince1970))|\(item.currentAction)"
            }
            for item in newlyFinished {
                notifiedCompletedAt[item.id] = (item.completedAt ?? item.updatedAt).timeIntervalSince1970
            }
            if newlyFinished.contains(where: { $0.status == .done }) && !isDNDActive {
                celebratingUntil = now.addingTimeInterval(4.5)
            }
            return
        }

        let mutedByDND = isDNDActive
        let t = l10n

        if !newlyNeedsInput.isEmpty {
            let batch = Array(newlyNeedsInput.prefix(2))
            for item in batch {
                notifiedNeedsInputKey[item.id] = "\(Int(item.updatedAt.timeIntervalSince1970))|\(item.currentAction)"
            }
            if !mutedByDND {
                onCompletionMoment?()
                if soundEnabled && now.timeIntervalSince(lastAlertSoundAt) >= 2.5 {
                    lastAlertSoundAt = now
                    playSound("Ping")
                }
                if notificationsEnabled {
                    for item in batch {
                        postNotification(
                            id: "input-\(item.id)-\(Int(item.updatedAt.timeIntervalSince1970))",
                            sessionId: item.id,
                            deepLink: deepLinkString(for: item),
                            completedAt: nil,
                            title: t.needsInputNotifTitle(kind: item.kind, project: t.project(item.project)),
                            subtitle: item.title,
                            body: t.needsInputNotifBody(kind: item.kind),
                            bundleID: item.kind.targetBundleIDs.first ?? ""
                        )
                    }
                }
            }
        }

        if !newlyFinished.isEmpty {
            let batch = Array(newlyFinished.prefix(3))
            for item in batch {
                notifiedCompletedAt[item.id] = (item.completedAt ?? item.updatedAt).timeIntervalSince1970
            }
            // Keep overflow items pending so they fire cleanly on the next tick instead of being dropped forever
            if newlyFinished.count > 3 {
                for overflow in newlyFinished.dropFirst(3) {
                    let ts = (overflow.completedAt ?? overflow.updatedAt).timeIntervalSince1970
                    pendingFinishSince[overflow.id] = PendingFinish(completedAt: ts, since: now.addingTimeInterval(-completionDebounceSeconds))
                }
            }
            let hasSuccessfulDone = newlyFinished.contains { $0.status == .done }
            if hasSuccessfulDone && !mutedByDND {
                let deadline = now.addingTimeInterval(4.5)
                celebratingUntil = deadline
                scheduleMoodReset(until: deadline)
            }
            if !mutedByDND {
                onCompletionMoment?()
                if soundEnabled && now.timeIntervalSince(lastAlertSoundAt) >= 2.5 {
                    lastAlertSoundAt = now
                    playSound()
                }
                if notificationsEnabled {
                    for item in batch {
                        let compTs = (item.completedAt ?? now).timeIntervalSince1970
                        postNotification(
                            id: "\(item.id)-\(Int(compTs))",
                            sessionId: item.id,
                            deepLink: deepLinkString(for: item),
                            completedAt: compTs,
                            title: t.finishNotifTitle(kind: item.kind, project: t.project(item.project), isError: item.status == .error),
                            subtitle: item.title,
                            body: t.finishNotifBody(kind: item.kind),
                            bundleID: item.kind.targetBundleIDs.first ?? ""
                        )
                    }
                }
            }
        }
    }

    private func notifyCounts() {
        onCountsChanged?(totalRunningCount, totalUnreadCount, totalNeedsInputCount, mascotMood)
    }

    private func postNotification(id: String, sessionId: String?, deepLink: String?, completedAt: TimeInterval? = nil, title: String, subtitle: String, body: String, bundleID: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.subtitle = subtitle
        content.body = body
        var info: [String: Any] = ["bundleID": bundleID]
        if let sessionId { info["sessionId"] = sessionId }
        if let deepLink { info["deepLink"] = deepLink }
        if let completedAt { info["completedAt"] = completedAt }
        content.userInfo = info
        let logger = jumpLogger
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil)) { error in
            if let error {
                logger.error("Failed to post macOS notification: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func loadAckState() {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: statePath)),
              let dict = try? JSONDecoder().decode([String: TimeInterval].self, from: data) else { return }
        let cutoff = Date().timeIntervalSince1970 - 30 * 86400
        ackedAt = dict.filter { $0.value >= cutoff }
    }

    private func saveAckState() {
        guard let data = try? JSONEncoder().encode(ackedAt) else { return }
        try? data.write(to: URL(fileURLWithPath: statePath), options: .atomic)
    }
}
