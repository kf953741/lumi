import AppKit
import Foundation
import SwiftUI

// MARK: - Warm Charcoal Hearth Shared Design Tokens

enum LumiPalette {
    static let shellTop      = Color(red: 0.082, green: 0.073, blue: 0.068)
    static let shellBottom   = Color(red: 0.060, green: 0.054, blue: 0.050)
    static let cardTop       = Color(red: 0.138, green: 0.122, blue: 0.114)
    static let cardBottom    = Color(red: 0.106, green: 0.095, blue: 0.089)
    static let knockoutBg    = Color(red: 0.120, green: 0.106, blue: 0.099)

    static let stageTop      = Color(red: 0.155, green: 0.120, blue: 0.100)
    static let stageBottom   = Color(red: 0.098, green: 0.084, blue: 0.076)

    static let warmPrimary   = Color(red: 0.985, green: 0.968, blue: 0.945)
    static let warmSecondary = Color(red: 0.850, green: 0.800, blue: 0.750).opacity(0.72)
    static let warmSubtle    = Color(red: 0.820, green: 0.760, blue: 0.700).opacity(0.48)
    static let warmDivider   = Color(red: 1.000, green: 0.920, blue: 0.840).opacity(0.085)
    static let champagneRim  = Color(red: 1.000, green: 0.930, blue: 0.850)

    static let emberOrange   = Color(red: 0.965, green: 0.576, blue: 0.224) // #F69339
    static let emberGold     = Color(red: 0.992, green: 0.702, blue: 0.345) // #FDB358
    static let runningIvory  = Color(red: 0.925, green: 0.880, blue: 0.825)
    static let errorCoral    = Color(red: 0.965, green: 0.400, blue: 0.365)
    static let needsAmber    = Color(red: 1.000, green: 0.530, blue: 0.250)
    static let darkInk       = Color(red: 0.140, green: 0.100, blue: 0.080)
}

/// Dual-surface appearance tokens: Warm Charcoal Hearth (default & mandatory for hardware Notch)
/// + optional Morning Oat Cream light surface for Floating Desktop Board.
struct BoardSurfaceTheme {
    let isLight: Bool

    static let charcoal = BoardSurfaceTheme(isLight: false)
    static let oatLight = BoardSurfaceTheme(isLight: true)

