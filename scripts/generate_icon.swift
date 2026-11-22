#!/usr/bin/env swift
import Cocoa

// Generates a crisp 1024x1024 macOS squircle App Icon featuring "Lumi Ember"
// (Headspace-inspired warm tangerine asymmetric-eye luminous bean on dark slate squircle)
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

// Flip Y to match top-down SwiftUI coordinates for identical vector math!
cg.translateBy(x: 0, y: size)
cg.scaleBy(x: 1, y: -1)

let cs = CGColorSpaceCreateDeviceRGB()

// 1. Rounded macOS App Icon squircle background (#18202B -> #141922)
let inset: CGFloat = 88
let iconRect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let bgPath = CGPath(roundedRect: iconRect, cornerWidth: 196, cornerHeight: 196, transform: nil)

cg.saveGState()
cg.addPath(bgPath)
cg.clip()

let bgGrad = CGGradient(
    colorsSpace: cs,
    colors: [
        CGColor(red: 0.094, green: 0.125, blue: 0.169, alpha: 1.0), // #18202B
        CGColor(red: 0.075, green: 0.094, blue: 0.130, alpha: 1.0)  // #131821
    ] as CFArray,
    locations: [0.0, 1.0]
)!
cg.drawLinearGradient(bgGrad, start: CGPoint(x: size * 0.5, y: inset), end: CGPoint(x: size * 0.5, y: size - inset), options: [])

// Warm ambient tangerine halo glow behind Lumi Ember
let glowGrad = CGGradient(
    colorsSpace: cs,
    colors: [
        CGColor(red: 0.961, green: 0.502, blue: 0.220, alpha: 0.44), // #F58038
        CGColor(red: 0.957, green: 0.408, blue: 0.286, alpha: 0.14),
        CGColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 0.0)
    ] as CFArray,
    locations: [0.0, 0.52, 1.0]
)!
cg.drawRadialGradient(
    glowGrad,
    startCenter: CGPoint(x: size * 0.50, y: size * 0.52),
    startRadius: 40,
    endCenter: CGPoint(x: size * 0.50, y: size * 0.52),
    endRadius: 420,
    options: []
)

// Subtle warm glass rim along squircle border
cg.setStrokeColor(CGColor(red: 1.0, green: 0.68, blue: 0.42, alpha: 0.22))
cg.setLineWidth(6)
cg.addPath(bgPath)
cg.strokePath()

// 2. Lineless organic asymmetric pear-bean body ("Lumi Ember")
let bw: CGFloat = 530
let bh: CGFloat = bw / 0.955
let rect = CGRect(x: (size - bw) * 0.5, y: (size - bh) * 0.5 + 8, width: bw, height: bh)
func pt(_ nx: CGFloat, _ ny: CGFloat) -> CGPoint {
    CGPoint(x: rect.minX + nx * rect.width, y: rect.minY + ny * rect.height)
}

let body = CGMutablePath()
body.move(to: pt(0.51, 0.00))
body.addCurve(to: pt(0.91, 0.22), control1: pt(0.71, 0.00), control2: pt(0.84, 0.09))
body.addCurve(to: pt(1.00, 0.54), control1: pt(0.98, 0.33), control2: pt(1.01, 0.44))
body.addCurve(to: pt(0.84, 0.85), control1: pt(0.99, 0.67), control2: pt(0.93, 0.77))
body.addCurve(to: pt(0.40, 1.00), control1: pt(0.73, 0.95), control2: pt(0.56, 1.01))
body.addCurve(to: pt(0.00, 0.74), control1: pt(0.18, 0.99), control2: pt(0.01, 0.90))
body.addCurve(to: pt(0.10, 0.40), control1: pt(-0.01, 0.60), control2: pt(0.07, 0.50))
body.addCurve(to: pt(0.20, 0.14), control1: pt(0.12, 0.28), control2: pt(0.14, 0.20))
body.addCurve(to: pt(0.51, 0.00), control1: pt(0.28, 0.04), control2: pt(0.39, 0.00))
body.closeSubpath()

