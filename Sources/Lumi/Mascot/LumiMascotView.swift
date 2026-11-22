import SwiftUI

/// Original animated Space-Ghost / Capsule mascot "Lumi" drawn with crisp SwiftUI Canvas vectors.
/// Uses adaptive frame rates (30fps when active/expanded, 6fps collapsed working, 1fps idle)
/// to stay silky-smooth while keeping CPU usage near 0% in the background.
struct LumiMascotView: View {
    let mood: MascotMood
    let theme: MascotTheme
    var size: CGFloat = 44
    var lookOffset: CGSize = .zero   // normalized -1...1 gaze vector
    var isCompact: Bool = false
    var isActiveSurface: Bool = true
    var fixedTime: TimeInterval? = nil
    var onPoke: (() -> Void)? = nil

    private var frameInterval: TimeInterval {
        switch mood {
        case .celebrating, .poked, .dizzy:
            return 1.0 / 30.0
        case .working, .error:
            return isActiveSurface ? (1.0 / 24.0) : (1.0 / 5.0)
        case .waitingUnread:
            return isActiveSurface ? (1.0 / 15.0) : (1.0 / 2.0)
        case .sleeping:
            return isActiveSurface ? (1.0 / 12.0) : 1.0
        }
    }

    var body: some View {
        Group {
            if let fixedTime {
                Canvas { ctx, canvasSize in
                    drawLumi(in: &ctx, size: canvasSize, time: fixedTime)
                }
                .frame(width: size, height: size)
            } else {
                TimelineView(.animation(minimumInterval: frameInterval)) { timeline in
                    let t = timeline.date.timeIntervalSinceReferenceDate
                    Canvas { ctx, canvasSize in
                        drawLumi(in: &ctx, size: canvasSize, time: t)
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

    private func drawLumi(in ctx: inout GraphicsContext, size: CGSize, time t: TimeInterval) {
        let w = size.width
        let h = size.height
        let s = min(w, h)
        let cx = w * 0.5
        let cy = h * 0.54

        // Vertical float / bounce offset
        let bob: CGFloat
        let tiltDeg: Double
        switch mood {
        case .celebrating:
            bob = -abs(sin(t * 7.5)) * s * 0.11
            tiltDeg = sin(t * 7.5) * 6.0
        case .poked:
            bob = -abs(sin(t * 10.0)) * s * 0.08
            tiltDeg = sin(t * 12.0) * 8.0
        case .dizzy:
            bob = sin(t * 4.0) * s * 0.03
            tiltDeg = sin(t * 9.0) * 11.0
        case .working:
            bob = sin(t * 4.2) * s * 0.035
            tiltDeg = sin(t * 2.1) * 2.5
        case .error:
            bob = sin(t * 16.0) * s * 0.015
            tiltDeg = sin(t * 18.0) * 3.0
        case .waitingUnread:
            bob = sin(t * 3.2) * s * 0.045
            tiltDeg = 0
        case .sleeping:
            bob = sin(t * 1.5) * s * 0.03
            tiltDeg = -3.0
        }

        // Soft ambient glow + grounded bounce-reactive floor shadow behind Lumi
        if !isCompact {
            let liftRatio = min(1.0, max(0.0, Double(-bob / max(1.0, s * 0.12))))
            let shadowW = s * CGFloat(0.46 - liftRatio * 0.10)
            let shadowH = s * CGFloat(0.11 - liftRatio * 0.025)
            let shadowRect = CGRect(
                x: cx - shadowW * 0.5,
                y: cy + s * 0.36 - shadowH * 0.5,
                width: shadowW,
                height: shadowH
            )
            ctx.fill(
                Path(ellipseIn: shadowRect),
                with: .color(Color.black.opacity(0.38 - liftRatio * 0.16))
            )

            let glowRect = CGRect(x: cx - s * 0.44, y: cy + bob - s * 0.40, width: s * 0.88, height: s * 0.88)
            let glowColor: Color = (mood == .error)
                ? Color(red: 1.0, green: 0.35, blue: 0.35).opacity(0.30)
                : theme.bodyTop.opacity(mood == .sleeping ? 0.15 : 0.30)
            ctx.fill(
                Path(ellipseIn: glowRect),
                with: .radialGradient(
                    Gradient(colors: [glowColor, glowColor.opacity(0)]),
                    center: CGPoint(x: cx, y: cy + bob),
                    startRadius: s * 0.06,
                    endRadius: s * 0.46
                )
            )
        }

        // Apply subtle tilt + bob transform for Lumi body
        var bodyCtx = ctx
        bodyCtx.translateBy(x: cx, y: cy + bob)
        bodyCtx.rotate(by: .degrees(tiltDeg))

        // 1. Headphones (behind/over head when working!)
        if mood == .working && !isCompact {
            drawHeadphones(in: &bodyCtx, s: s, time: t)
        }

        // 2. Capsule-Ghost Body Path (rounded dome + subtle floating wave skirt)
        let bw = s * 0.66
        let bh = s * 0.68
        let wavePhase = t * (mood == .working ? 6.0 : 2.6)
        let bodyPath = makeGhostCapsulePath(w: bw, h: bh, wavePhase: wavePhase)

        bodyCtx.fill(
            bodyPath,
            with: .linearGradient(
                Gradient(colors: [theme.bodyTop, theme.bodyBottom]),
                startPoint: CGPoint(x: 0, y: -bh * 0.5),
                endPoint: CGPoint(x: 0, y: bh * 0.52)
            )
        )

        // Subtle luminous inner rim & top glossy specular highlight
        bodyCtx.stroke(
            bodyPath,
            with: .color(Color.white.opacity(0.32)),
            lineWidth: max(0.8, s * 0.022)
        )
        let glossRect = CGRect(x: -bw * 0.28, y: -bh * 0.42, width: bw * 0.56, height: bh * 0.16)
        bodyCtx.fill(
            Path(ellipseIn: glossRect),
            with: .linearGradient(
                Gradient(colors: [Color.white.opacity(0.42), Color.white.opacity(0.0)]),
                startPoint: CGPoint(x: 0, y: glossRect.minY),
                endPoint: CGPoint(x: 0, y: glossRect.maxY)
            )
        )

        // 3. Cute little side nubs / floating hands
        let handOffsetY = sin(t * 5.0) * s * 0.02
        if mood == .celebrating {
            // Arms raised cheering!
            let leftArm = CGRect(x: -bw * 0.56, y: -bh * 0.18 + handOffsetY, width: s * 0.11, height: s * 0.15)
            let rightArm = CGRect(x: bw * 0.45, y: -bh * 0.18 - handOffsetY, width: s * 0.11, height: s * 0.15)
            bodyCtx.fill(Path(roundedRect: leftArm, cornerRadius: s * 0.06), with: .color(theme.bodyTop))
            bodyCtx.fill(Path(roundedRect: rightArm, cornerRadius: s * 0.06), with: .color(theme.bodyTop))
        } else if mood == .working && !isCompact {
            // Tiny tapping hands
            let tapL = abs(sin(t * 14.0)) * s * 0.03
            let tapR = abs(cos(t * 14.0)) * s * 0.03
            let leftArm = CGRect(x: -bw * 0.44, y: bh * 0.14 - tapL, width: s * 0.11, height: s * 0.09)
            let rightArm = CGRect(x: bw * 0.33, y: bh * 0.14 - tapR, width: s * 0.11, height: s * 0.09)
            bodyCtx.fill(Path(roundedRect: leftArm, cornerRadius: s * 0.05), with: .color(theme.bodyTop.opacity(0.95)))
            bodyCtx.fill(Path(roundedRect: rightArm, cornerRadius: s * 0.05), with: .color(theme.bodyTop.opacity(0.95)))
        }

        // 4. Curved Dark Glass Space Visor
        let vw = bw * 0.78
        let vh = bh * 0.44
        let visorRect = CGRect(x: -vw * 0.5, y: -bh * 0.21, width: vw, height: vh)
        let visorPath = Path(roundedRect: visorRect, cornerRadius: vh * 0.46)
        bodyCtx.fill(
            visorPath,
            with: .linearGradient(
                Gradient(colors: [Color(red: 0.06, green: 0.07, blue: 0.12), Color(red: 0.11, green: 0.13, blue: 0.20)]),
                startPoint: CGPoint(x: 0, y: visorRect.minY),
                endPoint: CGPoint(x: 0, y: visorRect.maxY)
            )
        )
        bodyCtx.stroke(visorPath, with: .color(Color.white.opacity(0.22)), lineWidth: max(0.7, s * 0.018))

        // Subtle visor glass streak
        let streak = CGRect(x: visorRect.minX + vw * 0.10, y: visorRect.minY + vh * 0.11, width: vw * 0.32, height: vh * 0.15)
        bodyCtx.fill(Path(roundedRect: streak, cornerRadius: vh * 0.08), with: .color(Color.white.opacity(0.16)))

        // 5. Expressive Eyes inside the visor!
        drawEyes(in: &bodyCtx, visorRect: visorRect, s: s, time: t)

        // 6. Cheek blush for happy / poked / error moods
        if mood == .celebrating || mood == .poked || mood == .error {
            let blushColor = mood == .error
                ? Color(red: 1.0, green: 0.32, blue: 0.32).opacity(0.55)
                : Color(red: 1.0, green: 0.48, blue: 0.68).opacity(0.50)
            let bW = vw * 0.18
            let bH = vh * 0.16
            let by = visorRect.maxY - vh * 0.22
            bodyCtx.fill(Path(ellipseIn: CGRect(x: visorRect.minX + vw * 0.09, y: by, width: bW, height: bH)), with: .color(blushColor))
            bodyCtx.fill(Path(ellipseIn: CGRect(x: visorRect.maxX - vw * 0.09 - bW, y: by, width: bW, height: bH)), with: .color(blushColor))
        }

        // 7. Ambient mood accessories (drawn in un-tilted space)
        if !isCompact {
            drawMoodEffects(in: &ctx, cx: cx, cy: cy + bob, s: s, time: t)
        } else if mood == .waitingUnread || mood == .celebrating {
            // Tiny golden star dot on compact notch Lumi
            let starRect = CGRect(x: cx + s * 0.22, y: cy - s * 0.38, width: s * 0.18, height: s * 0.18)
            ctx.fill(Path(ellipseIn: starRect), with: .color(Color(red: 1.0, green: 0.80, blue: 0.22)))
        }
    }

    private func makeGhostCapsulePath(w: CGFloat, h: CGFloat, wavePhase: Double) -> Path {
        var p = Path()
        let halfW = w * 0.5
        let topY = -h * 0.5
        let botY = h * 0.46
        let domeR = halfW

        // Top dome
        p.move(to: CGPoint(x: -halfW, y: topY + domeR))
        p.addArc(
            center: CGPoint(x: 0, y: topY + domeR),
            radius: domeR,
            startAngle: .degrees(180),
            endAngle: .degrees(0),
            clockwise: false
        )
        // Right side down
        p.addLine(to: CGPoint(x: halfW, y: botY - h * 0.08))

        // Gentle 3-scallop floating bottom edge
        let amp = h * 0.055
        let w1 = CGFloat(sin(wavePhase)) * amp * 0.45
        let w2 = CGFloat(cos(wavePhase)) * amp * 0.45
        p.addQuadCurve(
            to: CGPoint(x: halfW * 0.33, y: botY + w1),
            control: CGPoint(x: halfW * 0.72, y: botY + amp + w1)
        )
        p.addQuadCurve(
            to: CGPoint(x: -halfW * 0.33, y: botY - w2),
            control: CGPoint(x: 0, y: botY - amp * 0.55)
        )
        p.addQuadCurve(
            to: CGPoint(x: -halfW, y: botY - h * 0.08),
            control: CGPoint(x: -halfW * 0.72, y: botY + amp - w2)
        )
        p.closeSubpath()
        return p
    }

    private func drawHeadphones(in ctx: inout GraphicsContext, s: CGFloat, time t: TimeInterval) {
        let r = s * 0.375
        var band = Path()
        band.addArc(center: CGPoint(x: 0, y: -s * 0.03), radius: r, startAngle: .degrees(194), endAngle: .degrees(346), clockwise: false)
        ctx.stroke(
            band,
            with: .linearGradient(
                Gradient(colors: [Color.white.opacity(0.68), Color.white.opacity(0.28)]),
                startPoint: CGPoint(x: 0, y: -r),
                endPoint: CGPoint(x: 0, y: 0)
            ),
            style: StrokeStyle(lineWidth: s * 0.052, lineCap: .round)
        )

        let cupW = s * 0.11
        let cupH = s * 0.20
        let pulse = 0.72 + 0.28 * sin(t * 5.0)
        let leftCup = CGRect(x: -r - cupW * 0.36, y: -s * 0.11, width: cupW, height: cupH)
        let rightCup = CGRect(x: r - cupW * 0.64, y: -s * 0.11, width: cupW, height: cupH)
        let cupFill = theme.eyeGlow.opacity(pulse * 0.85)
        ctx.fill(Path(roundedRect: leftCup, cornerRadius: cupW * 0.5), with: .color(cupFill))
        ctx.fill(Path(roundedRect: rightCup, cornerRadius: cupW * 0.5), with: .color(cupFill))
        ctx.stroke(Path(roundedRect: leftCup, cornerRadius: cupW * 0.5), with: .color(Color.white.opacity(0.55)), lineWidth: max(0.7, s * 0.016))
        ctx.stroke(Path(roundedRect: rightCup, cornerRadius: cupW * 0.5), with: .color(Color.white.opacity(0.55)), lineWidth: max(0.7, s * 0.016))
    }

    private func drawEyes(in ctx: inout GraphicsContext, visorRect: CGRect, s: CGFloat, time t: TimeInterval) {
        let eyeColor: Color = (mood == .error) ? Color(red: 1.0, green: 0.45, blue: 0.42) : theme.eyeGlow
        let eyeSpacing = visorRect.width * 0.22
        let baseY = visorRect.midY + visorRect.height * 0.02

        // Gaze offset (subtle scanning when working, cursor tracking otherwise)
        let gx: CGFloat
        let gy: CGFloat
        if mood == .working {
            gx = CGFloat(sin(t * 2.4)) * visorRect.width * 0.08 + lookOffset.width * visorRect.width * 0.06
            gy = lookOffset.height * visorRect.height * 0.08
        } else {
            gx = max(-1, min(1, lookOffset.width)) * visorRect.width * 0.09
            gy = max(-1, min(1, lookOffset.height)) * visorRect.height * 0.10
        }

        let lx = -eyeSpacing + gx
        let rx = eyeSpacing + gx
        let ey = baseY + gy

        switch mood {
        case .sleeping:
            // Soft curved sleeping eyes (u u)
            for ex in [lx, rx] {
                var p = Path()
                let ew = visorRect.width * 0.15
                p.move(to: CGPoint(x: ex - ew * 0.5, y: ey))
                p.addQuadCurve(to: CGPoint(x: ex + ew * 0.5, y: ey), control: CGPoint(x: ex, y: ey + visorRect.height * 0.16))
                ctx.stroke(p, with: .color(eyeColor.opacity(0.8)), style: StrokeStyle(lineWidth: max(1.3, s * 0.042), lineCap: .round))
            }

        case .celebrating, .poked:
            // Joyful ^ ^ smiling eyes!
            for ex in [lx, rx] {
                var p = Path()
                let ew = visorRect.width * 0.17
                p.move(to: CGPoint(x: ex - ew * 0.5, y: ey + visorRect.height * 0.08))
                p.addQuadCurve(to: CGPoint(x: ex + ew * 0.5, y: ey + visorRect.height * 0.08), control: CGPoint(x: ex, y: ey - visorRect.height * 0.20))
                ctx.stroke(p, with: .color(eyeColor), style: StrokeStyle(lineWidth: max(1.6, s * 0.05), lineCap: .round))
            }

        case .error:
            // Worried > < eyes
            let ew = visorRect.width * 0.13
            let eh = visorRect.height * 0.14
            var leftP = Path()
            leftP.move(to: CGPoint(x: lx - ew * 0.5, y: ey - eh))
            leftP.addLine(to: CGPoint(x: lx + ew * 0.5, y: ey))
            leftP.addLine(to: CGPoint(x: lx - ew * 0.5, y: ey + eh))
            var rightP = Path()
            rightP.move(to: CGPoint(x: rx + ew * 0.5, y: ey - eh))
            rightP.addLine(to: CGPoint(x: rx - ew * 0.5, y: ey))
            rightP.addLine(to: CGPoint(x: rx + ew * 0.5, y: ey + eh))
            let style = StrokeStyle(lineWidth: max(1.5, s * 0.048), lineCap: .round, lineJoin: .round)
            ctx.stroke(leftP, with: .color(eyeColor), style: style)
            ctx.stroke(rightP, with: .color(eyeColor), style: style)

        case .dizzy:
            // Crisp spinning @ @ Archimedean spirals with clear dark gaps
            let r = visorRect.height * 0.21
            for (idx, ex) in [lx, rx].enumerated() {
                let dir = idx == 0 ? 1.0 : -1.0
                var spiral = Path()
                let steps = 22
                for step in 0...steps {
                    let frac = Double(step) / Double(steps)
                    let angle = frac * 3.3 * .pi + t * 8.0 * dir
                    let rad = r * CGFloat(0.14 + frac * 0.86)
                    let pt = CGPoint(x: ex + cos(angle) * rad, y: ey + sin(angle) * rad)
                    if step == 0 { spiral.move(to: pt) } else { spiral.addLine(to: pt) }
                }
                ctx.stroke(spiral, with: .color(eyeColor), style: StrokeStyle(lineWidth: max(1.0, s * 0.019), lineCap: .round))
            }

        case .working, .waitingUnread:
            // Natural periodic blink every 3.6s (140ms blink)
            let cycle = t.truncatingRemainder(dividingBy: 3.6)
            let isBlinking = cycle > 3.46
            let eyeW = visorRect.width * 0.145
            let eyeH = isBlinking ? max(1.4, s * 0.035) : visorRect.height * 0.36
            for ex in [lx, rx] {
                let rect = CGRect(x: ex - eyeW * 0.5, y: ey - eyeH * 0.5, width: eyeW, height: eyeH)
                ctx.fill(Path(roundedRect: rect, cornerRadius: eyeW * 0.5), with: .color(eyeColor))
                // Tiny bright catchlight dot
                if !isBlinking && s >= 24 {
                    let dot = CGRect(x: rect.minX + eyeW * 0.2, y: rect.minY + eyeH * 0.14, width: eyeW * 0.34, height: eyeW * 0.34)
                    ctx.fill(Path(ellipseIn: dot), with: .color(Color.white.opacity(0.85)))
                }
            }
        }
    }

    private func drawMoodEffects(in ctx: inout GraphicsContext, cx: CGFloat, cy: CGFloat, s: CGFloat, time t: TimeInterval) {
        switch mood {
        case .sleeping:
            // 3 staggered floating "z / Z / Z" bubbles
            let glyphs = ["z", "Z", "Z"]
            let scales: [CGFloat] = [0.13, 0.17, 0.21]
            for i in 0..<3 {
                let phase = (t * 0.42 + Double(i) * 0.33).truncatingRemainder(dividingBy: 1.0)
                let x = cx + s * (0.24 + CGFloat(phase) * 0.20)
                let y = cy - s * (0.20 + CGFloat(phase) * 0.28)
                let alpha = max(0.0, sin(phase * .pi)) * 0.92
                let text = Text(glyphs[i])
                    .font(.system(size: s * scales[i], weight: .bold, design: .rounded))
                    .foregroundColor(theme.eyeGlow.opacity(alpha))
                ctx.draw(text, at: CGPoint(x: x, y: y))
            }

        case .celebrating:
            // Colorful confetti stars popping around Lumi!
            let colors: [Color] = [
                Color(red: 1.0, green: 0.82, blue: 0.24),
                Color(red: 0.34, green: 0.90, blue: 0.62),
                Color(red: 1.0, green: 0.48, blue: 0.72),
                Color(red: 0.44, green: 0.84, blue: 1.0)
            ]
            for i in 0..<6 {
                let angle = Double(i) * (.pi / 3.0) + t * 2.2
                let radius = s * (0.40 + 0.07 * CGFloat(sin(t * 7.0 + Double(i))))
                let px = cx + cos(angle) * radius
                let py = cy - s * 0.08 + sin(angle) * radius * 0.72
                let d = s * 0.085
                ctx.fill(Path(ellipseIn: CGRect(x: px - d * 0.5, y: py - d * 0.5, width: d, height: d)), with: .color(colors[i % colors.count]))
            }

        case .waitingUnread:
            // Golden floating notification sparkle
            let bounce = CGFloat(sin(t * 4.5)) * s * 0.04
            let sx = cx + s * 0.34
            let sy = cy - s * 0.30 + bounce
            let star = makeStarPath(center: CGPoint(x: sx, y: sy), radius: s * 0.11)
            ctx.fill(star, with: .color(Color(red: 1.0, green: 0.78, blue: 0.20)))

        case .working:
            // Tiny floating code spark
            let phase = (t * 1.4).truncatingRemainder(dividingBy: 1.0)
            let sx = cx + s * 0.36
            let sy = cy - s * (0.18 + CGFloat(phase) * 0.18)
            let alpha = sin(phase * .pi)
            let dot = s * 0.075
            ctx.fill(Path(ellipseIn: CGRect(x: sx - dot * 0.5, y: sy - dot * 0.5, width: dot, height: dot)), with: .color(theme.eyeGlow.opacity(alpha)))

        case .error:
            // Rising twin stylized cartoon frustration steam wisps + alert badge
            for i in 0..<2 {
                let phase = (t * 1.4 + Double(i) * 0.48).truncatingRemainder(dividingBy: 1.0)
                let side: CGFloat = (i == 0) ? -0.14 : 0.15
                let sx = cx + s * side + CGFloat(sin(phase * .pi * 2)) * s * 0.03
                let sy = cy - s * (0.37 + CGFloat(phase) * 0.15)
                let alpha = sin(phase * .pi) * 0.85
                let w = s * (0.09 + CGFloat(phase) * 0.05)
                let h = s * (0.065 + CGFloat(phase) * 0.035)
                ctx.fill(
                    Path(ellipseIn: CGRect(x: sx - w * 0.5, y: sy - h * 0.5, width: w, height: h)),
                    with: .color(Color(red: 1.0, green: 0.78, blue: 0.76).opacity(alpha))
                )
            }
            let badge = Text("!")
                .font(.system(size: s * 0.22, weight: .black, design: .rounded))
                .foregroundColor(Color(red: 1.0, green: 0.36, blue: 0.34))
            ctx.draw(badge, at: CGPoint(x: cx + s * 0.34, y: cy - s * 0.31))

        case .poked, .dizzy:
            break
        }
    }

    private func makeStarPath(center: CGPoint, radius: CGFloat) -> Path {
        var p = Path()
        let inner = radius * 0.38
        for i in 0..<8 {
            let angle = Double(i) * (.pi / 4.0) - .pi / 2.0
            let r = (i % 2 == 0) ? radius : inner
            let pt = CGPoint(x: center.x + cos(angle) * r, y: center.y + sin(angle) * r)
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        p.closeSubpath()
        return p
    }
}
