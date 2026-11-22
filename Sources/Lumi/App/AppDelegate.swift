import AppKit
import SwiftUI
import UserNotifications

@main
struct LumiAppLauncher {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var statusItem: NSStatusItem!
    private var floatingPanel: NSPanel!
    private var settingsWindow: NSWindow?
    private var notchController: NotchWindowController!
    private let hotKeyManager = GlobalHotKeyManager()
    private var localKeyMonitor: Any?
    private let store = MonitorStore()
    private lazy var menuBarEmberIcon: NSImage = makeMenuBarEmberTemplateIcon()

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupNotifications()
        setupStatusBar()
        setupFloatingPanel()

        notchController = NotchWindowController(
            store: store,
            onPopOutFloating: { [weak self] in self?.switchMode(.floating) },
            onOpenSettings: { [weak self] in self?.openSettings() }
        )

        store.onDisplayModeChanged = { [weak self] mode in
            self?.applyDisplayMode(mode)
        }
        store.onWindowLevelChanged = { [weak self] onTop in
            self?.floatingPanel.level = onTop ? .floating : .normal
        }
        store.onScreenChanged = { [weak self] in
            self?.notchController.recomputeScreenGeometry(animated: false)
        }
        store.onLanguageChanged = { [weak self] in
            guard let self else { return }
            self.settingsWindow?.title = self.store.l10n.settingsWindowTitle
            self.updateStatusItem(
                running: self.store.totalRunningCount,
                unread: self.store.totalUnreadCount,
                needsInput: self.store.totalNeedsInputCount
            )
        }
        store.onHotKeyPresetChanged = { [weak self] preset in
            self?.registerGlobalHotKey(preset: preset)
        }
        store.onCountsChanged = { [weak self] running, unread, needsInput, _ in
            self?.updateStatusItem(running: running, unread: unread, needsInput: needsInput)
        }
        store.onCompletionMoment = { [weak self] in
            guard let self, self.store.displayMode == .notch else { return }
            self.notchController.peekBrieflyForCompletion()
        }

