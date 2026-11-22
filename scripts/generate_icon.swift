#!/usr/bin/env swift
import Cocoa

// Generates a crisp 1024x1024 macOS squircle icon with Lumi mascot
let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon_1024.png"
let size: CGFloat = 1024
let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(size),
    pixelsHigh: Int(size),
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
)!

NSGraphicsContext.saveGraphicsState()
let ctx = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.current = ctx
let cg = ctx.cgContext

// 1. Rounded macOS App Icon squircle background
let inset: CGFloat = 92
let iconRect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let bgPath = CGPath(roundedRect: iconRect, cornerWidth: 192, cornerHeight: 192, transform: nil)

cg.saveGState()
cg.addPath(bgPath)
cg.clip()

let cs = CGColorSpaceCreateDeviceRGB()
let bgGrad = CGGradient(
    colorsSpace: cs,
    colors: [
        CGColor(red: 0.08, green: 0.09, blue: 0.16, alpha: 1.0),
        CGColor(red: 0.03, green: 0.04, blue: 0.08, alpha: 1.0)
    ] as CFArray,
    locations: [0.0, 1.0]
)!
cg.drawLinearGradient(bgGrad, start: CGPoint(x: size * 0.5, y: size - inset), end: CGPoint(x: size * 0.5, y: inset), options: [])

// Nebula radial ambient glow
let glowGrad = CGGradient(
    colorsSpace: cs,
    colors: [
        CGColor(red: 0.66, green: 0.44, blue: 1.0, alpha: 0.52),
        CGColor(red: 0.18, green: 0.80, blue: 0.78, alpha: 0.16),
        CGColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 0.0)
    ] as CFArray,
    locations: [0.0, 0.52, 1.0]
)!
cg.drawRadialGradient(
    glowGrad,
    startCenter: CGPoint(x: size * 0.5, y: size * 0.54),
    startRadius: 30,
    endCenter: CGPoint(x: size * 0.5, y: size * 0.52),
    endRadius: 420,
    options: []
)

// Subtle top glass rim
cg.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.18))
cg.setLineWidth(6)
cg.addPath(bgPath)
cg.strokePath()

// 2. Draw Lumi space-ghost / capsule body
let cx = size * 0.5
let cy = size * 0.50
let bw: CGFloat = 460
let bh: CGFloat = 490
let halfW = bw * 0.5
let topY = cy + bh * 0.5
let botY = cy - bh * 0.44
let domeR = halfW

let body = CGMutablePath()
body.move(to: CGPoint(x: cx - halfW, y: topY - domeR))
body.addArc(center: CGPoint(x: cx, y: topY - domeR), radius: domeR, startAngle: .pi, endAngle: 0, clockwise: true)
body.addLine(to: CGPoint(x: cx + halfW, y: botY + 38))
body.addQuadCurve(to: CGPoint(x: cx + halfW * 0.33, y: botY), control: CGPoint(x: cx + halfW * 0.72, y: botY - 34))
body.addQuadCurve(to: CGPoint(x: cx - halfW * 0.33, y: botY), control: CGPoint(x: cx, y: botY + 30))
body.addQuadCurve(to: CGPoint(x: cx - halfW, y: botY + 38), control: CGPoint(x: cx - halfW * 0.72, y: botY - 34))
body.closeSubpath()

cg.saveGState()
cg.addPath(body)
cg.clip()
let bodyGrad = CGGradient(
    colorsSpace: cs,
    colors: [
        CGColor(red: 0.80, green: 0.64, blue: 1.0, alpha: 1.0),
        CGColor(red: 0.48, green: 0.34, blue: 0.94, alpha: 1.0)
    ] as CFArray,
    locations: [0.0, 1.0]
)!
cg.drawLinearGradient(bodyGrad, start: CGPoint(x: cx, y: topY), end: CGPoint(x: cx, y: botY - 20), options: [])

// Top glossy highlight
let gloss = CGRect(x: cx - 125, y: topY - 115, width: 250, height: 78)
cg.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.34))
cg.fillEllipse(in: gloss)
cg.restoreGState()

cg.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.42))
cg.setLineWidth(6)
cg.addPath(body)
cg.strokePath()

// 3. Dark curved space visor
let vw: CGFloat = 354
let vh: CGFloat = 198
let visorRect = CGRect(x: cx - vw * 0.5, y: cy - 10, width: vw, height: vh)
let visorPath = CGPath(roundedRect: visorRect, cornerWidth: vh * 0.46, cornerHeight: vh * 0.46, transform: nil)
cg.saveGState()
cg.addPath(visorPath)
cg.clip()
let visorGrad = CGGradient(
    colorsSpace: cs,
    colors: [
        CGColor(red: 0.06, green: 0.07, blue: 0.13, alpha: 1.0),
        CGColor(red: 0.12, green: 0.14, blue: 0.23, alpha: 1.0)
    ] as CFArray,
    locations: [0.0, 1.0]
)!
cg.drawLinearGradient(visorGrad, start: CGPoint(x: cx, y: visorRect.maxY), end: CGPoint(x: cx, y: visorRect.minY), options: [])
cg.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.16))
cg.addPath(CGPath(roundedRect: CGRect(x: visorRect.minX + 36, y: visorRect.maxY - 52, width: 118, height: 28), cornerWidth: 14, cornerHeight: 14, transform: nil))
cg.fillPath()
cg.restoreGState()

cg.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.25))
cg.setLineWidth(5)
cg.addPath(visorPath)
cg.strokePath()

// 4. Glowing cyan capsule eyes
let eyeW: CGFloat = 52
let eyeH: CGFloat = 78
let eyeY = visorRect.midY - eyeH * 0.5 - 4
for dx: CGFloat in [-74, 74] {
    let er = CGRect(x: cx + dx - eyeW * 0.5, y: eyeY, width: eyeW, height: eyeH)
    let ep = CGPath(roundedRect: er, cornerWidth: eyeW * 0.5, cornerHeight: eyeW * 0.5, transform: nil)
    cg.setShadow(offset: .zero, blur: 18, color: CGColor(red: 0.52, green: 0.94, blue: 1.0, alpha: 0.85))
    cg.setFillColor(CGColor(red: 0.62, green: 0.95, blue: 1.0, alpha: 1.0))
    cg.addPath(ep)
    cg.fillPath()
    cg.setShadow(offset: .zero, blur: 0, color: nil)
    cg.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.9))
    cg.fillEllipse(in: CGRect(x: er.minX + 10, y: er.maxY - 26, width: 17, height: 17))
}

// 5. Little golden notification sparkle top-right
let starX = cx + 225
let starY = cy + 205
let star = CGMutablePath()
for i in 0..<8 {
    let angle = Double(i) * (.pi / 4.0) - .pi / 2.0
    let r: CGFloat = (i % 2 == 0) ? 54 : 20
    let pt = CGPoint(x: starX + cos(angle) * r, y: starY + sin(angle) * r)
    if i == 0 { star.move(to: pt) } else { star.addLine(to: pt) }
}
star.closeSubpath()
cg.setShadow(offset: .zero, blur: 20, color: CGColor(red: 1.0, green: 0.80, blue: 0.24, alpha: 0.9))
cg.setFillColor(CGColor(red: 1.0, green: 0.84, blue: 0.30, alpha: 1.0))
cg.addPath(star)
cg.fillPath()

cg.restoreGState()
NSGraphicsContext.restoreGraphicsState()

let pngData = rep.representation(using: .png, properties: [:])!
try pngData.write(to: URL(fileURLWithPath: outPath))
print("Generated icon:", outPath)