    var shellTop: Color {
        isLight ? Color(red: 0.972, green: 0.950, blue: 0.918).opacity(0.94) : LumiPalette.shellTop.opacity(0.90)
    }
    var shellBottom: Color {
        isLight ? Color(red: 0.948, green: 0.918, blue: 0.875).opacity(0.96) : LumiPalette.shellBottom.opacity(0.94)
    }
    var cardTop: Color {
        isLight ? Color(red: 1.000, green: 0.994, blue: 0.984).opacity(0.93) : LumiPalette.cardTop.opacity(0.88)
    }
    var cardBottom: Color {
        isLight ? Color(red: 0.992, green: 0.980, blue: 0.962).opacity(0.96) : LumiPalette.cardBottom.opacity(0.92)
    }
    var stageTop: Color {
        isLight ? Color(red: 0.996, green: 0.945, blue: 0.886) : LumiPalette.stageTop.opacity(0.94)
    }
    var stageBottom: Color {
        isLight ? Color(red: 0.978, green: 0.896, blue: 0.818) : LumiPalette.stageBottom.opacity(0.96)
    }
    var knockoutBg: Color {
        isLight ? Color(red: 0.995, green: 0.988, blue: 0.975) : LumiPalette.knockoutBg
    }
    var primaryText: Color {
        isLight ? Color(red: 0.149, green: 0.122, blue: 0.106) : LumiPalette.warmPrimary
    }
    var secondaryText: Color {
        isLight ? Color(red: 0.440, green: 0.375, blue: 0.330) : LumiPalette.warmSecondary
    }
    var subtleText: Color {
        isLight ? Color(red: 0.560, green: 0.490, blue: 0.440) : LumiPalette.warmSubtle
    }
    var divider: Color {
        isLight ? Color(red: 0.550, green: 0.450, blue: 0.360).opacity(0.14) : LumiPalette.warmDivider
    }
    var emberAccent: Color {
        isLight ? Color(red: 0.880, green: 0.425, blue: 0.140) : LumiPalette.emberOrange
    }
    var emberHighlight: Color {
        isLight ? Color(red: 0.855, green: 0.410, blue: 0.135) : LumiPalette.emberGold
    }
    var runningTone: Color {
        isLight ? Color(red: 0.270, green: 0.220, blue: 0.190) : LumiPalette.runningIvory
    }
    var pillBg: Color {
        isLight ? Color(red: 0.945, green: 0.905, blue: 0.855) : Color.white.opacity(0.09)
    }
    var segmentedTrack: Color {
        isLight ? Color(red: 0.935, green: 0.892, blue: 0.840) : Color.black.opacity(0.22)
    }
    var segmentedActive: Color {
        isLight ? Color.white : Color.white.opacity(0.15)
    }
    var hoverRowFill: Color {
        isLight ? Color(red: 0.62, green: 0.48, blue: 0.36).opacity(0.08) : Color.white.opacity(0.055)
    }
    var ctaText: Color {
        isLight ? Color.white : LumiPalette.darkInk
    }
    var ctaFill: Color {
        isLight ? Color(red: 0.890, green: 0.435, blue: 0.145) : LumiPalette.emberGold
    }
    var rimColors: [Color] {
        if isLight {
            return [
                Color.white.opacity(0.95),
                Color(red: 0.85, green: 0.78, blue: 0.70).opacity(0.45),
                Color(red: 0.80, green: 0.73, blue: 0.65).opacity(0.55),
                Color.white.opacity(0.85)
            ]
        }
        return [
            LumiPalette.champagneRim.opacity(0.22),
            LumiPalette.champagneRim.opacity(0.08),
            Color.white.opacity(0.03),
            LumiPalette.emberGold.opacity(0.10)
        ]
    }
}

// MARK: - Native macOS App Icon Cache (Runtime NSWorkspace Lookup + Zero Bundled Proprietary Assets)

@MainActor
final class AgentIconCache {
    static let shared = AgentIconCache()

    private var resolved: [AgentKind: NSImage?] = [:]

    func nativeAppIcon(for kind: AgentKind) -> NSImage? {
        if let cached = resolved[kind] {
            return cached
        }
        let img = lookupNativeIcon(for: kind).flatMap { flattenToSRGB($0, pixelSize: 128) }
        resolved[kind] = img
        return img
    }