        registerGlobalHotKey(preset: store.hotKeyPreset)
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // Escape collapses expanded notch or hides floating board
                guard let self else { return event }
                if self.store.displayMode == .notch && self.notchController.isExpanded {
                    self.notchController.collapseAfterJump()
                    return nil
                } else if self.store.displayMode == .floating && self.floatingPanel.isKeyWindow {
                    self.floatingPanel.orderOut(nil)
                    return nil
                }
            }
            return event
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.notchController.recomputeScreenGeometry(animated: false)
            }
        }

        store.start()
        applyDisplayMode(store.displayMode)
    }

    // MARK: - Notifications

    private func setupNotifications() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        if let sessionId = info["sessionId"] as? String {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.store.markRead(byId: sessionId)
                self.store.openSession(byId: sessionId)
            }
            completionHandler()
            return
        }
        if let deepLink = info["deepLink"] as? String, let url = URL(string: deepLink) {
            NSWorkspace.shared.open(url)
        }
        if let bundleID = info["bundleID"] as? String,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: cfg, completionHandler: nil)
        }
        completionHandler()
    }

    private func registerGlobalHotKey(preset: GlobalHotKeyPreset) {
        hotKeyManager.register(preset: preset) { [weak self] in
            self?.togglePrimaryUI()
        }
    }

    private func togglePrimaryUI() {
        if store.displayMode == .notch {
            notchController.toggleExpanded()
        } else if floatingPanel.isVisible {
            floatingPanel.orderOut(nil)
        } else {
            showFloatingPanel(activate: true)
        }
    }

    // MARK: - Menu Bar

    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let btn = statusItem.button else { return }
        btn.target = self
        btn.action = #selector(statusItemClicked(_:))
        btn.sendAction(on: [.leftMouseUp, .rightMouseUp])
        updateStatusItem(running: 0, unread: 0, needsInput: 0)
    }

    /// Draws an ultra-crisp 18x18 monochrome template Lumi Ember bean silhouette
    /// with punched-out asymmetric eyes & smile so macOS adapts it automatically to Light/Dark menu bars.
    private func makeMenuBarEmberTemplateIcon() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let img = NSImage(size: size, flipped: true) { bounds in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let w: CGFloat = 14.0
            let h: CGFloat = 14.6
            let ox = (bounds.width - w) * 0.5
            let oy = (bounds.height - h) * 0.5 + 0.3

            func pt(_ nx: CGFloat, _ ny: CGFloat) -> CGPoint {
                CGPoint(x: ox + nx * w, y: oy + ny * h)
            }

            let body = CGMutablePath()
            body.move(to: pt(0.51, 0.00))
            body.addCurve(to: pt(0.91, 0.22), control1: pt(0.71, 0.00), control2: pt(0.84, 0.09))
            body.addCurve(to: pt(1.00, 0.54), control1: pt(0.98, 0.33), control2: pt(1.01, 0.44))
            body.addCurve(to: pt(0.84, 0.85), control1: pt(0.99, 0.67), control2: pt(0.93, 0.77))
            body.addCurve(to: pt(0.40, 1.00), control1: pt(0.73, 0.95), control2: pt(0.56, 1.01))
            body.addCurve(to: pt(0.00, 0.74), control1: pt(0.18, 0.99), control2: pt(0.01, 0.90))
            body.addCurve(to: pt(0.10, 0.40), control1: pt(-0.01, 0.60), control2: pt(0.07, 0.50))
            body.addCurve(to: pt(0.20, 0.14), control1: pt(0.12, 0.28), control2: pt(0.14, 0.20))
            body.addCurve(to: pt(0.51, 0.00), control1: pt(0.28, 0.04), control2: pt(0.39, 0.00))
            body.closeSubpath()

            ctx.setFillColor(NSColor.black.cgColor)
            ctx.addPath(body)
            ctx.fillPath()

            // Punch out signature asymmetric eyes + tilted goofy smile
            ctx.setBlendMode(.clear)
            let lEye = CGRect(x: pt(0.35, 0.45).x - 1.55, y: pt(0.35, 0.45).y - 1.55, width: 3.1, height: 3.1)
            let rEye = CGRect(x: pt(0.68, 0.39).x - 1.95, y: pt(0.68, 0.39).y - 1.95, width: 3.9, height: 3.9)
            ctx.fillEllipse(in: lEye)
            ctx.fillEllipse(in: rEye)

            let smile = CGMutablePath()
            smile.move(to: pt(0.42, 0.68))
            smile.addQuadCurve(to: pt(0.60, 0.65), control: pt(0.51, 0.78))
            ctx.setLineWidth(1.25)
            ctx.setLineCap(.round)
            ctx.addPath(smile)
            ctx.strokePath()

            // Tiny solid pupils inside punched-out eyes
            ctx.setBlendMode(.normal)
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.fillEllipse(in: CGRect(x: lEye.midX - 0.55, y: lEye.midY - 0.65, width: 1.35, height: 1.35))
            ctx.fillEllipse(in: CGRect(x: rEye.midX - 0.85, y: rEye.midY - 0.60, width: 1.55, height: 1.55))

            return true
        }
        img.isTemplate = true
        return img
    }

    private func updateStatusItem(running: Int, unread: Int, needsInput: Int) {
        guard let btn = statusItem?.button else { return }
        var parts: [String] = []
        if needsInput > 0 { parts.append("?\(needsInput)") }
        if running > 0 { parts.append("⚡\(running)") }
        if unread > 0 { parts.append("✓\(unread)") }
        if store.isDNDActive { parts.append("☾") }

        btn.image = menuBarEmberIcon
        btn.imagePosition = parts.isEmpty ? .imageOnly : .imageLeading
        btn.title = parts.isEmpty ? "" : " " + parts.joined(separator: " · ")
        btn.toolTip = store.l10n.statusTooltip(
            running: running,
            unread: unread,
            needsInput: needsInput,
            dndRemaining: store.dndRemainingText
        )
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu()
            return
        }
        togglePrimaryUI()
    }

    private func showContextMenu() {
        let t = store.l10n
        let menu = NSMenu()
        let modeTitle = store.displayMode == .notch ? t.menuSwitchToFloating : t.menuSwitchToNotch
        let modeItem = NSMenuItem(title: modeTitle, action: #selector(menuSwitchMode), keyEquivalent: "")
        modeItem.target = self
        menu.addItem(modeItem)

        let readItem = NSMenuItem(title: t.menuMarkAllRead, action: #selector(menuMarkAllRead), keyEquivalent: "")
        readItem.target = self
        menu.addItem(readItem)

        // Do Not Disturb submenu
        let dndMenu = NSMenu()
        let dnd30 = NSMenuItem(title: t.menuDND30m, action: #selector(menuDND30m), keyEquivalent: "")
        dnd30.target = self
        dndMenu.addItem(dnd30)
        let dnd60 = NSMenuItem(title: t.menuDND1h, action: #selector(menuDND1h), keyEquivalent: "")
        dnd60.target = self
        dndMenu.addItem(dnd60)
        if store.isDNDActive {
            dndMenu.addItem(.separator())
            let dndOff = NSMenuItem(title: t.menuDNDOff, action: #selector(menuDNDOff), keyEquivalent: "")
            dndOff.target = self
            dndMenu.addItem(dndOff)
        }
        let dndParent = NSMenuItem(
            title: store.dndRemainingText.map { "\(t.menuDNDTitle) (\($0))" } ?? t.menuDNDTitle,
            action: nil,
            keyEquivalent: ""
        )
        dndParent.submenu = dndMenu
        menu.addItem(dndParent)

        // Language submenu (instant live switch!)
        let langMenu = NSMenu()
        for lang in AppLanguage.allCases {
            let item = NSMenuItem(title: lang.label(isEnglish: store.isEnglish), action: #selector(menuSelectLanguage(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = lang.rawValue
            item.state = (store.appLanguage == lang) ? .on : .off
            langMenu.addItem(item)
        }
        let langParent = NSMenuItem(title: t.menuLanguageTitle, action: nil, keyEquivalent: "")
        langParent.submenu = langMenu
        menu.addItem(langParent)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: t.menuSettings, action: #selector(menuOpenSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let quitItem = NSMenuItem(title: t.menuQuit, action: #selector(menuQuit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func menuSwitchMode() {
        switchMode(store.displayMode == .notch ? .floating : .notch)
    }
    @objc private func menuMarkAllRead() { store.markAllRead() }
    @objc private func menuDND30m() { store.enableDND(minutes: 30) }
    @objc private func menuDND1h() { store.enableDND(minutes: 60) }
    @objc private func menuDNDOff() { store.disableDND() }
    @objc private func menuSelectLanguage(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let lang = AppLanguage(rawValue: raw) {
            store.appLanguage = lang
        }
    }
    @objc private func menuOpenSettings() { openSettings() }
    @objc private func menuQuit() { NSApp.terminate(nil) }

    // MARK: - Mode Switching & Windows

    private func switchMode(_ mode: DisplayMode) {
        store.displayMode = mode
    }

    private func applyDisplayMode(_ mode: DisplayMode) {
        switch mode {
        case .notch:
            floatingPanel.orderOut(nil)
            notchController.show()
        case .floating:
            notchController.hide()
            showFloatingPanel(activate: false)
        }
    }

    private func setupFloatingPanel() {
        let rect = NSRect(x: 0, y: 0, width: 454, height: 496)
        floatingPanel = NSPanel(
            contentRect: rect,
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        floatingPanel.title = "Lumi"
        floatingPanel.titleVisibility = .hidden
        floatingPanel.titlebarAppearsTransparent = true
        floatingPanel.isMovableByWindowBackground = true
        floatingPanel.isFloatingPanel = true
        floatingPanel.hidesOnDeactivate = false
        floatingPanel.level = store.alwaysOnTop ? .floating : .normal
        floatingPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        floatingPanel.isOpaque = false
        floatingPanel.backgroundColor = .clear
        floatingPanel.hasShadow = true
        floatingPanel.minSize = NSSize(width: 420, height: 410)
        floatingPanel.maxSize = NSSize(width: 660, height: 960)
        floatingPanel.standardWindowButton(.closeButton)?.isHidden = true
        floatingPanel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        floatingPanel.standardWindowButton(.zoomButton)?.isHidden = true

        let hosting = NSHostingView(rootView: FloatingBoardView(
            store: store,
            onDockToNotch: { [weak self] in self?.switchMode(.notch) },
            onOpenSettings: { [weak self] in self?.openSettings() },
            onHide: { [weak self] in self?.floatingPanel.orderOut(nil) }
        ))
        floatingPanel.contentView = hosting

        let restored = floatingPanel.setFrameUsingName("LumiFloatingBoardFrame")
        floatingPanel.setFrameAutosaveName("LumiFloatingBoardFrame")
        if !restored, let screen = NSScreen.main?.visibleFrame {
            let x = screen.maxX - rect.width - 18
            let y = screen.maxY - rect.height - 18
            floatingPanel.setFrameOrigin(NSPoint(x: x, y: y))
        }
    }

    private func showFloatingPanel(activate: Bool) {
        store.refreshNow()
        floatingPanel.level = store.alwaysOnTop ? .floating : .normal
        if activate {
            NSApp.activate(ignoringOtherApps: true)
            floatingPanel.makeKeyAndOrderFront(nil)
        } else {
            floatingPanel.orderFrontRegardless()
        }
    }

    private func openSettings() {
        if let existing = settingsWindow {
            existing.title = store.l10n.settingsWindowTitle
            NSApp.activate(ignoringOtherApps: true)
            existing.makeKeyAndOrderFront(nil)
            return
        }
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 572),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        win.title = store.l10n.settingsWindowTitle
        win.center()
        win.isReleasedWhenClosed = false
        win.contentView = NSHostingView(rootView: SettingsView(store: store))
        settingsWindow = win
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }
}
