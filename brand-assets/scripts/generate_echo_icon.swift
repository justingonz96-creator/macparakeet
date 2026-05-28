import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Echo app icon — v4 "Echo Ripples"
//
// Design brief: "sound waves + the simplicity of MacParakeet's original
// flat coral bird on cream." Single subject, two colors, no gradient,
// no skeuomorphic shading. The icon IS the metaphor:
//
//   - A small filled dot at left-of-center = sound source.
//   - Three concentric arcs of increasing radius opening to the right
//     = sound waves rippling outward.
//
// Reads as "echo" instantly — no letterform, no clever layering, just
// the literal visual of sound emanating from a point. The Echelon
// navy + cyan does the brand work without needing typography.
//
// Compile + run standalone:
//   swiftc generate_echo_icon.swift -o /tmp/gen -framework AppKit
//   /tmp/gen /tmp/echo-1024.png

guard CommandLine.arguments.count >= 2 else {
    print("usage: generate_echo_icon <output.png>")
    exit(1)
}
let outputPath = CommandLine.arguments[1]

let size: CGFloat = 1024

// MARK: - Brand colors

let navy = NSColor(srgbRed:   0/255.0, green:  26/255.0, blue:  44/255.0, alpha: 1.0)
let cyan = NSColor(srgbRed:   0/255.0, green: 181/255.0, blue: 216/255.0, alpha: 1.0)

// MARK: - Context

let colorSpace = CGColorSpaceCreateDeviceRGB()
let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue
    | CGImageAlphaInfo.premultipliedLast.rawValue
guard let ctx = CGContext(
    data: nil, width: Int(size), height: Int(size),
    bitsPerComponent: 8, bytesPerRow: 0,
    space: colorSpace, bitmapInfo: bitmapInfo
) else { print("CGContext failed"); exit(1) }
let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = nsCtx

// MARK: - Background: solid navy (fills full canvas; macOS squircle-masks)

ctx.setFillColor(navy.cgColor)
ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))

// MARK: - Echo ripples
//
// Composition follows the canonical "sound emanating from a source"
// icon pattern (Apple's volume icon, AirPlay): source dot on the LEFT
// third, ripple arcs fanning out RIGHTWARD across the rest of the
// canvas. Each ripple is a partial arc (~140°) on the right side of
// its circle — never wraps to the back where it would crowd the dot
// and unbalance the composition.

let sourcePoint = CGPoint(x: size * 0.30, y: size / 2)
let dotRadius: CGFloat = 56
let strokeWidth: CGFloat = 84

// Three arc radii — arithmetic spacing of ~135 px between rings gives
// a clear rhythm of propagation. Outermost radius chosen so the arc's
// rightmost point (sourceX + radius) lands ~80 px short of the canvas
// edge, leaving visual breathing room.
let ripple1Radius: CGFloat = 195
let ripple2Radius: CGFloat = 330
let ripple3Radius: CGFloat = 465

// Each arc covers 140° centered on 3 o'clock — wide enough to read as
// a full ripple, narrow enough to stay on the right side of the source
// and avoid the unbalanced "wrap around the back" look. The opening
// (left-facing) is implicit — that's where the source dot sits.
let arcSweepDegrees: CGFloat = 140
let halfSweep = arcSweepDegrees / 2
let arcStart: CGFloat = 360 - halfSweep            // 290° (lower-right)
let arcEnd: CGFloat   = halfSweep                  //  70° (upper-right)

cyan.setStroke()
cyan.setFill()

for radius in [ripple3Radius, ripple2Radius, ripple1Radius] {
    let arc = NSBezierPath()
    arc.appendArc(
        withCenter: sourcePoint,
        radius: radius,
        startAngle: arcStart,
        endAngle: arcEnd,
        clockwise: false   // CCW from 290° through 0° to 70° — right side only
    )
    arc.lineWidth = strokeWidth
    arc.lineCapStyle = .round
    arc.stroke()
}

// Source dot — small filled circle at the focal point. Anchors the
// composition and explicitly identifies where the sound is coming from.
let dotRect = CGRect(
    x: sourcePoint.x - dotRadius,
    y: sourcePoint.y - dotRadius,
    width: dotRadius * 2,
    height: dotRadius * 2
)
ctx.fillEllipse(in: dotRect)

NSGraphicsContext.restoreGraphicsState()

// MARK: - Encode PNG

guard let cgImage = ctx.makeImage() else { print("makeImage failed"); exit(1) }
let outputURL = URL(fileURLWithPath: outputPath)
guard let destination = CGImageDestinationCreateWithURL(
    outputURL as CFURL, UTType.png.identifier as CFString, 1, nil
) else { print("PNG destination failed"); exit(1) }
CGImageDestinationAddImage(destination, cgImage, nil)
guard CGImageDestinationFinalize(destination) else { print("finalize failed"); exit(1) }
print("Wrote \(Int(size))×\(Int(size)) icon to \(outputPath)")