    /// Flattens macOS .icns assets (including HDR Icon Composer icons) into crisp 8-bit sRGB
    /// so icons never cause EDR peak-brightness spikes in dark HUDs or HDR PQ washouts in captures.
    private func flattenToSRGB(_ source: NSImage, pixelSize: Int) -> NSImage? {
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB) else { return source }
        let copy = (source.copy() as? NSImage) ?? source
        copy.size = NSSize(width: pixelSize, height: pixelSize)
        var proposed = CGRect(x: 0, y: 0, width: pixelSize, height: pixelSize)
        guard let rawCG = copy.cgImage(forProposedRect: &proposed, context: nil, hints: nil),
              let ctx = CGContext(
                  data: nil,
                  width: pixelSize,
                  height: pixelSize,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: srgb,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return source
        }
        ctx.interpolationQuality = .high
        ctx.draw(rawCG, in: CGRect(x: 0, y: 0, width: pixelSize, height: pixelSize))
        guard let flatCG = ctx.makeImage() else { return source }
        return NSImage(cgImage: flatCG, size: NSSize(width: pixelSize / 2, height: pixelSize / 2))
    }

    private func lookupNativeIcon(for kind: AgentKind) -> NSImage? {
        // 1. Check running desktop apps first (handles non-standard install locations automatically)
        for bid in dedicatedAppBundleIDs(for: kind) {
            if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bid).first,
               let icon = running.icon {
                return icon
            }
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) {
                return NSWorkspace.shared.icon(forFile: url.path)
            }
        }

        // 2. Check standard /Applications and ~/Applications paths
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for name in dedicatedAppNames(for: kind) {
            for dir in ["/Applications", "\(home)/Applications"] {
                let path = "\(dir)/\(name)"
                if FileManager.default.fileExists(atPath: path) {
                    return NSWorkspace.shared.icon(forFile: path)
                }
            }
        }
        return nil
    }

    /// Dedicated desktop app bundle IDs (deliberately excludes generic Terminal/VSCode
    /// so CLI-only sessions render our crisp brand squircle fallback instead of Terminal.app).
    private func dedicatedAppBundleIDs(for kind: AgentKind) -> [String] {
        switch kind {
        case .antigravity: return ["com.google.antigravity"]
        case .codex:       return ["com.openai.codex"]
        case .claude:      return ["com.anthropic.claudefordesktop"]
        case .t3code:      return ["com.t3tools.t3code", "com.t3tools.t3code.dev"]
        case .cursor:      return ["com.todesktop.230313mzl4w4u92"]
        case .gemini:      return ["com.google.gemini"]
        case .opencode:    return ["ai.opencode.desktop", "dev.opencode.app"]
        }
    }

    private func dedicatedAppNames(for kind: AgentKind) -> [String] {
        switch kind {
        case .antigravity: return ["Antigravity.app"]
        case .codex:       return ["Codex.app"]
        case .claude:      return ["Claude.app"]
        case .t3code:      return ["T3 Code (Beta).app", "T3 Code.app"]
        case .cursor:      return ["Cursor.app"]
        case .gemini:      return ["Gemini.app"]
        case .opencode:    return ["OpenCode.app"]
        }
    }
}

// MARK: - Optically Matched Native macOS App Icon (with 6 Crisp Squircle Vector Fallbacks)

struct NativeAgentIconView: View {
    let kind: AgentKind
    var visualSize: CGFloat = 27
    var dimmed: Bool = false

    var body: some View {
        Group {
            if let nsImage = AgentIconCache.shared.nativeAppIcon(for: kind) {
                // Real macOS .icns assets carry ~10% transparent padding around the squircle body;
                // scale by 1.15x inside a fixed visualSize box so native & fallback icons match 1-to-1.
                Image(nsImage: nsImage)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: visualSize * 1.15, height: visualSize * 1.15)
                    .frame(width: visualSize, height: visualSize)
                    .shadow(color: Color.black.opacity(0.28), radius: 2, y: 1)
            } else {
                fallbackSquircleIcon
            }
        }
        .opacity(dimmed ? 0.62 : 1.0)
    }

    private var fallbackSquircleIcon: some View {
        let cr = visualSize * 0.235
        return ZStack {
            RoundedRectangle(cornerRadius: cr, style: .continuous)
                .fill(fallbackGradient)
                .overlay(
                    RoundedRectangle(cornerRadius: cr, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.65)
                )

            AgentVectorGlyph(kind: kind, color: fallbackGlyphColor, size: visualSize * 0.58)
        }
        .frame(width: visualSize, height: visualSize)
        .shadow(color: Color.black.opacity(0.28), radius: 2, y: 1)
    }

    private var fallbackGradient: LinearGradient {
        switch kind {
        case .antigravity:
            return LinearGradient(
                colors: [Color(red: 0.19, green: 0.20, blue: 0.26), Color(red: 0.10, green: 0.11, blue: 0.15)],
                startPoint: .top, endPoint: .bottom
            )
        case .codex:
            return LinearGradient(
                colors: [Color(red: 0.17, green: 0.18, blue: 0.20), Color(red: 0.085, green: 0.09, blue: 0.10)],
                startPoint: .top, endPoint: .bottom
            )
        case .claude:
            return LinearGradient(
                colors: [Color(red: 0.875, green: 0.502, blue: 0.365), Color(red: 0.780, green: 0.396, blue: 0.275)],
                startPoint: .top, endPoint: .bottom
            )
        case .t3code:
            return LinearGradient(
                colors: [Color(red: 0.145, green: 0.165, blue: 0.240), Color(red: 0.075, green: 0.085, blue: 0.130)],
                startPoint: .top, endPoint: .bottom
            )
        case .cursor:
            return LinearGradient(
                colors: [Color(red: 0.16, green: 0.17, blue: 0.19), Color(red: 0.075, green: 0.08, blue: 0.095)],
                startPoint: .top, endPoint: .bottom
            )
        case .gemini:
            return LinearGradient(
                colors: [Color(red: 0.20, green: 0.36, blue: 0.68), Color(red: 0.14, green: 0.22, blue: 0.46)],
                startPoint: .top, endPoint: .bottom
            )
        case .opencode:
            return LinearGradient(
                colors: [Color(red: 0.21, green: 0.19, blue: 0.17), Color(red: 0.11, green: 0.10, blue: 0.09)],
                startPoint: .top, endPoint: .bottom
            )
        }
    }

    private var fallbackGlyphColor: Color {
        switch kind {
        case .claude:
            return Color(red: 0.996, green: 0.976, blue: 0.953)
        default:
            return Color.white.opacity(0.95)
        }
    }
}

