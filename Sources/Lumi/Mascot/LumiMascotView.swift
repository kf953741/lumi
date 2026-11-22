import Foundation
import SwiftUI

/// Original "Lumi Ember" flat-editorial luminous bean mascot (Headspace × Pixar inspired)
/// rendered with pure lineless SwiftUI Canvas vectors & adaptive frame rates (< 2% idle CPU).
struct LumiMascotView: View {
    let mood: MascotMood
    let theme: MascotTheme
    var size: CGFloat = 44
    var lookOffset: CGSize = .zero   // normalized -1...1 gaze vector
    var isCompact: Bool = false
    var isActiveSurface: Bool = true
    var fixedTime: TimeInterval? = nil
    var onPoke: (() -> Void)? = nil

    private let inkColor = Color(red: 0.145, green: 0.175, blue: 0.228)     // #252D3A charcoal ink
    private let cavityColor = Color(red: 0.133, green: 0.157, blue: 0.204)  // #222834 grin cavity
    private let tongueColor = Color(red: 0.961, green: 0.420, blue: 0.294)  // #F56B4B coral tongue
    private let scleraColor = Color(red: 0.996, green: 0.996, blue: 0.996)  // #FEFEFE

    private var frameInterval: TimeInterval {
        switch mood {
        case .celebrating, .poked, .dizzy:
            return 1.0 / 30.0
        case .working, .error:
            return isActiveSurface ? (1.0 / 24.0) : (1.0 / 5.0)
        case .waitingUnread:
            return isActiveSurface ? (1.0 / 15.0) : (1.0 / 2.0)
        case .sleeping:
            return isActiveSurface ? (1.0 / 10.0) : 1.0
        }
    }

    var body: some View {
        Group {
            if let fixedTime {
                Canvas { ctx, canvasSize in
                    drawEmber(in: &ctx, size: canvasSize, time: fixedTime)
                }
                .frame(width: size, height: size)
            } else {
                TimelineView(.animation(minimumInterval: frameInterval)) { timeline in
                    let t = timeline.date.timeIntervalSinceReferenceDate
                    Canvas { ctx, canvasSize in
                        drawEmber(in: &ctx, size: canvasSize, time: t)
                    }
                    .frame(width: size, height: size)
                }
            }
        }
        .contentShape(Circle())
        .onTapGesture {
            onPoke?()
        }
    }

    // MARK: - Top-Level Pose Router

    private func drawEmber(in ctx: inout GraphicsContext, size: CGSize, time t: TimeInterval) {
        let s = min(size.width, size.height)
        let cx = size.width * 0.5
        let cy = size.height * 0.52

        if isCompact {
            drawCompactNotchEmber(in: &ctx, cx: cx, cy: size.height * 0.52, s: s, time: t)
            return
        }

        switch mood {
        case .working:
            drawWorkingPose(in: &ctx, cx: cx, cy: cy, s: s, time: t)
        case .celebrating:
            drawCelebratingPose(in: &ctx, cx: cx, cy: cy, s: s, time: t)
        case .sleeping:
            drawSleepingPose(in: &ctx, cx: cx, cy: cy, s: s, time: t)
        case .waitingUnread:
            drawHeroPose(in: &ctx, cx: cx, cy: cy, s: s, time: t, showUnreadSpark: true)
        case .poked:
            drawPokedPose(in: &ctx, cx: cx, cy: cy, s: s, time: t)
        case .error:
            drawErrorPose(in: &ctx, cx: cx, cy: cy, s: s, time: t)
        case .dizzy:
            drawDizzyPose(in: &ctx, cx: cx, cy: cy, s: s, time: t)
        }
    }

    // MARK: - 1. Compact 22px Hardware Notch Pose (Ultra-Bold Asymmetric Goofy Bean)

    private func drawCompactNotchEmber(in ctx: inout GraphicsContext, cx: CGFloat, cy: CGFloat, s: CGFloat, time t: TimeInterval) {
        let bob: CGFloat
        switch mood {
        case .celebrating, .poked: bob = -CGFloat(abs(Foundation.sin(t * 7.5))) * s * 0.09
        case .working:             bob = CGFloat(Foundation.sin(t * 4.5)) * s * 0.04
        case .sleeping:            bob = CGFloat(Foundation.sin(t * 1.4)) * s * 0.025
        default:                   bob = CGFloat(Foundation.sin(t * 2.8)) * s * 0.03
        }

        let bw = s * 0.86
        let bh = (mood == .sleeping) ? s * 0.70 : s * 0.86
        let origin = CGPoint(x: cx - bw * 0.5, y: cy + bob - bh * 0.5 + (mood == .sleeping ? s * 0.06 : 0))
        let body = makeUprightBeanPath(in: CGRect(origin: origin, size: CGSize(width: bw, height: bh)))
        fillBean(in: &ctx, path: body, rect: CGRect(origin: origin, size: CGSize(width: bw, height: bh)))

        // Signature oversized asymmetric white eyes so it reads effortlessly at 22px!
        let r = CGRect(origin: origin, size: CGSize(width: bw, height: bh))
        let lCenter = CGPoint(x: r.minX + bw * 0.34, y: r.minY + bh * 0.46)
        let rCenter = CGPoint(x: r.minX + bw * 0.69, y: r.minY + bh * 0.40)
        let lDia = bw * 0.27
        let rDia = bw * 0.32

        let gx = max(-1, min(1, lookOffset.width)) * bw * 0.035
        let gy = max(-1, min(1, lookOffset.height)) * bh * 0.035

        if mood == .sleeping {
            drawDroopyEye(in: &ctx, center: lCenter, diameter: lDia, lidFraction: 0.62, tiltDeg: -6)
            drawDroopyEye(in: &ctx, center: rCenter, diameter: rDia, lidFraction: 0.62, tiltDeg: -6)
        } else if mood == .celebrating || mood == .poked {
            drawCheekSquishedEye(in: &ctx, center: lCenter, diameter: lDia, pupilOffset: CGPoint(x: lDia * 0.08, y: lDia * 0.06))
            drawCheekSquishedEye(in: &ctx, center: rCenter, diameter: rDia, pupilOffset: CGPoint(x: -rDia * 0.08, y: rDia * 0.06))
        } else {
            let cycle = t.truncatingRemainder(dividingBy: 3.8)
            let blinking = cycle > 3.66
            drawSimpleAsymEye(in: &ctx, center: lCenter, diameter: lDia, pupilOffset: CGPoint(x: lDia * 0.14 + gx, y: gy), blinking: blinking)
            drawSimpleAsymEye(in: &ctx, center: rCenter, diameter: rDia, pupilOffset: CGPoint(x: -rDia * 0.12 + gx, y: rDia * 0.05 + gy), blinking: blinking)
        }

        if mood == .waitingUnread || mood == .celebrating {
            let dotR = s * 0.13
            ctx.fill(
                Path(ellipseIn: CGRect(x: r.maxX - dotR * 0.85, y: r.minY - dotR * 0.35, width: dotR * 1.7, height: dotR * 1.7)),
                with: .color(Color(red: 1.0, green: 0.82, blue: 0.30))
            )
        }
    }

