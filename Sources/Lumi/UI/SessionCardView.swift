import SwiftUI

/// Lightweight isolated 1Hz elapsed timer leaf so running clocks never trigger parent view redraws.
struct LiveElapsedText: View {
    enum Style {
        case duration
        case mmss
    }

    let since: Date
    let style: Style

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0)) { context in
            let elapsed = max(0, context.date.timeIntervalSince(since))
            Text(style == .mmss ? ProjectNameHelper.formatMMSS(elapsed) : ProjectNameHelper.formatDuration(elapsed))
        }
    }
}

/// Isolated mascot gaze wrapper so cursor motion over the notch only re-evaluates LumiMascotView.
struct NotchGazeMascot: View {
    @ObservedObject var lookModel: NotchLookModel
    let mood: MascotMood
    let theme: MascotTheme
    let size: CGFloat
    let isCompact: Bool
    let isActiveSurface: Bool
    var onPoke: (() -> Void)? = nil

    var body: some View {
        LumiMascotView(
            mood: mood,
            theme: theme,
            size: size,
            lookOffset: lookModel.offset,
            isCompact: isCompact,
            isActiveSurface: isActiveSurface,
            onPoke: onPoke
        )
    }
}

/// Refined Studio Bento hairline row — native macOS app icon with Apple Knockout
/// corner status badge (running spinner, Ember unread checkmark, coral error `!`,
/// or amber needs-input `?`), bilingual monochrome metadata, and duration display.
struct BentoSessionRow: View {
    let session: AgentSession
    var compact: Bool = false
    var surface: BoardSurfaceTheme = .charcoal
    var l10n: L10n = L10n(isEnglish: false)
    let onOpen: () -> Void
    let onMarkRead: (() -> Void)?

    @State private var isHovering = false

    private var isUnreadDone: Bool {
        session.isUnread && (session.status == .done || session.status == .error)
    }

    private var isNeedsInput: Bool {
        session.status == .needsInput
    }

    private var rowBackground: Color {
        if isNeedsInput {
            return LumiPalette.needsAmber.opacity(isHovering ? (surface.isLight ? 0.16 : 0.16) : (surface.isLight ? 0.10 : 0.09))
        }
        if isUnreadDone {
            if session.status == .error {
                return LumiPalette.errorCoral.opacity(isHovering ? 0.14 : 0.08)
            }
            return surface.emberAccent.opacity(isHovering ? (surface.isLight ? 0.13 : 0.11) : (surface.isLight ? 0.07 : 0.05))
        }
        return isHovering ? surface.hoverRowFill : Color.clear
    }

    private var rowBorderColor: Color {
        if isNeedsInput {
            return LumiPalette.needsAmber.opacity(isHovering ? 0.45 : 0.24)
        }
        if isUnreadDone && isHovering {
            return session.status == .error
                ? LumiPalette.errorCoral.opacity(0.32)
                : surface.emberAccent.opacity(0.26)
        }
        return Color.clear
    }

