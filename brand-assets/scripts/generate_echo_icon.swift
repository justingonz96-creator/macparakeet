import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Echo app icon generator.
//
// Renders a 1024×1024 PNG of the Echo app icon (navy gradient circle,
// custom-drawn geometric cyan "e") and writes it to the path you pass.
// Run via the wrapper script `generate_echo_icon.sh` (same dir) which
// also produces the full .iconset and packs it into Assets/AppIcon.icns.
//
// Compile + run standalone:
//   swiftc generate_echo_icon.swift -o /tmp/gen -framework AppKit
//   /tmp/gen /tmp/echo-1024.png
//
// Design notes:
//   - Background: navy circle with subtle vertical gradient (lighter
//     navy at top → deeper navy at bottom) plus a faint glassy
//     highlight crescent at the top.
//   - Mark: lowercase "e" stroked rather than typed — geometry is
//     tuned (bar slightly above optical center, opening on the lower
//     right, bar fuses into the ring on both sides). Heavy stroke so
//     it stays legible at 16 px.
//   - Padding: ~8% inset so macOS's automatic squircle mask doesn't
//     bite into the circle.

guard CommandLine.arguments.count >= 2 else {
    print("usage: generate_echo_icon <output.png>")
    exit(1)
}
let outputPath = CommandLine.arguments[1]

let size: CGFloat = 1024
let center = CGPoint(x: size / 2, y: size / 2)

// MARK: - Brand colors (calibrated from Echelon's mark)

let navyTop    = NSColor(srgbRed:   0/255.0, green: 64/255.0, blue:  94/255.0, alpha: 1.0)
let navyBottom = NSColor(srgbRed:   0/255.0, green: 26/255.0, blue:  44/255.0, alpha: 1.0)
let cyan       = NSColor(srgbRed:   0/255.0, green: 181/255.0, blue: 216/255.0, alpha: 1.0)
let highlight  = NSColor(white: 1.0, alpha: 0.10)

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

ctx.clear(CGRect(x: 0, y: 0, width: size, height: size))

// MARK: - Background circle with vertical gradient

let circleInset: CGFloat = 80
let circleRect = CGRect(
    x: circleInset, y: circleInset,
    width: size - 2 * circleInset, height: size - 2 * circleInset
)
ctx.saveGState()
let circlePath = CGPath(ellipseIn: circleRect, transform: nil)
ctx.addPath(circlePath)
ctx.clip()
guard let gradient = CGGradient(
    colorsSpace: colorSpace,
    colors: [navyTop.cgColor, navyBottom.cgColor] as CFArray,
    locations: [0.0, 1.0]
) else { print("Gradient failed"); exit(1) }
ctx.drawLinearGradient(
    gradient,
    start: CGPoint(x: 0, y: circleRect.maxY),
    end:   CGPoint(x: 0, y: circleRect.minY),
    options: []
)
ctx.restoreGState()

// MARK: - Top inner highlight

ctx.saveGState()
ctx.addPath(circlePath); ctx.clip()
let highlightRect = CGRect(
    x: circleInset - 60,
    y: circleRect.maxY - circleRect.height * 0.55,
    width: circleRect.width + 120,
    height: circleRect.height * 0.62
)
ctx.setFillColor(highlight.cgColor)
ctx.fillEllipse(in: highlightRect)
ctx.restoreGState()

// MARK: - Custom geometric "e"
//
// Design rules that make it actually read as a letter:
//   * Bar sits slightly above the geometric center (typographic
//     "optical centering" — geometric center looks too low).
//   * Bar's left and right ends BOTH overlap the ring stroke, so the
//     rounded line caps are hidden inside the arc and the bar fuses
//     into the ring instead of floating with visible tips.
//   * Opening lives BELOW the bar on the right (~28°). Symmetric or
//     side-only openings read as "c", not "e".
//   * Heavy stroke (108 px on 1024) keeps legibility at 16 px.

let eRadius: CGFloat = (size / 2) - 240
let eStrokeWidth: CGFloat = 108
let barYOffset: CGFloat = eRadius * 0.10
let barY: CGFloat = center.y + barYOffset

let barAngle = asin(barYOffset / eRadius) * 180 / .pi
let openingBelowBar: CGFloat = 28
let arcStartAngle = barAngle
let arcEndAngle = 360 - openingBelowBar

let arcPath = NSBezierPath()
arcPath.appendArc(
    withCenter: center,
    radius: eRadius,
    startAngle: arcStartAngle,
    endAngle: arcEndAngle,
    clockwise: false
)

let barLeftX  = center.x - eRadius * cos(barAngle * .pi / 180)
let barRightX = center.x + eRadius * cos(barAngle * .pi / 180)
let bar = NSBezierPath()
bar.move(to: CGPoint(x: barLeftX,  y: barY))
bar.line(to: CGPoint(x: barRightX, y: barY))

cyan.setStroke()
arcPath.lineWidth = eStrokeWidth
arcPath.lineCapStyle = .round
arcPath.lineJoinStyle = .round
arcPath.stroke()

bar.lineWidth = eStrokeWidth
bar.lineCapStyle = .round
bar.stroke()

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