    // MARK: - 2. Hero / Waiting-Unread Pose (Signature Asymmetric Googly Bean)

    private func drawHeroPose(in ctx: inout GraphicsContext, cx: CGFloat, cy: CGFloat, s: CGFloat, time t: TimeInterval, showUnreadSpark: Bool) {
        let bob = CGFloat(Foundation.sin(t * 2.8)) * s * 0.032
        let bw = s * 0.66
        let bh = bw / 0.955
        let rect = CGRect(x: cx - bw * 0.5, y: cy + bob - bh * 0.52, width: bw, height: bh)

        drawAmbientGlow(in: &ctx, center: CGPoint(x: cx, y: cy + bob), radius: s * 0.44, opacity: 0.24)
        drawGroundShadow(in: &ctx, cx: cx, y: cy + s * 0.38, width: bw * 0.82, height: s * 0.095, opacity: 0.42)

        let body = makeUprightBeanPath(in: rect)
        fillBean(in: &ctx, path: body, rect: rect)

        // Signature asymmetric eyes (right eye ~1.20x larger & higher)
        let lCenter = CGPoint(x: rect.minX + bw * 0.346, y: rect.minY + bh * 0.444)
        let rCenter = CGPoint(x: rect.minX + bw * 0.674, y: rect.minY + bh * 0.383)
        let lDia = bw * 0.232
        let rDia = bw * 0.278

        let gx = max(-1, min(1, lookOffset.width)) * bw * 0.038
        let gy = max(-1, min(1, lookOffset.height)) * bh * 0.038
        let cycle = t.truncatingRemainder(dividingBy: 3.8)
        let blinking = cycle > 3.66

        drawSimpleAsymEye(
            in: &ctx, center: lCenter, diameter: lDia,
            pupilOffset: CGPoint(x: bw * 0.030 + gx, y: -bh * 0.004 + gy),
            blinking: blinking
        )
        drawSimpleAsymEye(
            in: &ctx, center: rCenter, diameter: rDia,
            pupilOffset: CGPoint(x: -bw * 0.032 + gx, y: bh * 0.014 + gy),
            blinking: blinking
        )

        // Friendly charcoal eyebrows
        let browStyle = StrokeStyle(lineWidth: max(1.4, bw * 0.036), lineCap: .round)
        var lb = Path()
        lb.move(to: CGPoint(x: rect.minX + bw * 0.21, y: rect.minY + bh * 0.320))
        lb.addQuadCurve(
            to: CGPoint(x: rect.minX + bw * 0.39, y: rect.minY + bh * 0.256),
            control: CGPoint(x: rect.minX + bw * 0.29, y: rect.minY + bh * 0.252)
        )
        var rb = Path()
        rb.move(to: CGPoint(x: rect.minX + bw * 0.58, y: rect.minY + bh * 0.205))
        rb.addQuadCurve(
            to: CGPoint(x: rect.minX + bw * 0.76, y: rect.minY + bh * 0.225),
            control: CGPoint(x: rect.minX + bw * 0.67, y: rect.minY + bh * 0.178)
        )
        ctx.stroke(lb, with: .color(inkColor), style: browStyle)
        ctx.stroke(rb, with: .color(inkColor), style: browStyle)

        // Small tilted U-smile
        var mouth = Path()
        mouth.move(to: CGPoint(x: rect.minX + bw * 0.445, y: rect.minY + bh * 0.598))
        mouth.addQuadCurve(
            to: CGPoint(x: rect.minX + bw * 0.625, y: rect.minY + bh * 0.558),
            control: CGPoint(x: rect.minX + bw * 0.545, y: rect.minY + bh * 0.656)
        )
        ctx.stroke(mouth, with: .color(inkColor), style: StrokeStyle(lineWidth: max(1.5, bw * 0.038), lineCap: .round))

        if showUnreadSpark {
            let bounce = CGFloat(Foundation.sin(t * 4.0)) * s * 0.03
            let sc = CGPoint(x: rect.maxX + s * 0.02, y: rect.minY + s * 0.02 + bounce)
            let star = makeFourPointSpark(center: sc, radius: s * 0.095)
            ctx.fill(star, with: .color(Color(red: 1.0, green: 0.82, blue: 0.30)))
        }
    }

    // MARK: - 3. Working Pose (Wide Leaning Squint Staring Intently at `{ }`)

