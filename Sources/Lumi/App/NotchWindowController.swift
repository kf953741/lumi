import AppKit
import SwiftUI

/// Mouse tracking container for the Dynamic Notch Island: handles gentle hover-to-expand,
/// leave-to-collapse, and real-time normalized cursor gaze for Lumi's eyes.
final class NotchTrackingHostView: NSView {
    var onMouseEntered: (() -> Void)?
    var onMouseExited: (() -> Void)?
    var onMouseMoved: ((CGPoint, CGSize) -> Void)?
    private var trackingArea: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea { removeTrackingArea(existing) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        onMouseEntered?()
    }

    override func mouseExited(with event: NSEvent) {
        onMouseExited?()
    }

    override func mouseMoved(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        onMouseMoved?(loc, bounds.size)
    }
}

/// Custom NSPanel subclass that prevents macOS from clamping the notch panel
/// down below the menu bar (critical for true flush hardware-notch fusion!).
final class NotchOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        return frameRect
    }
}

/// Isolated cursor gaze model so mouse movement over the notch only redraws LumiMascotView
/// instead of re-evaluating the entire NotchIslandView & StudioBentoBoardView tree.
@MainActor
final class NotchLookModel: ObservableObject {
    @Published var offset: CGSize = .zero
}

@MainActor
final class NotchWindowController: ObservableObject {
    @Published var isExpanded: Bool = false
    @Published var hasHardwareNotch: Bool = false
    @Published var notchWidth: CGFloat = 185
    @Published var notchHeight: CGFloat = 32
    let lookModel = NotchLookModel()

    private var panel: NotchOverlayPanel!
    private var containerView: NotchTrackingHostView!
    private var hostingView: NSView?
    private let store: MonitorStore
    private let onPopOutFloating: () -> Void
    private let onOpenSettings: () -> Void

    private var isMouseInside: Bool = false
    private var isPinnedOpen: Bool = false
    private var hoverOpenWork: DispatchWorkItem?
    private var hoverCloseWork: DispatchWorkItem?

    private let expandedWidth: CGFloat = 496     // inner bento + concave bezel shoulders + light sleeve margin
    private let expandedHeight: CGFloat = 464

    init(store: MonitorStore, onPopOutFloating: @escaping () -> Void, onOpenSettings: @escaping () -> Void) {
        self.store = store
        self.onPopOutFloating = onPopOutFloating
        self.onOpenSettings = onOpenSettings
        setupPanel()
        recomputeScreenGeometry(animated: false)
    }

    func show() {
        if hostingView == nil {
            mountRootView(in: containerView)
        }
        recomputeScreenGeometry(animated: false)
        panel.orderFrontRegardless()
    }

    func hide() {
        hoverOpenWork?.cancel()
        hoverCloseWork?.cancel()
        isExpanded = false
        isPinnedOpen = false
        panel.orderOut(nil)
        hostingView?.removeFromSuperview()
        hostingView = nil
    }

    func toggleExpanded(activateForKeyboard: Bool = false) {
        if isExpanded {
            isPinnedOpen = false
            panel.resignKey()
            setExpanded(false)
        } else {
            isPinnedOpen = true
            setExpanded(true)
            if activateForKeyboard {
                // Allow immediate Escape key dismissal when explicitly opened via global hotkey
                NSApp.activate(ignoringOtherApps: true)
                panel.makeKeyAndOrderFront(nil)
            }
        }
    }

    func collapseAfterJump() {
        hoverOpenWork?.cancel()
        hoverCloseWork?.cancel()
        isPinnedOpen = false
        panel.resignKey()
        if isExpanded {
            setExpanded(false)
        }
    }

