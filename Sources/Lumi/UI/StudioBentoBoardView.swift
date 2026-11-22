import AppKit
import SwiftUI

/// Balanced frosted glass backdrop supporting both Warm Charcoal (dark)
/// and Morning Oat Cream (light) floating surfaces.
struct LiquidGlassBackdrop: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var isLight: Bool = false

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: isLight ? .aqua : .darkAqua)
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = .behindWindow
        nsView.appearance = NSAppearance(named: isLight ? .aqua : .darkAqua)
    }
}

enum BentoListTab: String, CaseIterable, Identifiable {
    case all
    case running
    case unread

    var id: String { rawValue }

    func label(_ l10n: L10n) -> String {
        switch self {
        case .all:     return l10n.tabAll
        case .running: return l10n.tabRunning
        case .unread:  return l10n.tabUnread
        }
    }
}

/// Studio Bento board shared by Dynamic Notch Expanded (Warm Charcoal)
/// and the Detachable Floating Desktop Window (Warm Charcoal or Morning Oat Light).
struct StudioBentoBoardView: View {
    @ObservedObject var store: MonitorStore
    let inNotch: Bool
    var surface: BoardSurfaceTheme = .charcoal
    let lookOffset: CGSize
    let onSwitchMode: () -> Void
    let onOpenSettings: () -> Void
    let onHide: (() -> Void)?
    var onDidJump: (() -> Void)? = nil

    @State private var activeTab: BentoListTab = .all
    @State private var showRecent = false

    private var t: L10n { store.l10n }

    private var glassCardFill: LinearGradient {
        LinearGradient(
            colors: [surface.cardTop, surface.cardBottom],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    var body: some View {
        VStack(spacing: 9) {
            // MARK: - Top Bento Split (Warm Hearth Mascot Stage + Telemetry Tiles)
            HStack(spacing: 9) {
                mascotStageModule
                    .frame(width: 146, height: 118)

                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        telemetryTile(
                            number: store.totalRunningCount + store.totalNeedsInputCount,
                            label: t.tabRunning,
                            accent: surface.runningTone,
                            isRunningTile: true,
                            isSelected: activeTab == .running
                        ) {
                            withAnimation(.easeInOut(duration: 0.16)) {
                                activeTab = (activeTab == .running) ? .all : .running
                            }
                        }

                        telemetryTile(
                            number: store.totalUnreadCount,
                            label: t.tabUnread,
                            accent: surface.emberHighlight,
                            isRunningTile: false,
                            isSelected: activeTab == .unread
                        ) {
                            withAnimation(.easeInOut(duration: 0.16)) {
                                activeTab = (activeTab == .unread) ? .all : .unread
                            }
                        }
                    }
                    .frame(height: 76)

                    controlStripModule
                        .frame(height: 34)
                }
            }

            // MARK: - Bottom Unified Task Card
            taskListModule
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
        .padding(.top, inNotch ? 2 : 12)
    }

    // MARK: - Left Warm Hearth Mascot Stage

    private var stageGlowMultiplier: Double {
        switch store.mascotMood {
        case .celebrating, .needsInput: return 1.38
        case .sleeping:                 return 0.50
        default:                        return 1.0
        }
    }

    private var mascotStageModule: some View {
        let highlightRim = (store.mascotMood == .celebrating || store.mascotMood == .needsInput)
        return ZStack {
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [surface.stageTop, surface.stageBottom],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RadialGradient(
                        colors: surface.isLight
                            ? [Color.white.opacity(0.62), Color.clear]
                            : [
                                store.mascotTheme.bodyTop.opacity(0.24 * stageGlowMultiplier),
                                store.mascotTheme.bodyBottom.opacity(0.08 * stageGlowMultiplier),
                                Color.clear
                            ],
                        center: UnitPoint(x: 0.5, y: surface.isLight ? 0.40 : 0.48),
                        startRadius: 4,
                        endRadius: 72
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
                )
                .overlay(
                    Ellipse()
                        .fill(
                            surface.isLight
                                ? RadialGradient(colors: [Color(red: 0.70, green: 0.44, blue: 0.26).opacity(0.16), Color.clear], center: .center, startRadius: 2, endRadius: 34)
                                : RadialGradient(colors: [store.mascotTheme.eyeGlow.opacity(0.18 * stageGlowMultiplier), Color.clear], center: .center, startRadius: 2, endRadius: 40)
                        )
                        .frame(width: surface.isLight ? 56 : 82, height: surface.isLight ? 10 : 16)
                        .offset(y: 23)
                )
                .overlay(
                    highlightRim
                        ? AnyView(
                            RoundedRectangle(cornerRadius: 17, style: .continuous)
                                .strokeBorder(
                                    LinearGradient(
                                        colors: [
                                            surface.emberAccent.opacity(0.72),
                                            surface.emberHighlight.opacity(0.35),
                                            surface.emberAccent.opacity(0.55)
                                        ],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ),
                                    lineWidth: 1.15
                                )
                        )
                        : AnyView(surfaceRim(cornerRadius: 17))
                )

            VStack(spacing: 3) {
                Spacer(minLength: 4)
                LumiMascotView(
                    mood: store.mascotMood,
                    theme: store.mascotTheme,
                    size: 66,
                    lookOffset: lookOffset,
                    isCompact: false,
                    isActiveSurface: true,
                    onPoke: { store.pokeMascot() }
                )
                .help(t.helpPokeMascot)

                Text(t.stageCaption(for: store.mascotMood))
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundColor(surface.isLight ? Color(red: 0.42, green: 0.31, blue: 0.24) : surface.secondaryText)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 9)
            }
        }
        .shadow(color: surface.isLight ? Color(red: 0.50, green: 0.38, blue: 0.26).opacity(0.07) : .clear, radius: 5, y: 2)
    }