    private func drawWorkingPose(in ctx: inout GraphicsContext, cx: CGFloat, cy: CGFloat, s: CGFloat, time t: TimeInterval) {
        let breathe = CGFloat(Foundation.sin(t * 4.2)) * s * 0.015
        let bw = s * 0.67
        let bh = bw / 1.48
        let rect = CGRect(x: cx - s * 0.42, y: cy + s * 0.03 + breathe - bh * 0.5, width: bw, height: bh)

        drawAmbientGlow(in: &ctx, center: CGPoint(x: rect.midX, y: rect.midY), radius: s * 0.40, opacity: 0.22)
        drawGroundShadow(in: &ctx, cx: rect.midX, y: rect.maxY + s * 0.015, width: bw * 0.92, height: s * 0.085, opacity: 0.44)

        let body = makeWorkingBeanPath(in: rect)
        fillBean(in: &ctx, path: body, rect: rect)

        // Soft peach specular pill on upper-left shoulder
        var specCtx = ctx
        specCtx.translateBy(x: rect.minX + bw * 0.14, y: rect.minY + bh * 0.34)
        specCtx.rotate(by: .degrees(-36))
        specCtx.fill(
            Path(capsuleIn: CGRect(x: -bw * 0.045, y: -bh * 0.022, width: bw * 0.09, height: bh * 0.044)),
            with: .color(theme.specularColor.opacity(0.55))
        )

        // Half-hooded squinting D-shape white eyes staring hard-right at `{ }`
        let scanY = CGFloat(Foundation.sin(t * 3.0)) * bh * 0.025 + max(-1, min(1, lookOffset.height)) * bh * 0.03
        let lCenter = CGPoint(x: rect.minX + bw * 0.62, y: rect.minY + bh * 0.60)
        let rCenter = CGPoint(x: rect.minX + bw * 0.83, y: rect.minY + bh * 0.56)
        let lDia = bw * 0.165
        let rDia = bw * 0.185

        drawSquintEye(in: &ctx, center: lCenter, diameter: lDia, hoodAngleDeg: 16, pupilShift: CGPoint(x: lDia * 0.22, y: scanY))
        drawSquintEye(in: &ctx, center: rCenter, diameter: rDia, hoodAngleDeg: -10, pupilShift: CGPoint(x: rDia * 0.20, y: scanY))

        // Furrowed V-angle concentration brows
        let browStyle = StrokeStyle(lineWidth: max(1.4, bw * 0.034), lineCap: .round)
        var lb = Path()
        lb.move(to: CGPoint(x: lCenter.x - lDia * 0.64, y: lCenter.y - lDia * 0.34))
        lb.addLine(to: CGPoint(x: lCenter.x + lDia * 0.56, y: lCenter.y - lDia * 0.02))
        var rb = Path()
        rb.move(to: CGPoint(x: rCenter.x - rDia * 0.52, y: rCenter.y - rDia * 0.10))
        rb.addLine(to: CGPoint(x: rCenter.x + rDia * 0.62, y: rCenter.y - rDia * 0.42))
        ctx.stroke(lb, with: .color(inkColor), style: browStyle)
        ctx.stroke(rb, with: .color(inkColor), style: browStyle)

        // Tight downward concentration frown (`⌒`)
        var frown = Path()
        frown.move(to: CGPoint(x: rect.minX + bw * 0.68, y: rect.minY + bh * 0.80))
        frown.addQuadCurve(
            to: CGPoint(x: rect.minX + bw * 0.81, y: rect.minY + bh * 0.81),
            control: CGPoint(x: rect.minX + bw * 0.745, y: rect.minY + bh * 0.73)
        )
        ctx.stroke(frown, with: .color(inkColor), style: StrokeStyle(lineWidth: max(1.4, bw * 0.032), lineCap: .round))

        // Crisp cool-grey `{ }` code braces right beside its squinting eyes!
        let braceAlpha = 0.74 + 0.24 * Foundation.sin(t * 4.5)
        let braceText = Text("{ }")
            .font(.system(size: max(10, s * 0.22), weight: .semibold, design: .rounded))
            .foregroundColor(Color(red: 0.62, green: 0.65, blue: 0.70).opacity(braceAlpha))
        ctx.draw(braceText, at: CGPoint(x: rect.maxX + s * 0.135, y: rect.minY + bh * 0.56))
    }

    // MARK: - 4. Celebrating Pose (Joyful Airborne Jump + Huge Open Grin + 7 Geometric Confetti)

    private func drawCelebratingPose(in ctx: inout GraphicsContext, cx: CGFloat, cy: CGFloat, s: CGFloat, time t: TimeInterval) {
        let jumpPhase = abs(Foundation.sin(t * 6.5))
        let lift = CGFloat(jumpPhase) * s * 0.095 + s * 0.045
        let tilt = Foundation.sin(t * 6.5) * 4.5

        let bw = s * 0.60
        let bh = bw / 0.95
        let shadowScale = CGFloat(1.0 - jumpPhase * 0.20)
        drawAmbientGlow(in: &ctx, center: CGPoint(x: cx, y: cy - lift * 0.5), radius: s * 0.46, opacity: 0.30)
        drawGroundShadow(in: &ctx, cx: cx, y: cy + s * 0.39, width: bw * 0.72 * shadowScale, height: s * 0.085 * shadowScale, opacity: 0.36)

        // 7 Flat Geometric Confetti Shapes (exact 3-color warm palette, zero outlines!)
        drawGeometricConfetti(in: &ctx, cx: cx, cy: cy - lift * 0.4, s: s, time: t)

        var bodyCtx = ctx
        bodyCtx.translateBy(x: cx, y: cy - lift)
        bodyCtx.rotate(by: .degrees(tilt))
        let rect = CGRect(x: -bw * 0.5, y: -bh * 0.52, width: bw, height: bh)
        let body = makeUprightBeanPath(in: rect)
        fillBean(in: &bodyCtx, path: body, rect: rect)

        // Close-set cheek-squished joyful white eyes (no eyebrows!)
        let lCenter = CGPoint(x: rect.minX + bw * 0.35, y: rect.minY + bh * 0.33)
        let rCenter = CGPoint(x: rect.minX + bw * 0.64, y: rect.minY + bh * 0.29)
        drawCheekSquishedEye(in: &bodyCtx, center: lCenter, diameter: bw * 0.225, pupilOffset: CGPoint(x: bw * 0.022, y: bh * 0.02))
        drawCheekSquishedEye(in: &bodyCtx, center: rCenter, diameter: bw * 0.255, pupilOffset: CGPoint(x: -bw * 0.022, y: bh * 0.02))

        // Huge goofy wide curved open grin + soft coral tongue!
        drawBigGoofyGrin(in: &bodyCtx, rect: rect)
    }