    func peekBrieflyForCompletion() {
        guard panel.isVisible, !isExpanded else { return }
        if store.isDNDActive { return }
        if store.hideAutoPeekInFullscreen && isActiveAppInFullscreen() { return }
        setExpanded(true)
        hoverCloseWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isMouseInside, !self.isPinnedOpen else { return }
            self.setExpanded(false)
        }
        hoverCloseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.6, execute: work)
    }

    /// Detects if the frontmost non-Lumi app owns a fullscreen window ON THE TARGET SCREEN
    /// (properly handles multi-monitor setups by intersecting CoreGraphics window bounds with the target screen).
    private func isActiveAppInFullscreen() -> Bool {
        guard let screen = targetScreen(),
              let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              frontPID != ProcessInfo.processInfo.processIdentifier else {
            return false
        }
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        // Convert AppKit bottom-left screen coordinates to CoreGraphics top-left coordinates
        let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? screen.frame.maxY
        let cgScreenRect = CGRect(
            x: screen.frame.minX,
            y: primaryMaxY - screen.frame.maxY,
            width: screen.frame.width,
            height: screen.frame.height
        )
        let screenArea = max(1, cgScreenRect.width * cgScreenRect.height)

        for info in list {
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPID == frontPID,
                  let layer = info[kCGWindowLayer as String] as? Int,
                  layer == 0,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                  let x = boundsDict["X"] as? CGFloat,
                  let y = boundsDict["Y"] as? CGFloat,
                  let w = boundsDict["Width"] as? CGFloat,
                  let h = boundsDict["Height"] as? CGFloat else {
                continue
            }
            guard w >= cgScreenRect.width - 6 && h >= cgScreenRect.height - 6 else { continue }
            let winRect = CGRect(x: x, y: y, width: w, height: h)
            let overlap = winRect.intersection(cgScreenRect)
            if !overlap.isNull && (overlap.width * overlap.height) >= screenArea * 0.5 {
                return true
            }
        }
        return false
    }

    private var notchLeftOffsetFromMid: CGFloat = 0

    func recomputeScreenGeometry(animated: Bool = true) {
        guard let screen = targetScreen() else { return }
        detectNotch(on: screen)
        let frame = targetFrame(on: screen, expanded: isExpanded)
        panel.hasShadow = false
        panel.setFrame(frame, display: true, animate: animated)
    }

    /// Smoothly adapts collapsed notch ear / floating pill widths when active/idle states change,
    /// keeping the center gap locked pixel-exact to the physical MacBook camera notch.
    func updateCollapsedGeometryIfNeeded() {
        guard !isExpanded, panel.isVisible, let screen = targetScreen() else { return }
        let desired = targetFrame(on: screen, expanded: false)
        if abs(panel.frame.width - desired.width) > 0.5 || abs(panel.frame.minX - desired.minX) > 0.5 {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.24
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(desired, display: true)
            }
        }
    }

    // MARK: - Private Setup

    private func setupPanel() {
        panel = NotchOverlayPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 32),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

        let container = NotchTrackingHostView(frame: panel.contentRect(forFrameRect: panel.frame))
        container.autoresizingMask = [.width, .height]
        container.onMouseEntered = { [weak self] in self?.handleMouseEntered() }
        container.onMouseExited = { [weak self] in self?.handleMouseExited() }
        container.onMouseMoved = { [weak self] pt, sz in self?.handleMouseMoved(pt, in: sz) }

        containerView = container
        panel.contentView = container
    }

    private func mountRootView(in container: NSView) {
        let root = NotchIslandView(
            store: store,
            controller: self,
            onToggleExpand: { [weak self] in self?.toggleExpanded() },
            onCollapseAfterJump: { [weak self] in self?.collapseAfterJump() },
            onPopOutFloating: { [weak self] in self?.onPopOutFloating() },
            onOpenSettings: { [weak self] in self?.onOpenSettings() }
        )
        let hosting = NSHostingView(rootView: root)
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        hostingView = hosting
    }

    private func setExpanded(_ expanded: Bool) {
        guard isExpanded != expanded else { return }
        isExpanded = expanded
        if expanded {
            store.refreshNow()
        }
        guard let screen = targetScreen() else { return }
        let target = targetFrame(on: screen, expanded: expanded)
        panel.hasShadow = false

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = expanded ? 0.26 : 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: expanded ? .easeOut : .easeInEaseOut)
            panel.animator().setFrame(target, display: true)
        }
    }

    private func handleMouseEntered() {
        isMouseInside = true
        hoverCloseWork?.cancel()
        guard store.hoverToExpand, !isExpanded else { return }
        hoverOpenWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isMouseInside else { return }
            self.setExpanded(true)
        }
        hoverOpenWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16, execute: work)
    }

    private func handleMouseExited() {
        isMouseInside = false
        if lookModel.offset != .zero {
            lookModel.offset = .zero
        }
        hoverOpenWork?.cancel()
        guard isExpanded else { return }
        hoverCloseWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isMouseInside else { return }
            self.isPinnedOpen = false
            self.setExpanded(false)
        }
        hoverCloseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.36, execute: work)
    }

    private func handleMouseMoved(_ pt: CGPoint, in size: CGSize) {
        guard size.width > 10, size.height > 10 else { return }
        let anchorX: CGFloat = isExpanded ? 39 : 26
        let anchorY: CGFloat = isExpanded ? (size.height - 56) : (size.height * 0.5)
        let dx = max(-1, min(1, (pt.x - anchorX) / 140.0))
        let dy = max(-1, min(1, (anchorY - pt.y) / 120.0))
        let next = CGSize(width: dx, height: dy)
        if abs(next.width - lookModel.offset.width) > 0.06 || abs(next.height - lookModel.offset.height) > 0.06 {
            lookModel.offset = next
        }
    }

    // MARK: - Screen & Notch Geometry

    static func screenKey(for screen: NSScreen) -> String {
        if let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            return "display:\(num.uint32Value)"
        }
        return screen.localizedName
    }

    static func screenChoices() -> [(id: String, label: String)] {
        let screens = NSScreen.screens
        var nameCounts: [String: Int] = [:]
        for s in screens { nameCounts[s.localizedName, default: 0] += 1 }
        var seen: [String: Int] = [:]
        return screens.map { s in
            let id = screenKey(for: s)
            if (nameCounts[s.localizedName] ?? 0) > 1 {
                let idx = (seen[s.localizedName] ?? 0) + 1
                seen[s.localizedName] = idx
                return (id: id, label: "\(s.localizedName) (\(idx))")
            }
            return (id: id, label: s.localizedName)
        }
    }

    private func targetScreen() -> NSScreen? {
        let screens = NSScreen.screens
        if store.selectedScreenName != "auto" {
            if let byId = screens.first(where: { Self.screenKey(for: $0) == store.selectedScreenName }) {
                return byId
            }
            // Backward compatibility for saved localizedName preference
            if let byName = screens.first(where: { $0.localizedName == store.selectedScreenName }) {
                return byName
            }
        }
        // Prefer MacBook built-in notch screen if present
        if let notchScreen = screens.first(where: { $0.auxiliaryTopLeftArea != nil && $0.auxiliaryTopRightArea != nil }) {
            return notchScreen
        }
        return NSScreen.main ?? screens.first
    }

    private func detectNotch(on screen: NSScreen) {
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            let gap = right.minX - left.maxX
            if gap > 60 {
                hasHardwareNotch = true
                notchWidth = gap
                notchLeftOffsetFromMid = left.maxX - screen.frame.midX
                let topInset = screen.safeAreaInsets.top
                let menuH = screen.frame.maxY - screen.visibleFrame.maxY
                notchHeight = topInset > 0 ? topInset : max(30, min(42, menuH > 0 ? menuH : 32))
                return
            }
        }
        hasHardwareNotch = false
        notchWidth = 180
        notchHeight = 34
        notchLeftOffsetFromMid = -90
    }

    private func targetFrame(on screen: NSScreen, expanded: Bool) -> NSRect {
        let sf = screen.frame
        if expanded {
            let w = hasHardwareNotch ? expandedWidth : (expandedWidth - 32)
            let h = hasHardwareNotch ? expandedHeight : (expandedHeight - 24)
            let x = sf.midX - w * 0.5
            let y = hasHardwareNotch ? (sf.maxY - h) : (sf.maxY - h - 6)
            return NSRect(x: round(x), y: round(y), width: w, height: h)
        } else {
            if hasHardwareNotch {
                let earR: CGFloat = 10
                let leftW = store.collapsedLeftEarWidth
                let rightW = store.collapsedRightEarWidth
                let notchLeftX = sf.midX + notchLeftOffsetFromMid
                let w = earR + leftW + notchWidth + rightW + earR
                let h = notchHeight
                let x = notchLeftX - earR - leftW
                let y = sf.maxY - h
                return NSRect(x: round(x), y: round(y), width: round(w), height: h)
            } else {
                let w: CGFloat = store.collapsedActiveKinds.isEmpty ? 216 : 246
                let h: CGFloat = 34
                let x = sf.midX - w * 0.5
                let y = sf.maxY - h - 6
                return NSRect(x: round(x), y: round(y), width: w, height: h)
            }
        }
    }
}
