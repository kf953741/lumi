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
            // Warm Charcoal frosted glass (subtle ambient blur + crisp warm-white readability)
            ZStack {
                LiquidGlassBackdrop(material: .hudWindow)
                LinearGradient(
                    colors: [
                        LumiPalette.shellTop.opacity(0.90),
                        LumiPalette.shellBottom.opacity(0.94)
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
                                LumiPalette.champagneRim.opacity(0.20),
                                LumiPalette.champagneRim.opacity(0.07),
                                Color.white.opacity(0.03),
                                LumiPalette.emberGold.opacity(0.11)
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