    // MARK: - 5. Sleeping Pose (Cozy Slumped Puddle + Heavy Droopy Eyelids + Bold Zzz)

    private func drawSleepingPose(in ctx: inout GraphicsContext, cx: CGFloat, cy: CGFloat, s: CGFloat, time t: TimeInterval) {
        let breathe = CGFloat(Foundation.sin(t * 1.8)) * s * 0.016
        let bw = s * 0.78
        let bh = bw / 1.52
        let rect = CGRect(x: cx - bw * 0.5, y: cy + s * 0.08 + breathe - bh * 0.5, width: bw, height: bh)

        drawAmbientGlow(in: &ctx, center: CGPoint(x: cx, y: rect.midY), radius: s * 0.38, opacity: 0.14)
        drawGroundShadow(in: &ctx, cx: cx, y: rect.maxY + s * 0.01, width: bw * 0.94, height: s * 0.085, opacity: 0.44)

        let body = makeSleepingBeanPath(in: rect)
        fillBean(in: &ctx, path: body, rect: rect)

        // Subtle peach highlight on slumped right slope
        var specCtx = ctx
        specCtx.translateBy(x: rect.minX + bw * 0.85, y: rect.minY + bh * 0.40)
        specCtx.rotate(by: .degrees(32))
        specCtx.fill(
            Path(capsuleIn: CGRect(x: -bw * 0.042, y: -bh * 0.022, width: bw * 0.084, height: bh * 0.044)),
            with: .color(theme.specularColor.opacity(0.48))
        )

        // Heavy droopy half-closed eyelids on the taller left dome
        let lCenter = CGPoint(x: rect.minX + bw * 0.24, y: rect.minY + bh * 0.49)
        let rCenter = CGPoint(x: rect.minX + bw * 0.47, y: rect.minY + bh * 0.45)
        drawDroopyEye(in: &ctx, center: lCenter, diameter: bw * 0.165, lidFraction: 0.60, tiltDeg: -7)
        drawDroopyEye(in: &ctx, center: rCenter, diameter: bw * 0.188, lidFraction: 0.60, tiltDeg: -7)

        // Tiny tilted sleeping "o" mouth
        var mouthCtx = ctx
        mouthCtx.translateBy(x: rect.minX + bw * 0.365, y: rect.minY + bh * 0.69)
        mouthCtx.rotate(by: .degrees(-10))
        mouthCtx.fill(
            Path(ellipseIn: CGRect(x: -bw * 0.040, y: -bh * 0.042, width: bw * 0.080, height: bh * 0.084)),
            with: .color(inkColor)
        )

        // 3 bold crisp geometric sans-serif Z letters drifting diagonally up-right
        let zScales: [CGFloat] = [0.115, 0.155, 0.200]
        for i in 0..<3 {
            let phase = (t * 0.36 + Double(i) * 0.33).truncatingRemainder(dividingBy: 1.0)
            let x = rect.minX + bw * (0.56 + CGFloat(i) * 0.15 + CGFloat(phase) * 0.06)
            let y = rect.minY - s * (0.01 + CGFloat(i) * 0.11 + CGFloat(phase) * 0.07)
            let alpha = 0.48 + 0.48 * Foundation.sin(phase * .pi)
            let zTxt = Text("Z")
                .font(.system(size: max(8, s * zScales[i]), weight: .bold, design: .rounded))
                .foregroundColor(Color(red: 0.77, green: 0.79, blue: 0.81).opacity(alpha))
            ctx.draw(zTxt, at: CGPoint(x: x, y: y))
        }
    }

    // MARK: - 6. Poked / Error / Dizzy Interactive Poses

    private func drawPokedPose(in ctx: inout GraphicsContext, cx: CGFloat, cy: CGFloat, s: CGFloat, time t: TimeInterval) {
        let bounce = CGFloat(abs(Foundation.sin(t * 10.0))) * s * 0.085
        let tilt = Foundation.sin(t * 12.0) * 7.5
        let bw = s * 0.64
        let bh = bw / 0.96

        drawAmbientGlow(in: &ctx, center: CGPoint(x: cx, y: cy - bounce), radius: s * 0.44, opacity: 0.28)
        drawGroundShadow(in: &ctx, cx: cx, y: cy + s * 0.38, width: bw * 0.76, height: s * 0.09, opacity: 0.38)

        var bodyCtx = ctx
        bodyCtx.translateBy(x: cx, y: cy - bounce)
        bodyCtx.rotate(by: .degrees(tilt))
        let rect = CGRect(x: -bw * 0.5, y: -bh * 0.52, width: bw, height: bh)
        fillBean(in: &bodyCtx, path: makeUprightBeanPath(in: rect), rect: rect)

        drawCheekSquishedEye(in: &bodyCtx, center: CGPoint(x: rect.minX + bw * 0.35, y: rect.minY + bh * 0.35), diameter: bw * 0.225, pupilOffset: CGPoint(x: bw * 0.02, y: bh * 0.01))
        drawCheekSquishedEye(in: &bodyCtx, center: CGPoint(x: rect.minX + bw * 0.65, y: rect.minY + bh * 0.31), diameter: bw * 0.260, pupilOffset: CGPoint(x: -bw * 0.02, y: bh * 0.01))
        drawBigGoofyGrin(in: &bodyCtx, rect: rect)
    }

