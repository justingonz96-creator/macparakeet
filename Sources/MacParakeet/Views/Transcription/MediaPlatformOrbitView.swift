import SwiftUI
import MacParakeetCore

/// The hero for the Transcribe-URL surfaces: a constellation of real platform marks
/// arranged around a core. When a recognized URL is pasted, the constellation recedes
/// and the matched platform blooms to focus in the center.
///
/// **Motion on intent, calm at rest.** The constellation is perfectly *static* while
/// idle, so the Transcribe tab costs no CPU and cannot jitter. (A continuous
/// `repeatForever` `.rotationEffect` was tried and measured: SwiftUI drives a
/// per-frame main-thread display-list regeneration for it — ~17% CPU — rather than a
/// free render-server transform, so it was dropped.) Motion happens only on intent:
/// the constellation makes one smooth full revolution on hover (a single eased
/// animation that settles back to zero work), and the center blooms on a match. All
/// motion is gated by Reduce Motion.
struct MediaPlatformOrbitView: View {
    /// The platform recognized from the current URL draft (nil while idle/typing).
    var matched: MediaPlatform?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spin: Double = 0
    @State private var hovering = false
    /// Guards against a hover re-entry restarting the revolution mid-flight (which
    /// would stack `+360`s and visibly speed up). One revolution at a time.
    @State private var revolving = false

    /// The seven marks shown on the ring. SoundCloud and Twitch are recognized and
    /// have bundled marks, but are intentionally left off the ring (seven spaces the
    /// circle cleanly); when matched they bloom in the center via the neutral-hero path.
    private let orbitPlatforms: [MediaPlatform] = [
        .youtube, .x, .vimeo, .facebook, .tiktok, .instagram, .applePodcasts,
    ]

    /// The matched platform, but only when it is one we orbit (so an obscure
    /// recognized site falls back to the generic hero rather than a missing chip).
    private var focus: MediaPlatform? {
        guard let matched, orbitPlatforms.contains(matched) else { return nil }
        return matched
    }

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let radius = side * 0.40
            let node = side * 0.215

            ZStack {
                guideRing(radius: radius)
                    .opacity(matched == nil ? (hovering ? 0.34 : 0.20) : 0.06)
                    .animation(fade, value: matched == nil)
                    .animation(fade, value: hovering)

                ring(radius: radius, node: node)
                    .opacity(matched == nil ? 1 : 0.14)
                    .blur(radius: matched == nil ? 0 : 1.5)
                    .animation(fade, value: matched == nil)

                center(side: side)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .contentShape(Rectangle())
        .onHover { isHovering in
            hovering = isHovering
            if isHovering { revolve() }
        }
        .onChange(of: matched) { _, newValue in
            // A match should leave the ring calm: end an in-flight hover revolve so it
            // doesn't keep turning (faded) behind the blooming center. Resetting `spin`
            // directly ends the animation; the ring's own fade-out covers the snap.
            if newValue != nil, revolving {
                spin = 0
                revolving = false
            }
        }
    }

    // MARK: - Pieces

    private func guideRing(radius: CGFloat) -> some View {
        Circle()
            .strokeBorder(DesignSystem.Colors.border, lineWidth: 1)
            .frame(width: radius * 2, height: radius * 2)
    }

    /// The orbiting chips. Each chip is placed at a **static** resting position and
    /// counter-rotates by `-spin`; the whole ring then rotates by `+spin`. Reading
    /// `spin` only as a direct `.rotationEffect` value — never to compute per-chip
    /// geometry in the body — keeps the chips out of per-frame body re-evaluation and
    /// is strictly cheaper than the earlier `base + spin` angle that recomputed
    /// in-body every frame. It is **not** free, though: while the one-shot hover
    /// revolve runs, SwiftUI still re-commits the rotation each frame on the main
    /// thread — which is exactly why a `repeatForever` spin measured ~17% idle CPU and
    /// was dropped (see the type doc). That per-frame cost is acceptable here only
    /// because the motion is transient and on-intent; do **not** make `spin` loop.
    private func ring(radius: CGFloat, node: CGFloat) -> some View {
        ZStack {
            ForEach(Array(orbitPlatforms.enumerated()), id: \.element) { index, platform in
                chip(platform, size: node)
                    .rotationEffect(.degrees(-spin))               // keep upright
                    .offset(restingOffset(index, radius: radius))  // static placement
            }
        }
        .rotationEffect(.degrees(spin))                            // orbit the whole ring
    }

