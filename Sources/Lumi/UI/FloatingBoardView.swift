import AppKit
import SwiftUI

struct FloatingBoardView: View {
    @ObservedObject var store: MonitorStore
    var onDockToNotch: () -> Void
    var onOpenSettings: () -> Void
    var onHide: () -> Void

    @State private var lookOffset: CGSize = .zero

    private var surface: BoardSurfaceTheme {
        store.floatingAppearance == .oatLight ? .oatLight : .charcoal
    }

    var body: some View {
        ZStack {
            // Warm Charcoal (dark) OR Morning Oat Cream (light) frosted glass backdrop
            ZStack {
                LiquidGlassBackdrop(material: surface.isLight ? .popover : .hudWindow, isLight: surface.isLight)
                LinearGradient(
                    colors: [surface.shellTop, surface.shellBottom],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: surface.rimColors,
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.85
                    )
            )

            StudioBentoBoardView(
                store: store,
                inNotch: false,
                surface: surface,
                lookOffset: lookOffset,
                onSwitchMode: onDockToNotch,
                onOpenSettings: onOpenSettings,
                onHide: onHide
            )
        }
        .preferredColorScheme(surface.isLight ? .light : .dark)
        .frame(minWidth: 420, minHeight: 410)
    }
}
