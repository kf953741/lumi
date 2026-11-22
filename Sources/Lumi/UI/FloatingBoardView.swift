import AppKit
import SwiftUI

struct FloatingBoardView: View {
    @ObservedObject var store: MonitorStore
    var onDockToNotch: () -> Void
    var onOpenSettings: () -> Void
    var onHide: () -> Void

    @State private var lookOffset: CGSize = .zero

    var body: some View {
        ZStack {
            // Smoked obsidian frosted glass (subtle ambient blur + crisp high-contrast readability)
            ZStack {
                LiquidGlassBackdrop(material: .hudWindow)
                LinearGradient(
                    colors: [
                        Color(red: 0.052, green: 0.055, blue: 0.072).opacity(0.84),
                        Color(red: 0.036, green: 0.039, blue: 0.052).opacity(0.88)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.22),
                                Color.white.opacity(0.08),
                                Color.white.opacity(0.04),
                                Color.white.opacity(0.12)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.85
                    )
            )

            StudioBentoBoardView(
                store: store,
                inNotch: false,
                lookOffset: lookOffset,
                onSwitchMode: onDockToNotch,
                onOpenSettings: onOpenSettings,
                onHide: onHide
            )
        }
        .preferredColorScheme(.dark)
        .frame(minWidth: 420, minHeight: 410)
    }
}