cg.saveGState()
cg.setShadow(offset: CGSize(width: 0, height: -18), blur: 52, color: CGColor(red: 0.96, green: 0.45, blue: 0.18, alpha: 0.40))
cg.addPath(body)
cg.setFillColor(CGColor(red: 0.96, green: 0.52, blue: 0.24, alpha: 1.0))
cg.fillPath()
cg.restoreGState()

cg.saveGState()
cg.addPath(body)
cg.clip()
let bodyGrad = CGGradient(
    colorsSpace: cs,
    colors: [
        CGColor(red: 0.965, green: 0.576, blue: 0.224, alpha: 1.0), // #F69339
        CGColor(red: 0.953, green: 0.482, blue: 0.259, alpha: 1.0), // #F37B42
        CGColor(red: 0.957, green: 0.408, blue: 0.286, alpha: 1.0)  // #F46849
    ] as CFArray,
    locations: [0.0, 0.58, 1.0]
)!
cg.drawLinearGradient(
    bodyGrad,
    start: CGPoint(x: rect.maxX * 0.85 + rect.minX * 0.15, y: rect.minY),
    end: CGPoint(x: rect.minX * 0.85 + rect.maxX * 0.15, y: rect.maxY),
    options: []
)
cg.restoreGState()

// 3. Signature Asymmetric White Eyes (#FEFEFE) & Charcoal Pupils (#252E3B)
let lCenter = pt(0.346, 0.444)
let rCenter = pt(0.674, 0.383)
let lDia = bw * 0.232
let rDia = bw * 0.278

cg.setFillColor(CGColor(red: 0.996, green: 0.996, blue: 0.996, alpha: 1.0))
cg.fillEllipse(in: CGRect(x: lCenter.x - lDia * 0.5, y: lCenter.y - lDia * 0.5, width: lDia, height: lDia))
cg.fillEllipse(in: CGRect(x: rCenter.x - rDia * 0.5, y: rCenter.y - rDia * 0.5, width: rDia, height: rDia))

let ink = CGColor(red: 0.145, green: 0.180, blue: 0.231, alpha: 1.0)
let lpCenter = pt(0.378, 0.441)
let rpCenter = pt(0.639, 0.399)
let lpDia = bw * 0.102
let rpDia = bw * 0.120
cg.setFillColor(ink)
cg.fillEllipse(in: CGRect(x: lpCenter.x - lpDia * 0.5, y: lpCenter.y - lpDia * 0.5, width: lpDia, height: lpDia))
cg.fillEllipse(in: CGRect(x: rpCenter.x - rpDia * 0.5, y: rpCenter.y - rpDia * 0.5, width: rpDia, height: rpDia))

// 4. Expressive Charcoal Eyebrows & Small Tilted U-Smile
cg.setStrokeColor(ink)
cg.setLineCap(.round)
cg.setLineWidth(bw * 0.036)

let lb = CGMutablePath()
lb.move(to: pt(0.21, 0.320))
lb.addQuadCurve(to: pt(0.39, 0.256), control: pt(0.29, 0.252))
cg.addPath(lb)
cg.strokePath()

let rb = CGMutablePath()
rb.move(to: pt(0.58, 0.205))
rb.addQuadCurve(to: pt(0.76, 0.225), control: pt(0.67, 0.178))
cg.addPath(rb)
cg.strokePath()

cg.setLineWidth(bw * 0.038)
let mouth = CGMutablePath()
mouth.move(to: pt(0.445, 0.598))
mouth.addQuadCurve(to: pt(0.625, 0.558), control: pt(0.545, 0.656))
cg.addPath(mouth)
cg.strokePath()

cg.restoreGState()
NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else {
    fputs("Failed to encode PNG\n", stderr)
    exit(1)
}
try png.write(to: URL(fileURLWithPath: outPath))
print("Generated Lumi Ember icon: \(outPath)")
