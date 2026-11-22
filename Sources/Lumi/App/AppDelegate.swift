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
    private let store = MonitorStore()

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
        store.onCountsChanged = { [weak self] running, unread, _ in
            self?.updateStatusItem(running: running, unread: unread)
        }
        store.onCompletionMoment = { [weak self] in
            guard let self, self.store.displayMode == .notch else { return }
            self.notchController.peekBrieflyForCompletion()
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

    // MARK: - Menu Bar

    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let btn = statusItem.button else { return }
        btn.target = self
        btn.action = #selector(statusItemClicked(_:))
        btn.sendAction(on: [.leftMouseUp, .rightMouseUp])
        updateStatusItem(running: 0, unread: 0)
    }

    private func updateStatusItem(running: Int, unread: Int) {
        guard let btn = statusItem?.button else { return }
        var parts: [String] = []
        if running > 0 { parts.append("⚡\(running)") }
        if unread > 0 { parts.append("✓\(unread)") }

        if parts.isEmpty {
            let img = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Lumi")
            img?.isTemplate = true
            btn.image = img
            btn.title = ""
        } else {
            btn.image = nil
            btn.title = " " + parts.joined(separator: " · ") + " "
        }
        btn.toolTip = "Lumi — 执行中: \(running) · 待查看: \(unread)（左键展开/切换，右键菜单）"
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu()
            return
        }
        if store.displayMode == .notch {
            notchController.toggleExpanded()
        } else if floatingPanel.isVisible {
            floatingPanel.orderOut(nil)
        } else {
            showFloatingPanel(activate: true)
        }
    }

    private func showContextMenu() {
        let menu = NSMenu()
        let modeTitle = store.displayMode == .notch ? "切换为桌面悬浮看板" : "切换为刘海灵动岛"
        let modeItem = NSMenuItem(title: modeTitle, action: #selector(menuSwitchMode), keyEquivalent: "")
        modeItem.target = self
        menu.addItem(modeItem)

        let readItem = NSMenuItem(title: "全部标为已读", action: #selector(menuMarkAllRead), keyEquivalent: "")
        readItem.target = self
        menu.addItem(readItem)

        let settingsItem = NSMenuItem(title: "设置…", action: #selector(menuOpenSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "退出 Lumi", action: #selector(menuQuit), keyEquivalent: "q")
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
            NSApp.activate(ignoringOtherApps: true)
            existing.makeKeyAndOrderFront(nil)
            return
        }
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 516),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        win.title = "Lumi 设置"
        win.center()
        win.isReleasedWhenClosed = false
        win.contentView = NSHostingView(rootView: SettingsView(store: store))
        settingsWindow = win
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }
}