    private func drawErrorPose(in ctx: inout GraphicsContext, cx: CGFloat, cy: CGFloat, s: CGFloat, time t: TimeInterval) {
        let shiver = CGFloat(Foundation.sin(t * 24.0)) * s * 0.016
        let bw = s * 0.64
        let bh = bw / 0.955
        let rect = CGRect(x: cx + shiver - bw * 0.5, y: cy - bh * 0.52, width: bw, height: bh)

        drawAmbientGlow(in: &ctx, center: CGPoint(x: cx, y: cy), radius: s * 0.44, opacity: 0.26, overrideColor: Color(red: 1.0, green: 0.34, blue: 0.32))
        drawGroundShadow(in: &ctx, cx: cx, y: cy + s * 0.38, width: bw * 0.80, height: s * 0.09, opacity: 0.42)

        fillBean(in: &ctx, path: makeUprightBeanPath(in: rect), rect: rect)

        // Comical shocked uneven wide eyes (small pinpoint pupils!)
        let lCenter = CGPoint(x: rect.minX + bw * 0.34, y: rect.minY + bh * 0.42)
        let rCenter = CGPoint(x: rect.minX + bw * 0.68, y: rect.minY + bh * 0.37)
        let lDia = bw * 0.21
        let rDia = bw * 0.295
        ctx.fill(Path(ellipseIn: CGRect(x: lCenter.x - lDia * 0.5, y: lCenter.y - lDia * 0.5, width: lDia, height: lDia)), with: .color(scleraColor))
        ctx.fill(Path(ellipseIn: CGRect(x: rCenter.x - rDia * 0.5, y: rCenter.y - rDia * 0.5, width: rDia, height: rDia)), with: .color(scleraColor))
        let lp = bw * 0.070
        let rp = bw * 0.080
        ctx.fill(Path(ellipseIn: CGRect(x: lCenter.x - lp * 0.5, y: lCenter.y - lp * 0.5, width: lp, height: lp)), with: .color(inkColor))
        ctx.fill(Path(ellipseIn: CGRect(x: rCenter.x - rp * 0.5, y: rCenter.y - rp * 0.5, width: rp, height: rp)), with: .color(inkColor))

        // Wavy panic squiggle mouth
        var squiggle = Path()
        let my = rect.minY + bh * 0.64
        squiggle.move(to: CGPoint(x: rect.minX + bw * 0.38, y: my))
        squiggle.addCurve(
            to: CGPoint(x: rect.minX + bw * 0.52, y: my),
            control1: CGPoint(x: rect.minX + bw * 0.42, y: my - bh * 0.05),
            control2: CGPoint(x: rect.minX + bw * 0.48, y: my + bh * 0.05)
        )
        squiggle.addCurve(
            to: CGPoint(x: rect.minX + bw * 0.66, y: my - bh * 0.01),
            control1: CGPoint(x: rect.minX + bw * 0.56, y: my - bh * 0.05),
            control2: CGPoint(x: rect.minX + bw * 0.62, y: my + bh * 0.04)
        )
        ctx.stroke(squiggle, with: .color(inkColor), style: StrokeStyle(lineWidth: max(1.5, bw * 0.038), lineCap: .round))

        // Crisp coral exclamation alert `!`
        let alertTxt = Text("!")
            .font(.system(size: max(11, s * 0.25), weight: .black, design: .rounded))
            .foregroundColor(Color(red: 1.0, green: 0.36, blue: 0.34))
        ctx.draw(alertTxt, at: CGPoint(x: rect.maxX + s * 0.07, y: rect.minY + s * 0.06))
    }

    private func drawDizzyPose(in ctx: inout GraphicsContext, cx: CGFloat, cy: CGFloat, s: CGFloat, time t: TimeInterval) {
        let tilt = Foundation.sin(t * 8.0) * 11.0
        let bob = CGFloat(Foundation.sin(t * 4.0)) * s * 0.03
        let bw = s * 0.64
        let bh = bw / 0.955

        drawAmbientGlow(in: &ctx, center: CGPoint(x: cx, y: cy + bob), radius: s * 0.44, opacity: 0.24)
        drawGroundShadow(in: &ctx, cx: cx, y: cy + s * 0.38, width: bw * 0.80, height: s * 0.09, opacity: 0.40)

        var bodyCtx = ctx
        bodyCtx.translateBy(x: cx, y: cy + bob)
        bodyCtx.rotate(by: .degrees(tilt))
        let rect = CGRect(x: -bw * 0.5, y: -bh * 0.52, width: bw, height: bh)
        fillBean(in: &bodyCtx, path: makeUprightBeanPath(in: rect), rect: rect)

        // Spinning crisp charcoal @ @ spirals inside the big asymmetric white eyes!
        let eyes: [(CGPoint, CGFloat, Double)] = [
            (CGPoint(x: rect.minX + bw * 0.346, y: rect.minY + bh * 0.44), bw * 0.236, 1.0),
            (CGPoint(x: rect.minX + bw * 0.674, y: rect.minY + bh * 0.38), bw * 0.282, -1.0)
        ]
        for (center, dia, dir) in eyes {
            bodyCtx.fill(Path(ellipseIn: CGRect(x: center.x - dia * 0.5, y: center.y - dia * 0.5, width: dia, height: dia)), with: .color(scleraColor))
            var spiral = Path()
            let maxR = dia * 0.36
            let steps = 22
            for step in 0...steps {
                let frac = Double(step) / Double(steps)
                let angle = frac * 3.4 * .pi + t * 8.5 * dir
                let rad = maxR * CGFloat(0.12 + frac * 0.88)
                let pt = CGPoint(
                    x: center.x + CGFloat(Foundation.cos(angle)) * rad,
                    y: center.y + CGFloat(Foundation.sin(angle)) * rad
                )
                if step == 0 { spiral.move(to: pt) } else { spiral.addLine(to: pt) }
            }
            bodyCtx.stroke(spiral, with: .color(inkColor), style: StrokeStyle(lineWidth: max(1.1, bw * 0.025), lineCap: .round))
        }

        // Tiny wobbly "o" mouth
        bodyCtx.fill(
            Path(ellipseIn: CGRect(x: rect.minX + bw * 0.49, y: rect.minY + bh * 0.61, width: bw * 0.095, height: bh * 0.075)),
            with: .color(inkColor)
        )
    }