// MARK: - Pure SwiftUI Canvas Vector Brand Glyphs (Zero External Assets)

struct AgentVectorGlyph: View {
    let kind: AgentKind
    let color: Color
    var size: CGFloat = 15

    var body: some View {
        Canvas { ctx, sz in
            let s = min(sz.width, sz.height)
            let cx = sz.width * 0.5
            let cy = sz.height * 0.5

            switch kind {
            case .antigravity:
                var arch = Path()
                arch.move(to: CGPoint(x: cx - s * 0.34, y: cy + s * 0.34))
                arch.addCurve(
                    to: CGPoint(x: cx, y: cy - s * 0.36),
                    control1: CGPoint(x: cx - s * 0.24, y: cy - s * 0.04),
                    control2: CGPoint(x: cx - s * 0.08, y: cy - s * 0.36)
                )
                arch.addCurve(
                    to: CGPoint(x: cx + s * 0.34, y: cy + s * 0.34),
                    control1: CGPoint(x: cx + s * 0.08, y: cy - s * 0.36),
                    control2: CGPoint(x: cx + s * 0.24, y: cy - s * 0.04)
                )
                ctx.stroke(arch, with: .color(color), style: StrokeStyle(lineWidth: s * 0.145, lineCap: .round, lineJoin: .round))

                var bar = Path()
                bar.move(to: CGPoint(x: cx - s * 0.19, y: cy + s * 0.10))
                bar.addQuadCurve(to: CGPoint(x: cx + s * 0.19, y: cy + s * 0.10), control: CGPoint(x: cx, y: cy + s * 0.01))
                ctx.stroke(bar, with: .color(color.opacity(0.85)), style: StrokeStyle(lineWidth: s * 0.115, lineCap: .round))

            case .codex:
                let ringR = s * 0.22
                let loopR = s * 0.155
                for i in 0..<6 {
                    let angle = Double(i) * (.pi / 3.0) - .pi / 6.0
                    let px = cx + CGFloat(Foundation.cos(angle)) * ringR
                    let py = cy + CGFloat(Foundation.sin(angle)) * ringR
                    let rect = CGRect(x: px - loopR, y: py - loopR, width: loopR * 2, height: loopR * 2)
                    ctx.stroke(Path(ellipseIn: rect), with: .color(color), style: StrokeStyle(lineWidth: s * 0.095))
                }

            case .claude:
                let angles: [Double] = [0, 42, 88, 132, 180, 224, 268, 315]
                let lengths: [CGFloat] = [0.40, 0.32, 0.41, 0.33, 0.39, 0.31, 0.40, 0.34]
                for idx in 0..<angles.count {
                    let rad = angles[idx] * .pi / 180.0
                    let len = s * lengths[idx]
                    var ray = Path()
                    ray.move(to: CGPoint(
                        x: cx + CGFloat(Foundation.cos(rad)) * s * 0.08,
                        y: cy + CGFloat(Foundation.sin(rad)) * s * 0.08
                    ))
                    ray.addLine(to: CGPoint(
                        x: cx + CGFloat(Foundation.cos(rad)) * len,
                        y: cy + CGFloat(Foundation.sin(rad)) * len
                    ))
                    ctx.stroke(ray, with: .color(color), style: StrokeStyle(lineWidth: s * 0.115, lineCap: .round))
                }
                let centerDot = CGRect(x: cx - s * 0.09, y: cy - s * 0.09, width: s * 0.18, height: s * 0.18)
                ctx.fill(Path(ellipseIn: centerDot), with: .color(color))

            case .t3code:
                // Geometric "T3" monogram fallback when T3 Code desktop bundle isn't installed
                let lw = s * 0.125
                var tBar = Path()
                tBar.move(to: CGPoint(x: cx - s * 0.36, y: cy - s * 0.24))
                tBar.addLine(to: CGPoint(x: cx - s * 0.02, y: cy - s * 0.24))
                tBar.move(to: CGPoint(x: cx - s * 0.19, y: cy - s * 0.24))
                tBar.addLine(to: CGPoint(x: cx - s * 0.19, y: cy + s * 0.28))
                ctx.stroke(tBar, with: .color(color), style: StrokeStyle(lineWidth: lw, lineCap: .round, lineJoin: .round))

                var three = Path()
                three.move(to: CGPoint(x: cx + s * 0.07, y: cy - s * 0.24))
                three.addLine(to: CGPoint(x: cx + s * 0.32, y: cy - s * 0.24))
                three.addLine(to: CGPoint(x: cx + s * 0.16, y: cy))
                three.addQuadCurve(to: CGPoint(x: cx + s * 0.33, y: cy + s * 0.15), control: CGPoint(x: cx + s * 0.33, y: cy))
                three.addQuadCurve(to: CGPoint(x: cx + s * 0.07, y: cy + s * 0.27), control: CGPoint(x: cx + s * 0.32, y: cy + s * 0.30))
                ctx.stroke(three, with: .color(color.opacity(0.92)), style: StrokeStyle(lineWidth: lw * 0.92, lineCap: .round, lineJoin: .round))

            case .cursor:
                var arrow = Path()
                arrow.move(to: CGPoint(x: cx - s * 0.28, y: cy - s * 0.36))
                arrow.addLine(to: CGPoint(x: cx + s * 0.34, y: cy + s * 0.02))
                arrow.addLine(to: CGPoint(x: cx + s * 0.02, y: cy + s * 0.08))
                arrow.addLine(to: CGPoint(x: cx - s * 0.12, y: cy + s * 0.38))
                arrow.closeSubpath()
                ctx.fill(arrow, with: .color(color))

            case .gemini:
                var star = Path()
                let r = s * 0.42
                star.move(to: CGPoint(x: cx, y: cy - r))
                star.addQuadCurve(to: CGPoint(x: cx + r, y: cy), control: CGPoint(x: cx + r * 0.14, y: cy - r * 0.14))
                star.addQuadCurve(to: CGPoint(x: cx, y: cy + r), control: CGPoint(x: cx + r * 0.14, y: cy + r * 0.14))
                star.addQuadCurve(to: CGPoint(x: cx - r, y: cy), control: CGPoint(x: cx - r * 0.14, y: cy + r * 0.14))
                star.addQuadCurve(to: CGPoint(x: cx, y: cy - r), control: CGPoint(x: cx - r * 0.14, y: cy - r * 0.14))
                star.closeSubpath()
                ctx.fill(star, with: .color(color))

            case .opencode:
                var chevron = Path()
                chevron.move(to: CGPoint(x: cx - s * 0.32, y: cy - s * 0.22))
                chevron.addLine(to: CGPoint(x: cx - s * 0.06, y: cy))
                chevron.addLine(to: CGPoint(x: cx - s * 0.32, y: cy + s * 0.22))
                ctx.stroke(chevron, with: .color(color), style: StrokeStyle(lineWidth: s * 0.13, lineCap: .round, lineJoin: .round))

                var under = Path()
                under.move(to: CGPoint(x: cx + s * 0.04, y: cy + s * 0.22))
                under.addLine(to: CGPoint(x: cx + s * 0.34, y: cy + s * 0.22))
                ctx.stroke(under, with: .color(color), style: StrokeStyle(lineWidth: s * 0.13, lineCap: .round))
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Apple Knockout Corner Status Badge (Low-CPU Adaptive Animation)

struct KnockoutRunningSpinner: View {
    var accent: Color = LumiPalette.emberGold
    var knockoutColor: Color = LumiPalette.knockoutBg
    var fixedPhase: Double? = nil

    var body: some View {
        Group {
            if let fixedPhase {
                spinnerCanvas(phase: fixedPhase)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 24.0)) { timeline in
                    let t = timeline.date.timeIntervalSinceReferenceDate
                    let phase = (t / 1.35).truncatingRemainder(dividingBy: 1.0)
                    spinnerCanvas(phase: phase)
                }
            }
        }
        .frame(width: 14, height: 14)
    }

    private func spinnerCanvas(phase: Double) -> some View {
        Canvas { ctx, sz in
            let rect = CGRect(origin: .zero, size: sz)
            // Knockout dark ring cutting cleanly into the squircle icon corner
            ctx.fill(Path(ellipseIn: rect), with: .color(knockoutColor))

            let center = CGPoint(x: sz.width * 0.5, y: sz.height * 0.5)
            let radius: CGFloat = 4.6

            // Faint base track
            let trackRect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
            ctx.stroke(Path(ellipseIn: trackRect), with: .color(accent.opacity(0.24)), style: StrokeStyle(lineWidth: 1.45))

            // Smooth sweeping golden arc (62% of circle)
            let startDeg = phase * 360.0 - 90.0
            let endDeg = startDeg + 225.0
            var arc = Path()
            arc.addArc(
                center: center,
                radius: radius,
                startAngle: .degrees(startDeg),
                endAngle: .degrees(endDeg),
                clockwise: false
            )
            ctx.stroke(arc, with: .color(accent), style: StrokeStyle(lineWidth: 1.55, lineCap: .round))
        }
    }
}

// MARK: - Compact Subtle Activity Pulse Bars (for Telemetry Header)

struct TelemetryPulseBars: View {
    var active: Bool
    var color: Color = LumiPalette.runningIvory
    var fixedTime: TimeInterval? = nil

    var body: some View {
        Group {
            if !active {
                HStack(alignment: .bottom, spacing: 1.7) {
                    ForEach(0..<3, id: \.self) { i in
                        Capsule()
                            .fill(Color.white.opacity(0.22))
                            .frame(width: 1.7, height: i == 1 ? 5.5 : 3.5)
                    }
                }
                .frame(height: 8.5, alignment: .bottom)
            } else if let fixedTime {
                barsView(time: fixedTime)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 12.0)) { timeline in
                    barsView(time: timeline.date.timeIntervalSinceReferenceDate)
                }
            }
        }
    }

    private func barsView(time t: TimeInterval) -> some View {
        let h0 = CGFloat(3.4 + 2.4 * (0.5 + 0.5 * Foundation.sin(t * 3.4)))
        let h1 = CGFloat(5.0 + 3.2 * (0.5 + 0.5 * Foundation.sin(t * 3.4 + 1.3)))
        let h2 = CGFloat(3.6 + 2.8 * (0.5 + 0.5 * Foundation.sin(t * 3.4 + 2.6)))
        return HStack(alignment: .bottom, spacing: 1.7) {
            Capsule().fill(color.opacity(0.65)).frame(width: 1.7, height: h0)
            Capsule().fill(color.opacity(0.95)).frame(width: 1.7, height: h1)
            Capsule().fill(color.opacity(0.70)).frame(width: 1.7, height: h2)
        }
        .frame(height: 8.5, alignment: .bottom)
    }
}
