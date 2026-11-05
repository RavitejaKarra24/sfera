import AppKit
import CoreGraphics
import Foundation

// Generates the Sfera app icon: a dark instrument panel with concentric
// spatial rings. Original artwork, no third-party assets.

let size = 1024
let space = CGColorSpaceCreateDeviceRGB()
guard let context = CGContext(
    data: nil,
    width: size,
    height: size,
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: space,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    fatalError("could not create context")
}

let rect = CGRect(x: 0, y: 0, width: size, height: size)
let corner = CGFloat(size) * 0.225

// Rounded body with a soft vertical gradient.
let body = CGPath(roundedRect: rect.insetBy(dx: 40, dy: 40), cornerWidth: corner, cornerHeight: corner, transform: nil)
context.saveGState()
context.addPath(body)
context.clip()
let gradient = CGGradient(
    colorsSpace: space,
    colors: [
        CGColor(red: 0.10, green: 0.11, blue: 0.14, alpha: 1),
        CGColor(red: 0.035, green: 0.04, blue: 0.055, alpha: 1),
    ] as CFArray,
    locations: [0, 1]
)!
context.drawLinearGradient(
    gradient,
    start: CGPoint(x: 0, y: CGFloat(size)),
    end: CGPoint(x: 0, y: 0),
    options: []
)

// Subtle inner glow.
let glow = CGGradient(
    colorsSpace: space,
    colors: [
        CGColor(red: 0.31, green: 0.83, blue: 0.76, alpha: 0.22),
        CGColor(red: 0.31, green: 0.83, blue: 0.76, alpha: 0.0),
    ] as CFArray,
    locations: [0, 1]
)!
context.drawRadialGradient(
    glow,
    startCenter: CGPoint(x: CGFloat(size) / 2, y: CGFloat(size) / 2),
    startRadius: 0,
    endCenter: CGPoint(x: CGFloat(size) / 2, y: CGFloat(size) / 2),
    endRadius: CGFloat(size) * 0.46,
    options: []
)
context.restoreGState()

let teal = CGColor(red: 0.31, green: 0.84, blue: 0.76, alpha: 1)
let center = CGPoint(x: CGFloat(size) / 2, y: CGFloat(size) / 2)

func ring(radius: CGFloat, width: CGFloat, alpha: CGFloat, start: CGFloat, end: CGFloat) {
    context.setStrokeColor(CGColor(red: 0.31, green: 0.84, blue: 0.76, alpha: alpha))
    context.setLineWidth(width)
    context.setLineCap(.round)
    context.addArc(center: center, radius: radius, startAngle: start, endAngle: end, clockwise: false)
    context.strokePath()
}

// Three spatial arcs, rotated like the in-app mark.
for index in 0..<3 {
    let base = CGFloat(index) * (2 * .pi / 3)
    ring(radius: 268, width: 20, alpha: 0.85 - CGFloat(index) * 0.16, start: base + 0.20, end: base + 1.85)
    ring(radius: 196, width: 10, alpha: 0.30, start: base + 0.55, end: base + 2.3)
}

// Crosshair axes.
context.setStrokeColor(CGColor(red: 0.92, green: 0.91, blue: 0.88, alpha: 0.10))
context.setLineWidth(6)
context.move(to: CGPoint(x: center.x - 330, y: center.y))
context.addLine(to: CGPoint(x: center.x + 330, y: center.y))
context.move(to: CGPoint(x: center.x, y: center.y - 330))
context.addLine(to: CGPoint(x: center.x, y: center.y + 330))
context.strokePath()

// Core.
context.setFillColor(teal)
context.fillEllipse(in: CGRect(x: center.x - 46, y: center.y - 46, width: 92, height: 92))
context.setFillColor(CGColor(red: 0.06, green: 0.07, blue: 0.09, alpha: 1))
context.fillEllipse(in: CGRect(x: center.x - 18, y: center.y - 18, width: 36, height: 36))

// Object markers.
let markers: [(Double, Double)] = [(-0.55, 0.42), (0.62, 0.20), (0.18, -0.62), (-0.24, -0.36)]
for (mx, my) in markers {
    let point = CGPoint(x: center.x + CGFloat(mx) * 330, y: center.y + CGFloat(my) * 330)
    context.setFillColor(CGColor(red: 0.56, green: 0.48, blue: 1.0, alpha: 0.95))
    context.fillEllipse(in: CGRect(x: point.x - 15, y: point.y - 15, width: 30, height: 30))
    context.setStrokeColor(CGColor(red: 0.56, green: 0.48, blue: 1.0, alpha: 0.28))
    context.setLineWidth(4)
    context.strokeEllipse(in: CGRect(x: point.x - 30, y: point.y - 30, width: 60, height: 60))
}

guard let image = context.makeImage() else { fatalError("could not render icon") }
let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Icon.png"
let url = URL(fileURLWithPath: output)
let rep = NSBitmapImageRep(cgImage: image)
guard let data = rep.representation(using: .png, properties: [:]) else { fatalError("encode failed") }
try data.write(to: url)
print("icon: wrote \(output)")