    // MARK: - Organic Lineless Bean Paths & Shared Drawing Primitives

    /// Iconic upright asymmetric pear-bean / soft-mango silhouette from the winning Lumi Ember spec.
    private func makeUprightBeanPath(in rect: CGRect) -> Path {
        func pt(_ nx: CGFloat, _ ny: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + nx * rect.width, y: rect.minY + ny * rect.height)
        }
        var p = Path()
        p.move(to: pt(0.51, 0.00))
        p.addCurve(to: pt(0.91, 0.22), control1: pt(0.71, 0.00), control2: pt(0.84, 0.09))
        p.addCurve(to: pt(1.00, 0.54), control1: pt(0.98, 0.33), control2: pt(1.01, 0.44))
        p.addCurve(to: pt(0.84, 0.85), control1: pt(0.99, 0.67), control2: pt(0.93, 0.77))
        p.addCurve(to: pt(0.40, 1.00), control1: pt(0.73, 0.95), control2: pt(0.56, 1.01))
        p.addCurve(to: pt(0.00, 0.74), control1: pt(0.18, 0.99), control2: pt(0.01, 0.90))
        p.addCurve(to: pt(0.10, 0.40), control1: pt(-0.01, 0.60), control2: pt(0.07, 0.50))
        p.addCurve(to: pt(0.20, 0.14), control1: pt(0.12, 0.28), control2: pt(0.14, 0.20))
        p.addCurve(to: pt(0.51, 0.00), control1: pt(0.28, 0.04), control2: pt(0.39, 0.00))
        p.closeSubpath()
        return p
    }

    /// Wide squashed horizontal leaning-right bean for hyper-focused Coding state.
    private func makeWorkingBeanPath(in rect: CGRect) -> Path {
        func pt(_ nx: CGFloat, _ ny: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + nx * rect.width, y: rect.minY + ny * rect.height)
        }
        var p = Path()
        p.move(to: pt(0.66, 0.00))
        p.addCurve(to: pt(0.98, 0.38), control1: pt(0.84, 0.00), control2: pt(0.96, 0.15))
        p.addCurve(to: pt(0.92, 0.88), control1: pt(1.01, 0.60), control2: pt(0.99, 0.78))
        p.addCurve(to: pt(0.46, 1.00), control1: pt(0.84, 0.99), control2: pt(0.66, 1.01))
        p.addCurve(to: pt(0.04, 0.88), control1: pt(0.24, 0.99), control2: pt(0.10, 0.98))
        p.addCurve(to: pt(0.06, 0.36), control1: pt(-0.02, 0.74), control2: pt(-0.01, 0.50))
        p.addCurve(to: pt(0.66, 0.00), control1: pt(0.16, 0.16), control2: pt(0.42, 0.00))
        p.closeSubpath()
        return p
    }

    /// Wide cozy slumped puddle-bean (taller rounded head dome on left, melting smoothly down-right).
    private func makeSleepingBeanPath(in rect: CGRect) -> Path {
        func pt(_ nx: CGFloat, _ ny: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + nx * rect.width, y: rect.minY + ny * rect.height)
        }
        var p = Path()
        p.move(to: pt(0.32, 0.00))
        p.addCurve(to: pt(0.66, 0.24), control1: pt(0.49, 0.00), control2: pt(0.58, 0.11))
        p.addCurve(to: pt(0.98, 0.56), control1: pt(0.80, 0.34), control2: pt(0.95, 0.38))
        p.addCurve(to: pt(0.90, 0.94), control1: pt(1.02, 0.72), control2: pt(0.98, 0.88))
        p.addCurve(to: pt(0.42, 1.00), control1: pt(0.80, 1.00), control2: pt(0.62, 1.01))
        p.addCurve(to: pt(0.05, 0.86), control1: pt(0.22, 0.99), control2: pt(0.10, 0.97))
        p.addCurve(to: pt(0.02, 0.40), control1: pt(-0.02, 0.72), control2: pt(-0.01, 0.54))
        p.addCurve(to: pt(0.32, 0.00), control1: pt(0.07, 0.16), control2: pt(0.17, 0.00))
        p.closeSubpath()
        return p
    }

    private func fillBean(in ctx: inout GraphicsContext, path: Path, rect: CGRect) {
        // Warm diagonal Headspace gradient (top-right warm tangerine -> mid -> bottom-left coral)
        ctx.fill(
            path,
            with: .linearGradient(
                Gradient(stops: [
                    .init(color: theme.bodyTop, location: 0.0),
                    .init(color: theme.bodyMid, location: 0.58),
                    .init(color: theme.bodyBottom, location: 1.0)
                ]),
                startPoint: CGPoint(x: rect.maxX * 0.85 + rect.minX * 0.15, y: rect.minY),
                endPoint: CGPoint(x: rect.minX * 0.85 + rect.maxX * 0.15, y: rect.maxY)
            )
        )
    }

    private func drawAmbientGlow(in ctx: inout GraphicsContext, center: CGPoint, radius: CGFloat, opacity: Double, overrideColor: Color? = nil) {
        let c = (overrideColor ?? theme.bodyTop).opacity(opacity)
        let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        ctx.fill(
            Path(ellipseIn: rect),
            with: .radialGradient(
                Gradient(colors: [c, c.opacity(0)]),
                center: center,
                startRadius: radius * 0.12,
                endRadius: radius
            )
        )
    }

    private func drawGroundShadow(in ctx: inout GraphicsContext, cx: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, opacity: Double) {
        ctx.fill(
            Path(ellipseIn: CGRect(x: cx - width * 0.5, y: y - height * 0.5, width: width, height: height)),
            with: .color(Color(red: 0.035, green: 0.045, blue: 0.070).opacity(opacity))
        )
    }

    private func drawSimpleAsymEye(in ctx: inout GraphicsContext, center: CGPoint, diameter: CGFloat, pupilOffset: CGPoint, blinking: Bool) {
        if blinking {
            var p = Path()
            p.move(to: CGPoint(x: center.x - diameter * 0.46, y: center.y))
            p.addLine(to: CGPoint(x: center.x + diameter * 0.46, y: center.y))
            ctx.stroke(p, with: .color(inkColor), style: StrokeStyle(lineWidth: max(1.5, diameter * 0.18), lineCap: .round))
            return
        }
        ctx.fill(
            Path(ellipseIn: CGRect(x: center.x - diameter * 0.5, y: center.y - diameter * 0.5, width: diameter, height: diameter)),
            with: .color(scleraColor)
        )
        let pDia = diameter * 0.435
        ctx.fill(
            Path(ellipseIn: CGRect(
                x: center.x + pupilOffset.x - pDia * 0.5,
                y: center.y + pupilOffset.y - pDia * 0.5,
                width: pDia,
                height: pDia
            )),
            with: .color(inkColor)
        )
    }

    private func drawSquintEye(in ctx: inout GraphicsContext, center: CGPoint, diameter: CGFloat, hoodAngleDeg: Double, pupilShift: CGPoint) {
        let r = diameter * 0.5
        let circle = Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: diameter, height: diameter))
        // Clip top slice using a rotated half-plane rectangle below the angled brow line
        ctx.drawLayer { layer in
            var clipRect = Path()
            clipRect.addRect(CGRect(x: -diameter, y: -r * 0.14, width: diameter * 2, height: diameter * 1.5))
            var xform = CGAffineTransform(translationX: center.x, y: center.y)
            xform = xform.rotated(by: CGFloat(hoodAngleDeg * .pi / 180.0))
            layer.clip(to: clipRect.applying(xform))
            layer.fill(circle, with: .color(scleraColor))

            let pDia = diameter * 0.46
            layer.fill(
                Path(ellipseIn: CGRect(
                    x: center.x + pupilShift.x - pDia * 0.5,
                    y: center.y + pupilShift.y + r * 0.08 - pDia * 0.5,
                    width: pDia,
                    height: pDia
                )),
                with: .color(inkColor)
            )
        }
    }

    private func drawCheekSquishedEye(in ctx: inout GraphicsContext, center: CGPoint, diameter: CGFloat, pupilOffset: CGPoint) {
        let r = diameter * 0.5
        let circle = Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: diameter, height: diameter))
        ctx.drawLayer { layer in
            // Flatten bottom ~22% from joyful cheek-squish!
            let clip = Path(CGRect(x: center.x - r * 1.2, y: center.y - r * 1.2, width: diameter * 1.2, height: diameter * 0.88))
            layer.clip(to: clip)
            layer.fill(circle, with: .color(scleraColor))
            let pDia = diameter * 0.43
            layer.fill(
                Path(ellipseIn: CGRect(
                    x: center.x + pupilOffset.x - pDia * 0.5,
                    y: center.y + pupilOffset.y - pDia * 0.5,
                    width: pDia,
                    height: pDia
                )),
                with: .color(inkColor)
            )
        }
    }

    private func drawDroopyEye(in ctx: inout GraphicsContext, center: CGPoint, diameter: CGFloat, lidFraction: CGFloat, tiltDeg: Double) {
        let r = diameter * 0.5
        let circle = Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: diameter, height: diameter))
        let lidY = -r + diameter * lidFraction

        var eyeCtx = ctx
        eyeCtx.translateBy(x: center.x, y: center.y)
        eyeCtx.rotate(by: .degrees(tiltDeg))

        let localCircle = Path(ellipseIn: CGRect(x: -r, y: -r, width: diameter, height: diameter))
        eyeCtx.drawLayer { layer in
            layer.clip(to: localCircle)
            // Bottom white sclera + tiny half-hidden pupil
            layer.fill(localCircle, with: .color(scleraColor))
            let pDia = diameter * 0.42
            layer.fill(
                Path(ellipseIn: CGRect(x: -pDia * 0.5, y: lidY - pDia * 0.25, width: pDia, height: pDia)),
                with: .color(inkColor)
            )
            // Heavy droopy burnt-orange upper eyelid covering top ~60%
            layer.fill(
                Path(CGRect(x: -r * 1.1, y: -r * 1.1, width: diameter * 1.1, height: r * 1.1 + lidY)),
                with: .color(theme.eyelidColor)
            )
            // Crisp charcoal crease line along eyelid bottom edge
            var crease = Path()
            crease.move(to: CGPoint(x: -r * 1.05, y: lidY))
            crease.addQuadCurve(to: CGPoint(x: r * 1.05, y: lidY), control: CGPoint(x: 0, y: lidY + r * 0.14))
            layer.stroke(crease, with: .color(inkColor), style: StrokeStyle(lineWidth: max(1.2, diameter * 0.12), lineCap: .round))
        }
        _ = circle
    }

    private func drawBigGoofyGrin(in ctx: inout GraphicsContext, rect: CGRect) {
        let bw = rect.width
        let bh = rect.height
        var mouth = Path()
        mouth.move(to: CGPoint(x: rect.minX + bw * 0.26, y: rect.minY + bh * 0.52))
        mouth.addQuadCurve(
            to: CGPoint(x: rect.minX + bw * 0.80, y: rect.minY + bh * 0.46),
            control: CGPoint(x: rect.minX + bw * 0.54, y: rect.minY + bh * 0.54)
        )
        mouth.addCurve(
            to: CGPoint(x: rect.minX + bw * 0.26, y: rect.minY + bh * 0.52),
            control1: CGPoint(x: rect.minX + bw * 0.78, y: rect.minY + bh * 0.82),
            control2: CGPoint(x: rect.minX + bw * 0.28, y: rect.minY + bh * 0.84)
        )
        mouth.closeSubpath()

        ctx.drawLayer { layer in
            layer.clip(to: mouth)
            layer.fill(mouth, with: .color(cavityColor))
            // Soft coral-pink tongue dome in bottom ~38% of mouth
            layer.fill(
                Path(ellipseIn: CGRect(
                    x: rect.minX + bw * 0.36,
                    y: rect.minY + bh * 0.65,
                    width: bw * 0.36,
                    height: bh * 0.24
                )),
                with: .color(tongueColor)
            )
        }
    }

    private func drawGeometricConfetti(in ctx: inout GraphicsContext, cx: CGFloat, cy: CGFloat, s: CGFloat, time t: TimeInterval) {
        let amber = Color(red: 0.953, green: 0.569, blue: 0.224)  // #F39139
        let coral = Color(red: 0.961, green: 0.424, blue: 0.306)  // #F56C4E
        let cream = Color(red: 0.988, green: 0.867, blue: 0.663)  // #FCDDA9

        let burst = CGFloat(0.92 + 0.12 * Foundation.sin(t * 7.0))
        let sway = CGFloat(Foundation.sin(t * 5.0)) * s * 0.02

        // 1. Upper-left amber circle
        let c1 = CGPoint(x: cx - s * 0.36 * burst, y: cy - s * 0.28 * burst + sway)
        ctx.fill(Path(ellipseIn: CGRect(x: c1.x - s * 0.042, y: c1.y - s * 0.042, width: s * 0.084, height: s * 0.084)), with: .color(amber))

        // 2. Mid-left tilted coral bar
        var sh2 = ctx
        sh2.translateBy(x: cx - s * 0.40 * burst, y: cy - s * 0.03 - sway)
        sh2.rotate(by: .degrees(-24 + Foundation.sin(t * 4.0) * 10))
        sh2.fill(Path(roundedRect: CGRect(x: -s * 0.055, y: -s * 0.024, width: s * 0.11, height: s * 0.048), cornerRadius: 1.5), with: .color(coral))

        // 3. Lower-left pale cream triangle
        var sh3 = ctx
        sh3.translateBy(x: cx - s * 0.35 * burst, y: cy + s * 0.21 + sway)
        sh3.rotate(by: .degrees(18))
        var tri = Path()
        tri.move(to: CGPoint(x: 0, y: -s * 0.048))
        tri.addLine(to: CGPoint(x: s * 0.045, y: s * 0.038))
        tri.addLine(to: CGPoint(x: -s * 0.045, y: s * 0.038))
        tri.closeSubpath()
        sh3.fill(tri, with: .color(cream))

        // 4. Upper-right slanted coral narrow bar
        var sh4 = ctx
        sh4.translateBy(x: cx + s * 0.34 * burst, y: cy - s * 0.29 * burst - sway)
        sh4.rotate(by: .degrees(32))
        sh4.fill(Path(roundedRect: CGRect(x: -s * 0.052, y: -s * 0.020, width: s * 0.104, height: s * 0.040), cornerRadius: 1.5), with: .color(coral))

        // 5. Upper-mid-right pale cream bar
        var sh5 = ctx
        sh5.translateBy(x: cx + s * 0.41 * burst, y: cy - s * 0.07 + sway)
        sh5.rotate(by: .degrees(-18))
        sh5.fill(Path(roundedRect: CGRect(x: -s * 0.046, y: -s * 0.024, width: s * 0.092, height: s * 0.048), cornerRadius: 1.5), with: .color(cream))

        // 6. Lower-mid-right amber triangle
        var sh6 = ctx
        sh6.translateBy(x: cx + s * 0.38 * burst, y: cy + s * 0.14 - sway)
        sh6.rotate(by: .degrees(-35))
        sh6.fill(tri, with: .color(amber))

        // 7. Lower-right coral circle
        let c7 = CGPoint(x: cx + s * 0.31 * burst, y: cy + s * 0.29 + sway)
        ctx.fill(Path(ellipseIn: CGRect(x: c7.x - s * 0.036, y: c7.y - s * 0.036, width: s * 0.072, height: s * 0.072)), with: .color(coral))
    }

    private func makeFourPointSpark(center: CGPoint, radius: CGFloat) -> Path {
        var p = Path()
        let inner = radius * 0.34
        for i in 0..<8 {
            let angle = Double(i) * (.pi / 4.0) - .pi / 2.0
            let r = (i % 2 == 0) ? radius : inner
            let pt = CGPoint(
                x: center.x + CGFloat(Foundation.cos(angle)) * r,
                y: center.y + CGFloat(Foundation.sin(angle)) * r
            )
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        p.closeSubpath()
        return p
    }
}

private extension Path {
    init(capsuleIn rect: CGRect) {
        self.init(roundedRect: rect, cornerRadius: min(rect.width, rect.height) * 0.5)
    }
}
