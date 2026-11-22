import SwiftUI

/// Organic MacBook hardware-notch silhouette with true concave top bezel shoulders
/// curving smoothly outward into the top display bezel (just like Apple's physical notch & Coucou).
struct NotchIslandShape: Shape {
    var topEarRadius: CGFloat     // concave shoulder radius kissing the top screen bezel
    var bottomRadius: CGFloat     // convex rounded bottom corners

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topEarRadius, bottomRadius) }
        set {
            topEarRadius = newValue.first
            bottomRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        let er = max(0, min(topEarRadius, w * 0.2, h * 0.45))
        let br = max(0, min(bottomRadius, (w - er * 2) * 0.5, h - er))

        var p = Path()
        // Flush across the very top bezel edge
        p.move(to: CGPoint(x: 0, y: 0))
        p.addLine(to: CGPoint(x: w, y: 0))

        // Top-right concave shoulder curving smoothly from bezel down into right wall
        if er > 0 {
            p.addQuadCurve(
                to: CGPoint(x: w - er, y: er),
                control: CGPoint(x: w - er, y: 0)
            )
        }

        // Right edge down to bottom-right convex corner
        p.addLine(to: CGPoint(x: w - er, y: h - br))
        p.addArc(
            center: CGPoint(x: w - er - br, y: h - br),
            radius: br,
            startAngle: .degrees(0),
            endAngle: .degrees(90),
            clockwise: false
        )

        // Bottom edge across to bottom-left convex corner
        p.addLine(to: CGPoint(x: er + br, y: h))
        p.addArc(
            center: CGPoint(x: er + br, y: h - br),
            radius: br,
            startAngle: .degrees(90),
            endAngle: .degrees(180),
            clockwise: false
        )

        // Left edge up to top-left concave shoulder
        p.addLine(to: CGPoint(x: er, y: er))
        if er > 0 {
            p.addQuadCurve(
                to: CGPoint(x: 0, y: 0),
                control: CGPoint(x: er, y: 0)
            )
        }

        p.closeSubpath()
        return p
    }
}

struct NotchIslandView: View {
    @ObservedObject var store: MonitorStore
    @ObservedObject var controller: NotchWindowController
    let onToggleExpand: () -> Void
    let onCollapseAfterJump: () -> Void
    let onPopOutFloating: () -> Void
    let onOpenSettings: () -> Void

    private var isExpanded: Bool { controller.isExpanded }
    private var hasHardwareNotch: Bool { controller.hasHardwareNotch }
    private var hardwareNotchWidth: CGFloat { controller.notchWidth }
    private var hardwareNotchHeight: CGFloat { controller.notchHeight }
    private var lookOffset: CGSize { controller.lookOffset }

    private var earRadius: CGFloat {
        guard hasHardwareNotch else { return 0 }
        return isExpanded ? 16 : 10
    }

    private var bottomRadius: CGFloat {
        isExpanded ? 26 : 13
    }

    var body: some View {
        ZStack(alignment: .top) {
            if hasHardwareNotch {
                hardwareNotchBody
            } else {
                floatingPillBody
            }
        }
        .animation(.spring(response: 0.30, dampingFraction: 0.84), value: isExpanded)
    }

    // MARK: - Hardware MacBook Notch Mode (Seamless Black Top Cap + True Liquid Glass Body!)