    private var toolShortDisplay: String {
        switch session.kind {
        case .antigravity: return "Antigravity"
        case .codex:       return "Codex"
        case .claude:      return "Claude"
        case .t3code:      return "T3 Code"
        case .cursor:      return "Cursor"
        case .gemini:      return "Gemini"
        case .opencode:    return "OpenCode"
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            Button(action: onOpen) {
                HStack(alignment: .center, spacing: 11) {
                    leadingAppIconWithBadge

                    VStack(alignment: .leading, spacing: compact ? 2 : 3.5) {
                        Text(session.title)
                            .font(.system(size: compact ? 11.8 : 12.2, weight: .semibold))
                            .foregroundColor(compact ? surface.secondaryText : surface.primaryText)
                            .lineLimit(1)
                            .truncationMode(.tail)

                        if isNeedsInput {
                            HStack(spacing: 4.5) {
                                Text(toolShortDisplay)
                                    .font(.system(size: 10.2, weight: .semibold))
                                    .foregroundColor(surface.primaryText.opacity(0.76))
                                Text("·")
                                    .font(.system(size: 10.2))
                                    .foregroundColor(surface.subtleText)
                                Text(l10n.project(session.project))
                                    .font(.system(size: 10.2, weight: .medium))
                                    .foregroundColor(surface.secondaryText)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text("·")
                                    .font(.system(size: 10.2))
                                    .foregroundColor(surface.subtleText)
                                Text(l10n.action(session.currentAction.isEmpty ? "等待你的审批或回复" : session.currentAction))
                                    .font(.system(size: 10.2, weight: .semibold))
                                    .foregroundColor(surface.emberHighlight)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                        } else if session.status == .running {
                            HStack(spacing: 4.5) {
                                Text(toolShortDisplay)
                                    .font(.system(size: 10.2, weight: .semibold))
                                    .foregroundColor(surface.primaryText.opacity(0.74))
                                Text("·")
                                    .font(.system(size: 10.2))
                                    .foregroundColor(surface.subtleText)
                                Text(l10n.project(session.project))
                                    .font(.system(size: 10.2, weight: .medium))
                                    .foregroundColor(surface.secondaryText)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                if session.activeSubagents > 0 {
                                    Text("+\(session.activeSubagents)")
                                        .font(.system(size: 8.8, weight: .semibold, design: .rounded))
                                        .foregroundColor(surface.primaryText.opacity(0.76))
                                        .padding(.horizontal, 4.5)
                                        .padding(.vertical, 0.8)
                                        .background(Capsule().fill(surface.pillBg))
                                }
                                Text("·")
                                    .font(.system(size: 10.2))
                                    .foregroundColor(surface.subtleText)
                                Text(l10n.action(session.currentAction))
                                    .font(.system(size: 10.2))
                                    .foregroundColor(surface.primaryText.opacity(0.72))
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                        } else {
                            HStack(spacing: 4.5) {
                                Text(toolShortDisplay)
                                    .font(.system(size: 10.2, weight: .semibold))
                                    .foregroundColor(surface.primaryText.opacity(compact ? 0.56 : 0.74))
                                Text("·")
                                    .font(.system(size: 10.2))
                                    .foregroundColor(surface.subtleText)
                                Text(l10n.project(session.project))
                                    .font(.system(size: 10.2, weight: .medium))
                                    .foregroundColor(compact ? surface.subtleText : surface.secondaryText)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                if session.status == .error {
                                    Text(l10n.errorTag)
                                        .font(.system(size: 10.2, weight: .medium))
                                        .foregroundColor(LumiPalette.errorCoral)
                                }
                            }
                        }
                    }

                    Spacer(minLength: 8)

                    trailingMeta
                }
                .padding(.vertical, compact ? 7.0 : 8.5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isUnreadDone && isHovering, let onMarkRead {
                Button(action: onMarkRead) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundColor(surface.secondaryText)
                        .frame(width: 21, height: 21)
                        .background(Circle().fill(surface.pillBg))
                }
                .buttonStyle(.plain)
                .help(l10n.helpMarkReadOnly)
            }
        }
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(rowBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(rowBorderColor, lineWidth: 0.7)
                )
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.14)) {
                isHovering = hovering
            }
        }
        .help(
            isNeedsInput
                ? l10n.helpJumpNeedsInput(session.kind.displayName)
                : (isUnreadDone
                    ? l10n.helpJumpUnread(session.kind.displayName)
                    : l10n.helpJump(session.kind.displayName))
        )
    }

    // MARK: - Native App Icon + Apple Knockout Corner Badge