    // MARK: - Big-Number Telemetry Tile

    private func telemetryTile(
        number: Int,
        label: String,
        accent: Color,
        isRunningTile: Bool,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                Text(String(format: "%02d", number))
                    .font(.system(size: 27, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(
                        number > 0
                            ? (isRunningTile ? surface.primaryText : accent)
                            : surface.subtleText.opacity(0.65)
                    )
                    .lineLimit(1)

                HStack(spacing: 5) {
                    if isRunningTile {
                        TelemetryPulseBars(active: number > 0, color: surface.runningTone)
                    } else {
                        Circle()
                            .fill(number > 0 ? surface.emberAccent : surface.subtleText.opacity(0.35))
                            .frame(width: 6, height: 6)
                    }
                    Text(label)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(surface.secondaryText)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(.horizontal, 13)
            .padding(.vertical, 10)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(glassCardFill)
                    if !isRunningTile && number > 0 {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(
                                RadialGradient(
                                    colors: [surface.emberAccent.opacity(surface.isLight ? 0.10 : 0.11), Color.clear],
                                    center: .topLeading,
                                    startRadius: 2,
                                    endRadius: 85
                                )
                            )
                    }
                    if isSelected {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill((isRunningTile ? surface.runningTone : surface.emberAccent).opacity(0.13))
                    }
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(
                        isSelected
                            ? LinearGradient(colors: [accent.opacity(0.60), accent.opacity(0.18)], startPoint: .topLeading, endPoint: .bottomTrailing)
                            : LinearGradient(colors: surface.rimColors, startPoint: .topLeading, endPoint: .bottomTrailing),
                        lineWidth: isSelected ? 1.0 : 0.75
                    )
            )
            .shadow(color: surface.isLight ? Color(red: 0.50, green: 0.40, blue: 0.30).opacity(0.06) : .clear, radius: 5, y: 2)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Slim Control Strip

    private var controlStripModule: some View {
        HStack(spacing: 4) {
            Button(action: onSwitchMode) {
                HStack(spacing: 4.5) {
                    Image(systemName: inNotch ? "pip.exit" : "macbook")
                        .font(.system(size: 10.2, weight: .semibold))
                    Text(inNotch ? t.desktopMode : t.dockToNotch)
                        .font(.system(size: 10.8, weight: .medium))
                }
                .foregroundColor(surface.primaryText.opacity(0.92))
                .padding(.horizontal, 8.5)
                .frame(height: 24)
                .background(
                    Capsule()
                        .fill(surface.pillBg)
                        .overlay(Capsule().strokeBorder(surface.divider, lineWidth: 0.5))
                )
            }
            .buttonStyle(.plain)
            .help(inNotch ? t.helpDesktopMode : t.helpDockToNotch)

            Spacer(minLength: 2)

            if store.isDNDActive {
                stripIconButton(
                    icon: "moon.zzz.fill",
                    active: true,
                    help: t.helpDndActive
                ) { store.disableDND() }
            }

            if !inNotch {
                stripIconButton(
                    icon: surface.isLight ? "moon.fill" : "sun.max.fill",
                    active: false,
                    help: t.helpSwitchAppearance
                ) {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        store.floatingAppearance = (store.floatingAppearance == .oatLight) ? .charcoal : .oatLight
                    }
                }

                stripIconButton(
                    icon: store.alwaysOnTop ? "pin.fill" : "pin",
                    active: store.alwaysOnTop,
                    help: store.alwaysOnTop ? t.helpPinnedOn : t.helpPinnedOff
                ) { store.alwaysOnTop.toggle() }
            }

            stripIconButton(
                icon: store.soundEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill",
                active: store.soundEnabled,
                help: store.soundEnabled ? t.helpSoundOn : t.helpSoundOff
            ) { store.soundEnabled.toggle() }

            stripIconButton(
                icon: "gearshape.fill",
                active: false,
                help: t.helpSettings
            ) { onOpenSettings() }

            if let onHide {
                stripIconButton(
                    icon: "xmark",
                    active: false,
                    help: t.helpHide
                ) { onHide() }
            }
        }
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(glassCardFill))
        .overlay(surfaceRim(cornerRadius: 12))
        .shadow(color: surface.isLight ? Color(red: 0.50, green: 0.40, blue: 0.30).opacity(0.05) : .clear, radius: 4, y: 1.5)
    }

    private func stripIconButton(icon: String, active: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 10.8, weight: .medium))
                .foregroundColor(active ? surface.emberHighlight : surface.secondaryText)
                .frame(width: 23, height: 22)
                .background(
                    Circle()
                        .fill(active ? surface.emberAccent.opacity(surface.isLight ? 0.14 : 0.18) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: - Bottom Unified Task List

    private var taskListModule: some View {
        VStack(spacing: 0) {
            // Segmented Tabs + Agent Filter + Mark All Read
            HStack(spacing: 6) {
                HStack(spacing: 2) {
                    ForEach(BentoListTab.allCases) { tab in
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) { activeTab = tab }
                        } label: {
                            HStack(spacing: 3.5) {
                                Text(tab.label(t))
                                    .font(.system(size: 10.8, weight: activeTab == tab ? .semibold : .medium))
                                if tab == .unread && store.unreadCompletedSessions.count > 0 {
                                    Text("\(store.unreadCompletedSessions.count)")
                                        .font(.system(size: 9.2, weight: .bold, design: .rounded))
                                        .foregroundColor(surface.emberHighlight)
                                }
                            }
                            .foregroundColor(activeTab == tab ? surface.primaryText : surface.secondaryText)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4.5)
                            .background(
                                Capsule()
                                    .fill(activeTab == tab ? surface.segmentedActive : Color.clear)
                                    .overlay(
                                        Capsule().strokeBorder(
                                            activeTab == tab ? surface.divider : Color.clear,
                                            lineWidth: 0.5
                                        )
                                    )
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(2)
                .background(Capsule().fill(surface.segmentedTrack))

                Spacer(minLength: 4)

                Menu {
                    ForEach(AgentFilter.allCases) { f in
                        Button {
                            store.selectedFilter = f
                        } label: {
                            HStack {
                                Text(f.label(isEnglish: store.isEnglish))
                                if store.selectedFilter == f { Image(systemName: "checkmark") }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 3) {
                        Text(store.selectedFilter == .all ? t.allAgents : store.selectedFilter.label(isEnglish: store.isEnglish))
                            .font(.system(size: 10.2, weight: .medium))
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 8.2, weight: .semibold))
                    }
                    .foregroundColor(surface.secondaryText)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(surface.pillBg)
                            .overlay(Capsule().strokeBorder(surface.divider, lineWidth: 0.5))
                    )
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                if !store.unreadCompletedSessions.isEmpty {
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) { store.markAllRead() }
                    } label: {
                        Text(t.markAllRead)
                            .font(.system(size: 10.2, weight: .semibold))
                            .foregroundColor(surface.emberHighlight)
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 3)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)

            Rectangle()
                .fill(surface.divider)
                .frame(height: 0.5)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    let showRunning = (activeTab == .all || activeTab == .running)
                    let showUnread = (activeTab == .all || activeTab == .unread)
                    let needsInput = store.needsInputSessions

                    if showRunning && !needsInput.isEmpty {
                        subtleGroupHeader(t.groupNeedsInput, accent: true)
                        ForEach(needsInput) { s in
                            BentoSessionRow(
                                session: s,
                                nowRef: store.lastRefreshAt,
                                surface: surface,
                                l10n: t,
                                onOpen: {
                                    if store.openSession(s) {
                                        onDidJump?()
                                    }
                                },
                                onMarkRead: nil
                            )
                        }
                    }

                    if showRunning {
                        let running = store.runningSessions
                        if activeTab == .all && !running.isEmpty {
                            subtleGroupHeader(t.groupRunning)
                                .padding(.top, needsInput.isEmpty ? 0 : 6)
                        }
                        if running.isEmpty && needsInput.isEmpty && activeTab == .running {
                            emptyState(t.emptyRunning)
                        } else {
                            ForEach(Array(running.enumerated()), id: \.element.id) { idx, s in
                                BentoSessionRow(
                                    session: s,
                                    nowRef: store.lastRefreshAt,
                                    surface: surface,
                                    l10n: t,
                                    onOpen: {
                                        if store.openSession(s) {
                                            onDidJump?()
                                        }
                                    },
                                    onMarkRead: nil
                                )
                                if idx < running.count - 1 {
                                    rowDivider
                                }
                            }
                        }
                    }

                    if showUnread {
                        let unread = store.unreadCompletedSessions
                        if activeTab == .all && !unread.isEmpty {
                            subtleGroupHeader(t.groupUnread)
                                .padding(.top, (store.runningSessions.isEmpty && needsInput.isEmpty) ? 0 : 6)
                        }
                        if unread.isEmpty && activeTab == .unread {
                            emptyState(t.emptyUnread)
                        } else {
                            ForEach(unread) { s in
                                BentoSessionRow(
                                    session: s,
                                    surface: surface,
                                    l10n: t,
                                    onOpen: {
                                        let jumped = store.openSession(s)
                                        if jumped {
                                            withAnimation(.easeInOut(duration: 0.18)) { store.markRead(s) }
                                            onDidJump?()
                                        }
                                    },
                                    onMarkRead: {
                                        withAnimation(.easeInOut(duration: 0.18)) { store.markRead(s) }
                                    }
                                )
                            }
                        }
                    }

                    if activeTab == .all && needsInput.isEmpty && store.runningSessions.isEmpty && store.unreadCompletedSessions.isEmpty {
                        emptyState(t.emptyAll)
                    }

                    if activeTab == .all && !store.recentReadSessions.isEmpty {
                        Button {
                            withAnimation(.easeInOut(duration: 0.16)) { showRecent.toggle() }
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: showRecent ? "chevron.down" : "chevron.right")
                                    .font(.system(size: 8.5, weight: .semibold))
                                Text(t.recentlyRead(store.recentReadSessions.count))
                                    .font(.system(size: 10.5, weight: .medium))
                                Spacer()
                            }
                            .foregroundColor(surface.subtleText)
                            .padding(.horizontal, 12)
                            .padding(.top, 10)
                            .padding(.bottom, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        if showRecent {
                            ForEach(store.recentReadSessions) { s in
                                BentoSessionRow(
                                    session: s,
                                    compact: true,
                                    surface: surface,
                                    l10n: t,
                                    onOpen: {
                                        if store.openSession(s) {
                                            onDidJump?()
                                        }
                                    },
                                    onMarkRead: nil
                                )
                            }
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 6)
            }

            if let hint = store.jumpHintMessage {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(surface.emberHighlight)
                    Text(hint)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundColor(surface.primaryText.opacity(0.90))
                        .lineLimit(2)
                    Spacer(minLength: 4)
                    Button(t.grantAccessibility) {
                        store.dismissJumpHint()
                        store.requestAccessibilityPermission()
                    }
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(surface.ctaText)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(surface.ctaFill))
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
                .background(surface.emberAccent.opacity(0.14))
                .overlay(alignment: .top) {
                    Rectangle().fill(surface.emberAccent.opacity(0.30)).frame(height: 0.5)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 17, style: .continuous).fill(glassCardFill))
        .overlay(surfaceRim(cornerRadius: 17))
        .shadow(color: surface.isLight ? Color(red: 0.50, green: 0.40, blue: 0.30).opacity(0.06) : .clear, radius: 6, y: 2)
    }

    private func subtleGroupHeader(_ text: String, accent: Bool = false) -> some View {
        Text(text)
            .font(.system(size: 9.8, weight: .semibold))
            .foregroundColor(accent ? surface.emberHighlight : surface.subtleText)
            .padding(.horizontal, 12)
            .padding(.top, 5)
            .padding(.bottom, 2)
    }

    private var rowDivider: some View {
        Rectangle()
            .fill(surface.divider)
            .frame(height: 0.5)
            .padding(.leading, 51)
            .padding(.trailing, 12)
    }

    private func emptyState(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundColor(surface.subtleText)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
    }

    private func surfaceRim(cornerRadius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .strokeBorder(
                LinearGradient(colors: surface.rimColors, startPoint: .topLeading, endPoint: .bottomTrailing),
                lineWidth: 0.75
            )
    }
}