    /// Resting position (no spin) for chip `index` on the ring; first chip at top.
    private func restingOffset(_ index: Int, radius: CGFloat) -> CGSize {
        let theta = baseDegrees(index) * .pi / 180
        return CGSize(width: radius * CGFloat(cos(theta)), height: radius * CGFloat(sin(theta)))
    }

    private func chip(_ platform: MediaPlatform, size: CGFloat) -> some View {
        PlatformGlyph(platform: platform, color: platform.brandTint)
            .frame(width: size * 0.62, height: size * 0.62)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: size * 0.30, style: .continuous)
                    .fill(platform.brandTint.opacity(0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.30, style: .continuous)
                    .strokeBorder(platform.brandTint.opacity(0.16), lineWidth: 0.5)
            )
    }

    @ViewBuilder
    private func center(side: CGFloat) -> some View {
        ZStack {
            if let focus {
                heroBadge(platform: focus, tint: focus.brandTint, side: side)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            } else if matched != nil {
                // Recognized but not one of the orbit chips (e.g. SoundCloud) —
                // show a neutral hero so the field still feels "understood".
                heroBadge(platform: matched, tint: DesignSystem.Colors.accent, side: side)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            } else {
                idleCore(side: side)
                    .transition(.opacity)
            }
        }
        .animation(bloom, value: matched)
    }

    /// Reduce Motion gates *all* motion, not just the spin: the ring fade and the
    /// center bloom resolve instantly when the user has asked for less motion.
    private var fade: Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.35)
    }
    private var bloom: Animation? {
        reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.8)
    }

    private func heroBadge(platform: MediaPlatform?, tint: Color, side: CGFloat) -> some View {
        ZStack {
            Circle()
                .fill(tint.opacity(0.14))
                .frame(width: side * 0.46, height: side * 0.46)
            Circle()
                .strokeBorder(tint.opacity(0.28), lineWidth: 1)
                .frame(width: side * 0.46, height: side * 0.46)
            PlatformGlyph(platform: platform, color: tint)
                .frame(width: side * 0.26, height: side * 0.26)
        }
    }

    private func idleCore(side: CGFloat) -> some View {
        ZStack {
            Circle()
                .fill(DesignSystem.Colors.accent.opacity(0.06))
                .frame(width: side * 0.40, height: side * 0.40)
            PlatformGlyph(platform: nil, color: DesignSystem.Colors.textSecondary)
                .frame(width: side * 0.20, height: side * 0.20)
                .opacity(0.55)
        }
    }

    // MARK: - Motion

    /// One smooth full revolution, triggered on hover. A single eased animation (not a
    /// `repeatForever` linear loop) has no seam to stutter and — crucially — leaves the
    /// constellation static at rest, so the idle tab does zero per-frame work. No-op
    /// under Reduce Motion, while a match is bloomed, or while already revolving. On
    /// completion `spin` resets to 0 (visually identical to 360·n for `rotationEffect`),
    /// keeping it bounded across many hovers.
    private func revolve() {
        guard !reduceMotion, matched == nil, !revolving else { return }
        revolving = true
        withAnimation(.easeInOut(duration: 1.4)) {
            spin += 360
        } completion: {
            spin = 0
            revolving = false
        }
    }

    /// Resting angle (degrees) for chip `index`, evenly spaced, first chip at top.
    private func baseDegrees(_ index: Int) -> Double {
        Double(index) / Double(orbitPlatforms.count) * 360 - 90
    }
}

#if DEBUG
#Preview("Orbit — idle") {
    MediaPlatformOrbitView(matched: nil)
        .frame(width: 130, height: 130)
        .padding(40)
}

#Preview("Orbit — matched YouTube") {
    MediaPlatformOrbitView(matched: .youtube)
        .frame(width: 130, height: 130)
        .padding(40)
}
#endif