    private var leadingAppIconWithBadge: some View {
        let iconSize: CGFloat = compact ? 22 : 27
        let frameSize: CGFloat = compact ? 24 : 30

        return ZStack {
            NativeAgentIconView(kind: session.kind, visualSize: iconSize, dimmed: compact)

            if isNeedsInput {
                ZStack {
                    Circle().fill(surface.knockoutBg).frame(width: 14.5, height: 14.5)
                    Circle().fill(LumiPalette.needsAmber).frame(width: 11, height: 11)
                    Text("?")
                        .font(.system(size: 7.8, weight: .black, design: .rounded))
                        .foregroundColor(LumiPalette.darkInk)
                }
                .offset(x: 10.5, y: 10.5)
            } else if session.status == .running {
                KnockoutRunningSpinner(
                    accent: surface.emberHighlight,
                    knockoutColor: surface.knockoutBg
                )
                .offset(x: 10.5, y: 10.5)
            } else if isUnreadDone {
                ZStack {
                    Circle()
                        .fill(surface.knockoutBg)
                        .frame(width: 14, height: 14)

                    if session.status == .error {
                        Circle()
                            .fill(LumiPalette.errorCoral)
                            .frame(width: 10.5, height: 10.5)
                        Text("!")
                            .font(.system(size: 7.5, weight: .black, design: .rounded))
                            .foregroundColor(LumiPalette.darkInk)
                    } else {
                        Circle()
                            .fill(surface.emberAccent)
                            .frame(width: 10.5, height: 10.5)
                        Image(systemName: "checkmark")
                            .font(.system(size: 6.2, weight: .black))
                            .foregroundColor(surface.ctaText)
                    }
                }
                .offset(x: 10.5, y: 10.5)
            }
        }
        .frame(width: frameSize, height: frameSize)
    }

    @ViewBuilder
    private var trailingMeta: some View {
        if isNeedsInput {
            Text(l10n.replyCTA)
                .font(.system(size: 10.2, weight: .semibold))
                .foregroundColor(surface.ctaText)
                .padding(.horizontal, 9)
                .padding(.vertical, 3.5)
                .background(Capsule().fill(surface.ctaFill))
        } else if isUnreadDone && isHovering {
            Text(l10n.openCTA)
                .font(.system(size: 10.2, weight: .semibold))
                .foregroundColor(surface.ctaText)
                .padding(.horizontal, 9)
                .padding(.vertical, 3.5)
                .background(
                    Capsule().fill(
                        session.status == .error ? LumiPalette.errorCoral : surface.ctaFill
                    )
                )
        } else if session.status == .running {
            HStack(spacing: 5) {
                LiveElapsedText(since: session.startedAt ?? session.updatedAt, style: .duration)
                    .font(.system(size: 10.6, weight: .medium, design: .monospaced))
                    .foregroundColor(surface.subtleText)
                if isHovering {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 9.2, weight: .semibold))
                        .foregroundColor(surface.secondaryText)
                }
            }
        } else {
            HStack(spacing: 4.5) {
                if let comp = session.completedAt {
                    let clockStr = ProjectNameHelper.formatClock(comp)
                    if !compact, let dur = session.durationSec, dur >= 5 {
                        Text("\(clockStr) · \(ProjectNameHelper.formatDuration(dur))")
                            .font(.system(size: 10.0, weight: .medium, design: .monospaced))
                            .foregroundColor(
                                isUnreadDone
                                    ? (session.status == .error ? LumiPalette.errorCoral : surface.emberHighlight.opacity(0.92))
                                    : surface.subtleText.opacity(0.85)
                            )
                    } else {
                        Text(clockStr)
                            .font(.system(size: 10.4, weight: .medium, design: .monospaced))
                            .foregroundColor(
                                isUnreadDone
                                    ? (session.status == .error ? LumiPalette.errorCoral : surface.emberHighlight.opacity(0.92))
                                    : surface.subtleText.opacity(0.85)
                            )
                    }
                }
                if isHovering && !isUnreadDone {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 9.2, weight: .semibold))
                        .foregroundColor(surface.secondaryText)
                }
            }
        }
    }
}