    private var hardwareNotchBody: some View {
        let shape = NotchIslandShape(topEarRadius: earRadius, bottomRadius: bottomRadius)
        return ZStack(alignment: .top) {
            if isExpanded {
                // Smoked frosted dark glass: seamless pitch-black notch cap at top + crisp readable dark glass body
                ZStack(alignment: .top) {
                    LiquidGlassBackdrop(material: .hudWindow)

                    LinearGradient(
                        stops: [
                            .init(color: Color.black, location: 0.0),
                            .init(color: Color.black, location: 0.08),
                            .init(color: LumiPalette.shellTop.opacity(0.90), location: 0.20),
                            .init(color: LumiPalette.shellBottom.opacity(0.92), location: 1.0)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
                .clipShape(shape)
                .overlay(
                    shape.stroke(
                        LinearGradient(
                            stops: [
                                .init(color: Color.clear, location: 0.0),
                                .init(color: Color.clear, location: 0.10),
                                .init(color: LumiPalette.champagneRim.opacity(0.16), location: 0.45),
                                .init(color: LumiPalette.emberGold.opacity(0.15), location: 1.0)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1.1
                    )
                    .clipShape(shape)
                )

                VStack(spacing: 0) {
                    Spacer()
                        .frame(height: max(32, hardwareNotchHeight))

                    StudioBentoBoardView(
                        store: store,
                        inNotch: true,
                        lookOffset: lookOffset,
                        onSwitchMode: onPopOutFloating,
                        onOpenSettings: onOpenSettings,
                        onHide: nil,
                        onDidJump: onCollapseAfterJump
                    )
                    .padding(.horizontal, earRadius)
                }
                .clipShape(shape)
                .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
            } else {
                // Collapsed ears hugging left & right of the physical camera notch (Scheme 1)
                shape
                    .fill(Color.black)

                HStack(spacing: 0) {
                    Spacer().frame(width: earRadius)

                    collapsedLeftEar
                        .frame(width: store.collapsedLeftEarWidth, height: hardwareNotchHeight)

                    Spacer()
                        .frame(width: hardwareNotchWidth)

                    compactStatusBadge
                        .frame(width: store.collapsedRightEarWidth, height: hardwareNotchHeight)

                    Spacer().frame(width: earRadius)
                }
                .frame(height: hardwareNotchHeight)
                .contentShape(Rectangle())
                .onTapGesture { onToggleExpand() }
                .transition(.opacity)
            }
        }
    }

    // MARK: - Non-Notch External Display Mode (Pure Liquid Glass Dynamic Pill)

    private var floatingPillBody: some View {
        let shape = RoundedRectangle(cornerRadius: isExpanded ? 24 : 17, style: .continuous)
        return ZStack(alignment: .top) {
            ZStack {
                LiquidGlassBackdrop(material: .hudWindow)
                LumiPalette.shellTop.opacity(isExpanded ? 0.90 : 0.86)
            }
            .clipShape(shape)
            .overlay(
                shape.strokeBorder(
                    LinearGradient(
                        colors: [LumiPalette.champagneRim.opacity(0.20), Color.white.opacity(0.05), LumiPalette.emberGold.opacity(0.12)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.85
                )
            )

            if isExpanded {
                StudioBentoBoardView(
                    store: store,
                    inNotch: true,
                    lookOffset: lookOffset,
                    onSwitchMode: onPopOutFloating,
                    onOpenSettings: onOpenSettings,
                    onHide: nil,
                    onDidJump: onCollapseAfterJump
                )
                .padding(.top, 6)
                .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
            } else {
                HStack(spacing: 7) {
                    LumiMascotView(
                        mood: store.mascotMood,
                        theme: store.mascotTheme,
                        size: 24,
                        lookOffset: lookOffset,
                        isCompact: true,
                        isActiveSurface: false
                    )
                    if !store.collapsedActiveKinds.isEmpty {
                        stackedMiniAppIcons(kinds: store.collapsedActiveKinds)
                    }
                    Text(compactHeadline)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundColor(.white.opacity(0.94))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    compactStatusBadge
                }
                .padding(.horizontal, 12)
                .frame(height: 34)
                .contentShape(Rectangle())
                .onTapGesture { onToggleExpand() }
                .transition(.opacity)
            }
        }
    }

    private var compactHeadline: String {
        store.l10n.compactHeadline(
            running: store.totalRunningCount,
            unread: store.totalUnreadCount,
            needsInput: store.totalNeedsInputCount
        )
    }

    private var collapsedLeftEar: some View {
        let activeKinds = store.collapsedActiveKinds
        return HStack(spacing: 4) {
            LumiMascotView(
                mood: store.mascotMood,
                theme: store.mascotTheme,
                size: min(24, max(20, hardwareNotchHeight - 8)),
                lookOffset: lookOffset,
                isCompact: true,
                isActiveSurface: false
            )
            if !activeKinds.isEmpty {
                stackedMiniAppIcons(kinds: activeKinds)
            }
        }
    }

    private func stackedMiniAppIcons(kinds: [AgentKind]) -> some View {
        ZStack(alignment: .leading) {
            ForEach(Array(kinds.enumerated()), id: \.offset) { idx, kind in
                NativeAgentIconView(kind: kind, visualSize: 15.5)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .stroke(Color.black, lineWidth: idx > 0 ? 1.3 : 0)
                    )
                    .offset(x: CGFloat(idx) * 10.0)
            }
        }
        .frame(width: kinds.count >= 2 ? 26 : 16, height: 18, alignment: .leading)
    }

    private var compactStatusBadge: some View {
        HStack(spacing: 5) {
            if store.totalNeedsInputCount > 0 {
                HStack(spacing: 3) {
                    Image(systemName: "questionmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundColor(LumiPalette.needsAmber)
                    Text(store.isEnglish ? "Reply" : "确认")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(LumiPalette.emberGold)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2.5)
                .background(Capsule().fill(LumiPalette.needsAmber.opacity(0.18)))
            } else if let solo = store.singleRunningSession {
                // Single active task -> show live tabular MM:SS elapsed timer directly!
                let elapsed = max(0, store.lastRefreshAt.timeIntervalSince(solo.startedAt ?? solo.updatedAt))
                HStack(spacing: 4) {
                    TelemetryPulseBars(active: true, color: LumiPalette.emberGold)
                    Text(ProjectNameHelper.formatMMSS(elapsed))
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        .monospacedDigit()
                        .foregroundColor(LumiPalette.warmPrimary.opacity(0.95))
                }
            } else {
                if store.totalRunningCount > 0 {
                    HStack(spacing: 3) {
                        TelemetryPulseBars(active: true, color: LumiPalette.runningIvory)
                        Text("\(store.totalRunningCount)")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundColor(LumiPalette.warmPrimary)
                    }
                }
                if store.totalUnreadCount > 0 {
                    HStack(spacing: 2) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 9.5))
                            .foregroundColor(LumiPalette.emberOrange)
                        Text("\(store.totalUnreadCount)")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundColor(LumiPalette.emberGold)
                    }
                }
                if store.totalRunningCount == 0 && store.totalUnreadCount == 0 {
                    if store.isDNDActive {
                        Image(systemName: "moon.zzz.fill")
                            .font(.system(size: 9.5))
                            .foregroundColor(LumiPalette.warmSecondary)
                    } else {
                        Circle()
                            .fill(Color.white.opacity(0.18))
                            .frame(width: 4.5, height: 4.5)
                    }
                }
            }
        }
    }
}
