import SwiftUI

/// Refined Studio Bento hairline row — native macOS app icon with Apple Knockout
/// corner status badge (zero rainbow dots, zero colored pill clutter), clean warm
/// monochrome metadata, and Swiss-watch tabular timestamps.
struct BentoSessionRow: View {
    let session: AgentSession
    var nowRef: Date = Date()
    var compact: Bool = false
    let onOpen: () -> Void
    let onMarkRead: (() -> Void)?

    @State private var isHovering = false

    private var isUnreadDone: Bool {
        session.isUnread && (session.status == .done || session.status == .error)
    }

    private var rowBackground: Color {
        if isUnreadDone {
            if session.status == .error {
                return LumiPalette.errorCoral.opacity(isHovering ? 0.14 : 0.08)
            }
            return LumiPalette.emberOrange.opacity(isHovering ? 0.11 : 0.05)
        }
        return Color.white.opacity(isHovering ? 0.055 : 0.0)
    }

    private var rowBorderColor: Color {
        if isUnreadDone && isHovering {
            return session.status == .error
                ? LumiPalette.errorCoral.opacity(0.30)
                : LumiPalette.emberOrange.opacity(0.24)
        }
        return Color.clear
    }

    private var toolShortDisplay: String {
        switch session.kind {
        case .antigravity: return "Antigravity"
        case .codex:       return "Codex"
        case .claude:      return "Claude"
        case .cursor:      return "Cursor"
        case .gemini:      return "Gemini"
        case .opencode:    return "OpenCode"
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            Button(action: onOpen) {
                HStack(alignment: .center, spacing: 11) {
                    // Leading: Pure native macOS app squircle + Apple Knockout corner badge
                    leadingAppIconWithBadge

                    // Middle: Crisp title + single monochrome metadata line
                    VStack(alignment: .leading, spacing: compact ? 2 : 3.5) {
                        Text(session.title)
                            .font(.system(size: compact ? 11.8 : 12.2, weight: .semibold))
                            .foregroundColor(compact ? LumiPalette.warmSecondary : LumiPalette.warmPrimary)
                            .lineLimit(1)
                            .truncationMode(.tail)

                        if session.status == .running {
                            HStack(spacing: 4.5) {
                                Text(toolShortDisplay)
                                    .font(.system(size: 10.2, weight: .semibold))
                                    .foregroundColor(Color(red: 0.92, green: 0.87, blue: 0.82).opacity(0.76))
                                Text("·")
                                    .font(.system(size: 10.2))
                                    .foregroundColor(LumiPalette.warmSubtle)
                                Text(session.project)
                                    .font(.system(size: 10.2, weight: .medium))
                                    .foregroundColor(LumiPalette.warmSecondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                if session.activeSubagents > 0 {
                                    Text("+\(session.activeSubagents)")
                                        .font(.system(size: 8.8, weight: .semibold, design: .rounded))
                                        .foregroundColor(Color(red: 0.92, green: 0.87, blue: 0.82).opacity(0.78))
                                        .padding(.horizontal, 4.5)
                                        .padding(.vertical, 0.8)
                                        .background(Capsule().fill(Color.white.opacity(0.08)))
                                }
                                Text("·")
                                    .font(.system(size: 10.2))
                                    .foregroundColor(LumiPalette.warmSubtle)
                                Text(session.currentAction)
                                    .font(.system(size: 10.2))
                                    .foregroundColor(LumiPalette.warmPrimary.opacity(0.74))
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                        } else {
                            HStack(spacing: 4.5) {
                                Text(toolShortDisplay)
                                    .font(.system(size: 10.2, weight: .semibold))
                                    .foregroundColor(Color(red: 0.92, green: 0.87, blue: 0.82).opacity(compact ? 0.56 : 0.76))
                                Text("·")
                                    .font(.system(size: 10.2))
                                    .foregroundColor(LumiPalette.warmSubtle)
                                Text(session.project)
                                    .font(.system(size: 10.2, weight: .medium))
                                    .foregroundColor(compact ? LumiPalette.warmSubtle : LumiPalette.warmSecondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                if session.status == .error {
                                    Text("· 执行出错")
                                        .font(.system(size: 10.2, weight: .medium))
                                        .foregroundColor(LumiPalette.errorCoral)
                                }
                            }
                        }
                    }

                    Spacer(minLength: 8)

                    // Right side: Swiss-watch clean tabular timer or crisp hover CTA
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
                        .foregroundColor(LumiPalette.warmSecondary)
                        .frame(width: 21, height: 21)
                        .background(Circle().fill(Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .help("仅标为已读")
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
        .help(isUnreadDone
              ? "单击切换到 \(session.kind.displayName) 并移出待查看"
              : "单击切换到 \(session.kind.displayName)")
    }

    // MARK: - Native App Icon + Apple Knockout Corner Badge

    private var leadingAppIconWithBadge: some View {
        let iconSize: CGFloat = compact ? 22 : 27
        let frameSize: CGFloat = compact ? 24 : 30

        return ZStack {
            NativeAgentIconView(kind: session.kind, visualSize: iconSize, dimmed: compact)

            if session.status == .running {
                KnockoutRunningSpinner(
                    accent: LumiPalette.emberGold,
                    knockoutColor: LumiPalette.knockoutBg
                )
                .offset(x: 10.5, y: 10.5)
            } else if isUnreadDone {
                ZStack {
                    Circle()
                        .fill(LumiPalette.knockoutBg)
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
                            .fill(LumiPalette.emberOrange)
                            .frame(width: 10.5, height: 10.5)
                        Image(systemName: "checkmark")
                            .font(.system(size: 6.2, weight: .black))
                            .foregroundColor(LumiPalette.darkInk)
                    }
                }
                .offset(x: 10.5, y: 10.5)
            }
        }
        .frame(width: frameSize, height: frameSize)
    }

    @ViewBuilder
    private var trailingMeta: some View {
        if isUnreadDone && isHovering {
            Text("打开 ↗")
                .font(.system(size: 10.2, weight: .semibold))
                .foregroundColor(LumiPalette.darkInk)
                .padding(.horizontal, 9)
                .padding(.vertical, 3.5)
                .background(
                    Capsule().fill(
                        session.status == .error ? LumiPalette.errorCoral : LumiPalette.emberGold
                    )
                )
        } else if session.status == .running {
            HStack(spacing: 5) {
                let elapsed = max(0, nowRef.timeIntervalSince(session.startedAt ?? session.updatedAt))
                Text(ProjectNameHelper.formatDuration(elapsed))
                    .font(.system(size: 10.6, weight: .medium, design: .monospaced))
                    .foregroundColor(LumiPalette.warmSubtle)
                if isHovering {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 9.2, weight: .semibold))
                        .foregroundColor(LumiPalette.warmSecondary)
                }
            }
        } else {
            HStack(spacing: 5) {
                if let comp = session.completedAt {
                    Text(ProjectNameHelper.formatClock(comp))
                        .font(.system(size: 10.4, weight: .medium, design: .monospaced))
                        .foregroundColor(
                            isUnreadDone
                                ? (session.status == .error ? LumiPalette.errorCoral : LumiPalette.emberGold.opacity(0.92))
                                : LumiPalette.warmSubtle.opacity(0.85)
                        )
                }
                if isHovering && !isUnreadDone {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 9.2, weight: .semibold))
                        .foregroundColor(LumiPalette.warmSecondary)
                }
            }
        }
    }
}
