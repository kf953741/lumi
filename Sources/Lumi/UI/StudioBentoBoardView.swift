import AppKit
import SwiftUI

/// Balanced smoked frosted glass backdrop: soft native behind-window blur
/// with rich obsidian tint so white typography stays razor-sharp even over bright webpages.
struct LiquidGlassBackdrop: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: .darkAqua)
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = .behindWindow
        nsView.appearance = NSAppearance(named: .darkAqua)
    }
}

enum BentoListTab: String, CaseIterable, Identifiable {
    case all = "全部"
    case running = "执行中"
    case unread = "待查看"

    var id: String { rawValue }
}

/// Apple Liquid Glass × Studio Bento board shared by Dynamic Notch Expanded
/// and the Detachable Floating Desktop Window.
struct StudioBentoBoardView: View {
    @ObservedObject var store: MonitorStore
    let inNotch: Bool
    let lookOffset: CGSize
    let onSwitchMode: () -> Void
    let onOpenSettings: () -> Void
    let onHide: (() -> Void)?
    var onDidJump: (() -> Void)? = nil

    @State private var activeTab: BentoListTab = .all
    @State private var showRecent = false

    // Rich tactile smoked Bento glass fills (subtle translucency + WCAG AAA text contrast)
    private var glassCardFill: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 0.125, green: 0.130, blue: 0.165).opacity(0.84),
                Color(red: 0.095, green: 0.100, blue: 0.130).opacity(0.88)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    var body: some View {
        VStack(spacing: 9) {
            // MARK: - Top Bento Split (Liquid Glass Mascot Stage + Telemetry Tiles)
            HStack(spacing: 9) {
                mascotStageModule
                    .frame(width: 146, height: 118)

                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        telemetryTile(
                            number: store.totalRunningCount,
                            label: "执行中",
                            accent: Color(red: 0.28, green: 0.90, blue: 0.62),
                            isSelected: activeTab == .running
                        ) {
                            withAnimation(.easeInOut(duration: 0.16)) {
                                activeTab = (activeTab == .running) ? .all : .running
                            }
                        }

                        telemetryTile(
                            number: store.totalUnreadCount,
                            label: "待查看",
                            accent: Color(red: 1.0, green: 0.78, blue: 0.30),
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

            // MARK: - Bottom Unified Liquid Glass Task Card
            taskListModule
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
        .padding(.top, inNotch ? 2 : 12)
    }

    // MARK: - Left Liquid Glass Mascot Stage

    private var mascotStageModule: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.15, green: 0.135, blue: 0.22).opacity(0.90),
                            Color(red: 0.095, green: 0.098, blue: 0.135).opacity(0.92)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RadialGradient(
                        colors: [store.mascotTheme.eyeGlow.opacity(0.20), Color.clear],
                        center: .center,
                        startRadius: 4,
                        endRadius: 68
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
                )
                .overlay(stageStars)
                .overlay(liquidGlassRim(cornerRadius: 17, topIntensity: 0.30))

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
                .help("点 Lumi 互动（连戳 4 下会晕哦）")

                Text(shortStageCaption)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundColor(Color.white.opacity(0.68))
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 9)
            }
        }
    }

    private var stageStars: some View {
        GeometryReader { geo in
            ZStack {
                Circle().fill(Color.white.opacity(0.40)).frame(width: 2.0, height: 2.0)
                    .position(x: geo.size.width * 0.18, y: geo.size.height * 0.22)
                Circle().fill(store.mascotTheme.eyeGlow.opacity(0.55)).frame(width: 2.4, height: 2.4)
                    .position(x: geo.size.width * 0.84, y: geo.size.height * 0.20)
                Circle().fill(Color.white.opacity(0.26)).frame(width: 1.8, height: 1.8)
                    .position(x: geo.size.width * 0.78, y: geo.size.height * 0.64)
            }
        }
        .allowsHitTesting(false)
    }

    private var shortStageCaption: String {
        switch store.mascotMood {
        case .dizzy: return "转晕啦 @ @"
        case .poked: return "嘿嘿在盯盘~"
        case .celebrating: return "有对话完工啦!"
        case .error: return "发现执行出错"
        case .working: return "Lumi 盯盘中"
        case .waitingUnread: return "等你查看哟"
        case .sleeping: return "全部空闲 · Zzz"
        }
    }

    // MARK: - Translucent Big-Number Telemetry Tile

    private func telemetryTile(
        number: Int,
        label: String,
        accent: Color,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                Text(String(format: "%02d", number))
                    .font(.system(size: 27, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(number > 0 ? (label == "待查看" ? accent : Color.white) : Color.white.opacity(0.28))
                    .lineLimit(1)

                HStack(spacing: 5) {
                    Circle()
                        .fill(number > 0 ? accent : Color.white.opacity(0.22))
                        .frame(width: 6, height: 6)
                    Text(label)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Color.white.opacity(0.68))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(.horizontal, 13)
            .padding(.vertical, 10)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(glassCardFill)
                    if isSelected {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(accent.opacity(0.14))
                    }
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(
                        isSelected
                            ? LinearGradient(colors: [accent.opacity(0.65), accent.opacity(0.20)], startPoint: .topLeading, endPoint: .bottomTrailing)
                            : liquidGlassGradient(topIntensity: 0.26),
                        lineWidth: isSelected ? 1.0 : 0.7
                    )
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Slim Glass Control Strip

    private var controlStripModule: some View {
        HStack(spacing: 5) {
            Button(action: onSwitchMode) {
                HStack(spacing: 5) {
                    Image(systemName: inNotch ? "pip.exit" : "macbook")
                        .font(.system(size: 10.5, weight: .semibold))
                    Text(inNotch ? "桌面模式" : "回到刘海")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundColor(Color.white.opacity(0.90))
                .padding(.horizontal, 9)
                .frame(height: 24)
                .background(
                    Capsule()
                        .fill(Color.white.opacity(0.10))
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5))
                )
            }
            .buttonStyle(.plain)
            .help(inNotch ? "切换为可拖动的桌面悬浮看板" : "收回 MacBook 刘海灵动岛")

            Spacer(minLength: 2)

            if !inNotch {
                stripIconButton(
                    icon: store.alwaysOnTop ? "pin.fill" : "pin",
                    active: store.alwaysOnTop,
                    help: store.alwaysOnTop ? "已置顶（跨桌面跟随）" : "置顶窗口"
                ) { store.alwaysOnTop.toggle() }
            }

            stripIconButton(
                icon: store.soundEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill",
                active: store.soundEnabled,
                help: store.soundEnabled ? "完成提示音已开" : "完成提示音已关"
            ) { store.soundEnabled.toggle() }

            stripIconButton(
                icon: "gearshape.fill",
                active: false,
                help: "打开 Lumi 设置"
            ) { onOpenSettings() }

            if let onHide {
                stripIconButton(
                    icon: "xmark",
                    active: false,
                    help: "收起到菜单栏"
                ) { onHide() }
            }
        }
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(glassCardFill))
        .overlay(liquidGlassRim(cornerRadius: 12, topIntensity: 0.24))
    }

    private func stripIconButton(icon: String, active: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(active ? store.mascotTheme.eyeGlow : Color.white.opacity(0.68))
                .frame(width: 24, height: 22)
                .background(
                    Circle()
                        .fill(active ? Color.white.opacity(0.14) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: - Bottom Unified Liquid Glass Task List

    private var taskListModule: some View {
        VStack(spacing: 0) {
            // Segmented Glass Tabs + Compact Platform Filter + Mark All Read
            HStack(spacing: 6) {
                HStack(spacing: 2) {
                    ForEach(BentoListTab.allCases) { tab in
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) { activeTab = tab }
                        } label: {
                            HStack(spacing: 3.5) {
                                Text(tab.rawValue)
                                    .font(.system(size: 11, weight: activeTab == tab ? .semibold : .medium))
                                if tab == .unread && store.unreadCompletedSessions.count > 0 {
                                    Text("\(store.unreadCompletedSessions.count)")
                                        .font(.system(size: 9.5, weight: .bold, design: .rounded))
                                        .foregroundColor(Color(red: 1.0, green: 0.80, blue: 0.30))
                                }
                            }
                            .foregroundColor(activeTab == tab ? Color.white : Color.white.opacity(0.56))
                            .padding(.horizontal, 9.5)
                            .padding(.vertical, 4.5)
                            .background(
                                Capsule()
                                    .fill(activeTab == tab ? Color.white.opacity(0.16) : Color.clear)
                                    .overlay(
                                        Capsule().strokeBorder(
                                            activeTab == tab ? Color.white.opacity(0.22) : Color.clear,
                                            lineWidth: 0.5
                                        )
                                    )
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(2)
                .background(Capsule().fill(Color.black.opacity(0.20)))

                Spacer(minLength: 4)

                Menu {
                    ForEach(AgentFilter.allCases) { f in
                        Button {
                            store.selectedFilter = f
                        } label: {
                            HStack {
                                Text(f.rawValue)
                                if store.selectedFilter == f { Image(systemName: "checkmark") }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 3) {
                        Text(store.selectedFilter == .all ? "全平台" : store.selectedFilter.rawValue)
                            .font(.system(size: 10.5, weight: .medium))
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 8.5, weight: .semibold))
                    }
                    .foregroundColor(Color.white.opacity(0.66))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(Color.white.opacity(0.08))
                            .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5))
                    )
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                if !store.unreadCompletedSessions.isEmpty {
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) { store.markAllRead() }
                    } label: {
                        Text("全部已读")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundColor(Color(red: 0.38, green: 0.92, blue: 0.66))
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 4)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)

            Rectangle()
                .fill(Color.white.opacity(0.10))
                .frame(height: 0.5)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    let showRunning = (activeTab == .all || activeTab == .running)
                    let showUnread = (activeTab == .all || activeTab == .unread)

                    if showRunning {
                        let running = store.runningSessions
                        if activeTab == .all && !running.isEmpty {
                            subtleGroupHeader("正在执行")
                        }
                        if running.isEmpty && activeTab == .running {
                            emptyState("当前没有正在执行的对话")
                        } else {
                            ForEach(Array(running.enumerated()), id: \.element.id) { idx, s in
                                BentoSessionRow(
                                    session: s,
                                    nowRef: store.lastRefreshAt,
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
                            subtleGroupHeader("待查看 · 点击跳转即已读")
                                .padding(.top, store.runningSessions.isEmpty ? 0 : 6)
                        }
                        if unread.isEmpty && activeTab == .unread {
                            emptyState("暂无未读的独立对话完成项")
                        } else {
                            ForEach(unread) { s in
                                BentoSessionRow(
                                    session: s,
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

                    if activeTab == .all && store.runningSessions.isEmpty && store.unreadCompletedSessions.isEmpty {
                        emptyState("所有对话都已处理完毕，Lumi 正在打盹…")
                    }

                    if activeTab == .all && !store.recentReadSessions.isEmpty {
                        Button {
                            withAnimation(.easeInOut(duration: 0.16)) { showRecent.toggle() }
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: showRecent ? "chevron.down" : "chevron.right")
                                    .font(.system(size: 8.5, weight: .semibold))
                                Text("最近已读 (\(store.recentReadSessions.count))")
                                    .font(.system(size: 10.5, weight: .medium))
                                Spacer()
                            }
                            .foregroundColor(Color.white.opacity(0.42))
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
                        .foregroundColor(Color(red: 1.0, green: 0.76, blue: 0.26))
                    Text(hint)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundColor(Color.white.opacity(0.90))
                        .lineLimit(2)
                    Spacer(minLength: 4)
                    Button("前往授权") {
                        store.dismissJumpHint()
                        store.requestAccessibilityPermission()
                    }
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.black)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color(red: 1.0, green: 0.78, blue: 0.30)))
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
                .background(Color(red: 1.0, green: 0.68, blue: 0.18).opacity(0.16))
                .overlay(alignment: .top) {
                    Rectangle().fill(Color(red: 1.0, green: 0.76, blue: 0.26).opacity(0.32)).frame(height: 0.5)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 17, style: .continuous).fill(glassCardFill))
        .overlay(liquidGlassRim(cornerRadius: 17, topIntensity: 0.26))
    }

    private func subtleGroupHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(Color.white.opacity(0.44))
            .padding(.horizontal, 12)
            .padding(.top, 5)
            .padding(.bottom, 2)
    }

    private var rowDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.08))
            .frame(height: 0.5)
            .padding(.leading, 36)
            .padding(.trailing, 12)
    }

    private func emptyState(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundColor(Color.white.opacity(0.45))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
    }

    private func liquidGlassGradient(topIntensity: Double) -> LinearGradient {
        LinearGradient(
            colors: [
                Color.white.opacity(topIntensity),
                Color.white.opacity(topIntensity * 0.35),
                Color.white.opacity(0.04),
                Color.white.opacity(topIntensity * 0.45)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private func liquidGlassRim(cornerRadius: CGFloat, topIntensity: Double) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .strokeBorder(liquidGlassGradient(topIntensity: topIntensity), lineWidth: 0.75)
    }
}
