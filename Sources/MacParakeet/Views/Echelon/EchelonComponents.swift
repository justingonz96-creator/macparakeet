import AVFoundation
import AppKit
import MacParakeetCore
import SwiftUI

// MARK: - Status pill

struct EchelonPill: View {
    enum Tone { case green, amber, red, blue, quiet }

    let text: String
    let tone: Tone

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .lineLimit(1)
            .padding(.horizontal, 9)
            .frame(height: 22)
            .foregroundStyle(foreground)
            .background(Capsule().fill(foreground.opacity(tone == .quiet ? 0 : 0.14)))
            .background(Capsule().fill(tone == .quiet ? DesignSystem.Colors.surfaceElevated : .clear))
    }

    private var foreground: Color {
        switch tone {
        case .green: DesignSystem.Colors.successGreen
        case .amber: DesignSystem.Colors.warningAmber
        case .red: DesignSystem.Colors.errorRed
        case .blue: DesignSystem.Colors.accent
        case .quiet: DesignSystem.Colors.textSecondary
        }
    }
}

/// Pill for a caption check result.
struct CaptionCheckPill: View {
    let errors: Int
    let toCheck: Int

    var body: some View {
        if errors > 0 {
            EchelonPill(text: toCheck > 0 ? "\(errors) \(errors == 1 ? "error" : "errors") · \(toCheck) to check" : "\(errors) \(errors == 1 ? "error" : "errors")", tone: .red)
        } else if toCheck > 0 {
            EchelonPill(text: "\(toCheck) to check", tone: .amber)
        } else {
            EchelonPill(text: "Passed · ready", tone: .green)
        }
    }
}

struct LanguageChip: View {
    enum State { case done, draft, none }
    let language: CaptionLanguage
    let state: State

    var body: some View {
        Text(language.rawValue.uppercased())
            .font(.system(size: 11, weight: .bold))
            .tracking(0.3)
            .frame(minWidth: 28, minHeight: 20)
            .padding(.horizontal, 4)
            .foregroundStyle(foreground)
            .background(RoundedRectangle(cornerRadius: 4).fill(state == .done ? DesignSystem.Colors.surfaceElevated : .clear))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(border, style: StrokeStyle(lineWidth: 1, dash: state == .none ? [3, 2] : []))
            )
            .help(help)
    }

    private var foreground: Color {
        switch state {
        case .done: DesignSystem.Colors.textPrimary
        case .draft: DesignSystem.Colors.warningAmber
        case .none: DesignSystem.Colors.textTertiary
        }
    }

    private var border: Color {
        switch state {
        case .done: .clear
        case .draft: DesignSystem.Colors.warningAmber
        case .none: DesignSystem.Colors.border
        }
    }

    private var help: String {
        switch state {
        case .done: "\(language.displayName) captions ready"
        case .draft: "\(language.displayName): AI draft waiting for a native speaker's review"
        case .none: "No \(language.displayName) captions yet"
        }
    }
}

// MARK: - Video

/// The player's picture without controls, so Echo can draw captions over it.
struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer?

    func makeNSView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.playerLayer.player = player
        return view
    }

    func updateNSView(_ view: PlayerLayerView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
    }

    final class PlayerLayerView: NSView {
        let playerLayer = AVPlayerLayer()

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer = CALayer()
            layer?.backgroundColor = NSColor.black.cgColor
            playerLayer.videoGravity = .resizeAspect
            layer?.addSublayer(playerLayer)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func layout() {
            super.layout()
            playerLayer.frame = bounds
        }
    }
}

/// A caption drawn the way Premiere places Echelon captions: lower-centre over
/// the rider, white text on a dark translucent box, sized to the picture.
struct EchelonCaptionOverlay: View {
    let text: String?
    let videoHeight: CGFloat

    var body: some View {
        if let text, !text.isEmpty {
            Text(text)
                .font(.custom("Helvetica Neue", size: max(10, videoHeight * 0.045)).weight(.medium))
                .multilineTextAlignment(.center)
                .lineSpacing(videoHeight * 0.006)
                .foregroundStyle(.white)
                .padding(.horizontal, videoHeight * 0.022)
                .padding(.vertical, videoHeight * 0.008)
                .background(RoundedRectangle(cornerRadius: videoHeight * 0.012).fill(Color(white: 0.07).opacity(0.72)))
                .fixedSize()
        }
    }
}

// MARK: - Whole-class caption strip

/// Every caption in the class as a tick; amber where something is worth a
/// look, red where a caption rule is broken. Click to jump there.
struct CaptionStrip: View {
    let cues: [CaptionDocumentCue]
    let flags: [Int: CaptionQualityIssue.Severity]
    let durationMs: Int
    let playheadMs: Int
    let onSeek: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geometry in
                let width = geometry.size.width
                Canvas { context, size in
                    guard durationMs > 0 else { return }
                    for (index, cue) in cues.enumerated() {
                        let x = CGFloat(cue.startMs) / CGFloat(durationMs) * size.width
                        switch flags[index] {
                        case .error?:
                            context.fill(Path(CGRect(x: x - 1, y: 1, width: 3, height: size.height - 2)), with: .color(DesignSystem.Colors.errorRed))
                        case .review?:
                            context.fill(Path(CGRect(x: x - 1, y: 1, width: 3, height: size.height - 2)), with: .color(DesignSystem.Colors.warningAmber))
                        case nil:
                            context.fill(Path(CGRect(x: x, y: 6, width: 1, height: size.height - 12)), with: .color(Color(red: 0.27, green: 0.34, blue: 0.42)))
                        }
                    }
                    let px = CGFloat(playheadMs) / CGFloat(durationMs) * size.width
                    context.fill(Path(CGRect(x: px - 1, y: 0, width: 2, height: size.height)), with: .color(DesignSystem.Colors.accent))
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onEnded { value in
                    guard width > 0, durationMs > 0 else { return }
                    onSeek(Int(max(0, min(1, value.location.x / width)) * CGFloat(durationMs)))
                })
            }
            .frame(height: 26)
            HStack {
                ForEach(Array(scaleMarks.enumerated()), id: \.offset) { offset, mark in
                    if offset > 0 { Spacer() }
                    Text(mark)
                }
            }
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(DesignSystem.Colors.textTertiary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 6).fill(DesignSystem.Colors.surface))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(DesignSystem.Colors.divider))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("All captions in the class, \(flags.count) flagged")
    }

    private var scaleMarks: [String] {
        guard durationMs > 0 else { return [] }
        return (0...6).map { step in Self.clock(durationMs * step / 6) }
    }

    static func clock(_ ms: Int) -> String {
        let seconds = ms / 1000
        return seconds >= 3600
            ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// `00:10:32;09`-style timecode at the preset's frame rate.
enum Timecode {
    static func string(_ ms: Int, frameRate: Double = 29.97) -> String {
        let seconds = ms / 1000
        let frames = Int(Double(ms % 1000) / 1000 * frameRate.rounded())
        return String(format: "%02d:%02d:%02d;%02d", seconds / 3600, seconds / 60 % 60, seconds % 60, frames)
    }
}
