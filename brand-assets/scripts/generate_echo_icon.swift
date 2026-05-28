import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Echo app icon — v3.
//
// Modern macOS icon principles applied:
//   1. FILL THE CANVAS. macOS auto-masks the 1024×1024 master to a
//      squircle. Designing a smaller circle inside a square (v1/v2)
//      under-uses the visual area. Apple's own icons (Music, Calendar,
//      App Store) all fill the full square; macOS does the rounding.
//   2. GRADIENT BACKGROUND. ~40% of top-chart app icons in 2026 use
//      multi-tone gradients. Diagonal navy → cyan (analogous, on-brand)
//      reads as depth + dynamism, not flat-2014.
//   3. SINGLE WHITE SYMBOL. The canonical modern macOS composition
//      (Music's note, App Store's A, Calendar's date) is one clean
//      white glyph on a gradient. Maximum contrast, instant recognition
//      at any size.
//   4. SUBTLE DEPTH. A soft top-left highlight (light source) + faint
//      bottom-right vignette imply dimensionality without heaviness.
//      No skeuomorphic gloss.
//   5. GEOMETRIC LETTERFORM. The "e" stays — Echelon brand + the
//      "Echo" name make it the right mark. Stroked construction,
//      bar slightly above optical center, opening on the lower-right.
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
let center = CGPoint(x: size / 2, y: size / 2)

// MARK: - Brand colors

// Cyan and navy are calibrated from the Echelon mark. White is full
// opacity for the foreground glyph — maximum contrast on the gradient.
let cyanBright = NSColor(srgbRed:   0/255.0, green: 181/255.0, blue: 216/255.0, alpha: 1.0)
let navyDeep   = NSColor(srgbRed:   0/255.0, green:  26/255.0, blue:  44/255.0, alpha: 1.0)
let white      = NSColor.white
let topLight   = NSColor(white: 1.0, alpha: 0.12)  // top-left light source
let cornerShadow = NSColor(srgbRed: 0/255.0, green: 10/255.0, blue: 20/255.0, alpha: 0.25)

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

// MARK: - Background: full-canvas diagonal gradient

// Diagonal from top-left (bright cyan, the "light source") to bottom-
// right (deep navy, the "shadow"). Analogous color pair = smooth, on-
// brand depth. This fills the entire 1024×1024 canvas — macOS applies
// its squircle mask on top automatically.
guard let backgroundGradient = CGGradient(
    colorsSpace: colorSpace,
    colors: [cyanBright.cgColor, navyDeep.cgColor] as CFArray,
    locations: [0.0, 1.0]
) else { print("background gradient failed"); exit(1) }

ctx.drawLinearGradient(
    backgroundGradient,
    start: CGPoint(x: 0, y: size),          // top-left
    end:   CGPoint(x: size, y: 0),          // bottom-right
    options: []
)

// MARK: - Top-left highlight (light source)

// A soft radial pool of light in the top-left to reinforce the gradient's
// implied light direction. Sits at low opacity so it reads as "lit
// surface" rather than "white blob."
guard let highlightGradient = CGGradient(
    colorsSpace: colorSpace,
    colors: [topLight.cgColor, NSColor(white: 1.0, alpha: 0).cgColor] as CFArray,
    locations: [0.0, 1.0]
) else { print("highlight gradient failed"); exit(1) }

ctx.drawRadialGradient(
    highlightGradient,
    startCenter: CGPoint(x: size * 0.25, y: size * 0.78),
    startRadius: 0,
    endCenter:   CGPoint(x: size * 0.25, y: size * 0.78),
    endRadius:   size * 0.7,
    options: []
)

// MARK: - Bottom-right corner shadow (depth)

// Mirror of the highlight — soft pool of darker color in the opposite
// corner. Subtle, mostly subliminal, but the eye reads it as
// "something dimensional" rather than "flat sticker."
guard let shadowGradient = CGGradient(
    colorsSpace: colorSpace,
    colors: [cornerShadow.cgColor, NSColor(white: 0, alpha: 0).cgColor] as CFArray,
    locations: [0.0, 1.0]
) else { print("shadow gradient failed"); exit(1) }

ctx.drawRadialGradient(
    shadowGradient,
    startCenter: CGPoint(x: size * 0.85, y: size * 0.15),
    startRadius: 0,
    endCenter:   CGPoint(x: size * 0.85, y: size * 0.15),
    endRadius:   size * 0.55,
    options: []
)

// MARK: - Geometric "e" glyph (white, centered)

// Same construction as v2 (the geometry was already correct — bar
// optically lifted, opening on lower-right, line caps hidden inside
// the ring). Now in WHITE for max contrast on the gradient.

// Slightly larger now that the icon isn't constrained by an inset
// circle — the e can claim more visual real estate.
let eRadius: CGFloat = (size / 2) - 220
let eStrokeWidth: CGFloat = 116
let barYOffset: CGFloat = eRadius * 0.10
let barY: CGFloat = center.y + barYOffset

let barAngle = asin(barYOffset / eRadius) * 180 / .pi
let openingBelowBar: CGFloat = 28
let arcStartAngle = barAngle
let arcEndAngle = 360 - openingBelowBar

// Soft drop shadow under the glyph — gives the e weight on the
// gradient, the way Apple's white symbols sit on their gradients.
ctx.setShadow(
    offset: CGSize(width: 0, height: -8),
    blur: 24,
    color: NSColor(white: 0, alpha: 0.18).cgColor
)

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

white.setStroke()
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
