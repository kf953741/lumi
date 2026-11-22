import SwiftUI

/// Ultra-clean Studio Bento hairline row — zero nested card borders, zero rainbow clutter.
/// Hover reveals crisp jump & dismiss actions; clicking an unread completed row jumps & auto-reads.
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
                return Color(red: 0.98, green: 0.34, blue: 0.34).opacity(isHovering ? 0.14 : 0.08)
            }
            return Color(red: 1.0, green: 0.74, blue: 0.24).opacity(isHovering ? 0.12 : 0.06)
        }
        return Color.white.opacity(isHovering ? 0.065 : 0.0)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            Button(action: onOpen) {
                HStack(alignment: .center, spacing: 10) {
                    // Leading minimalist status beacon
                    statusIndicator
                        .frame(width: 14, alignment: .center)

                    // Main content (Title + single ultra-clean meta line)
                    VStack(alignment: .leading, spacing: compact ? 2 : 3.5) {
                        Text(session.title)
                            .font(.system(size: compact ? 12 : 12.5, weight: .semibold))
                            .foregroundColor(Color.white.opacity(compact ? 0.72 : 0.96))
                            .lineLimit(1)
                            .truncationMode(.tail)

                        if session.status == .running {
                            HStack(spacing: 5) {
                                microSourceTag
                                Text(session.project)
                                    .font(.system(size: 10.5, weight: .medium))
                                    .foregroundColor(Color.white.opacity(0.58))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                if session.activeSubagents > 0 {
                                    Text("+\(session.activeSubagents)")
                                        .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                                        .foregroundColor(Color(red: 1.0, green: 0.68, blue: 0.28))
                                        .padding(.horizontal, 4.5)
                                        .padding(.vertical, 0.5)
                                        .background(Capsule().fill(Color.orange.opacity(0.18)))
                                }
                                Text("·")
                                    .font(.system(size: 10.5))
                                    .foregroundColor(Color.white.opacity(0.35))
                                Text(session.currentAction)
                                    .font(.system(size: 10.5))
                                    .foregroundColor(Color.white.opacity(0.76))
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                        } else {
                            HStack(spacing: 5) {
                                microSourceTag
                                Text(session.project)
                                    .font(.system(size: 10.5, weight: .medium))
                                    .foregroundColor(Color.white.opacity(0.58))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                if session.status == .error {
                                    Text("· 执行出错")
                                        .font(.system(size: 10.5, weight: .medium))
                                        .foregroundColor(Color(red: 1.0, green: 0.44, blue: 0.44))
                                }
                            }
                        }
                    }

                    Spacer(minLength: 8)

                    // Right side: tabular timer/clock or jump hint
                    trailingMeta
                }
                .padding(.vertical, compact ? 7.5 : 9.5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isUnreadDone && isHovering, let onMarkRead {
                Button(action: onMarkRead) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(Color.white.opacity(0.72))
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color.white.opacity(0.10)))
                }
                .buttonStyle(.plain)
                .help("仅标为已读")
            }
        }
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(rowBackground)
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

    @ViewBuilder
    private var statusIndicator: some View {
        if session.status == .running {
            ZStack {
                Circle()
                    .fill(session.kind.accentColor.opacity(0.26))
                    .frame(width: 12, height: 12)
                Circle()
                    .fill(session.kind.accentColor)
                    .frame(width: 6.5, height: 6.5)
            }
        } else if isUnreadDone {
            if session.status == .error {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color(red: 1.0, green: 0.40, blue: 0.40))
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color(red: 1.0, green: 0.76, blue: 0.24))
            }
        } else {
            Circle()
                .fill(Color.white.opacity(0.22))
                .frame(width: 5.5, height: 5.5)
        }
    }

    private var microSourceTag: some View {
        Text(session.kind.shortLabel)
            .font(.system(size: 9.5, weight: .bold, design: .rounded))
            .foregroundColor(session.kind.accentColor.opacity(0.95))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(session.kind.accentColor.opacity(0.14))
            )
    }

    @ViewBuilder
    private var trailingMeta: some View {
        if isUnreadDone && isHovering {
            Text("跳转 →")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundColor(Color(red: 1.0, green: 0.80, blue: 0.34))
                .padding(.horizontal, 7.5)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color(red: 1.0, green: 0.74, blue: 0.24).opacity(0.18)))
        } else if session.status == .running {
            HStack(spacing: 5) {
                let elapsed = max(0, nowRef.timeIntervalSince(session.startedAt ?? session.updatedAt))
                Text(ProjectNameHelper.formatDuration(elapsed))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(Color.white.opacity(0.46))
                if isHovering {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundColor(Color.white.opacity(0.65))
                }
            }
        } else {
            HStack(spacing: 5) {
                if let comp = session.completedAt {
                    Text(ProjectNameHelper.formatClock(comp))
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .foregroundColor(isUnreadDone ? Color(red: 1.0, green: 0.80, blue: 0.36).opacity(0.90) : Color.white.opacity(0.36))
                }
                if isHovering && !isUnreadDone {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundColor(Color.white.opacity(0.55))
                }
            }
        }
    }
}
