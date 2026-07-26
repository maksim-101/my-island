import SwiftUI

/// The Ambient HUD (HUD-01, HUD-02) as a detached Liquid Glass pill floating
/// just BELOW the notch — a self-contained rounded capsule, independent of the
/// notch/wing shapes so it never has to match their width. Shows a glyph + a
/// neutral level bar; the fill is ALWAYS neutral (`Tokens.Color.text`), never
/// the amber attention token (D-06). Appears while `isShowingHUD` and fades out
/// after the arbiter's timeout.
///
/// Pinned to the top of its (oversized) window so it hangs just under the notch;
/// the extra window height below leaves room for the glow/shadow.
@MainActor
struct HUDPillView: View {
    let hud: HUDViewModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let barWidth: CGFloat = 88

    /// A meeting bump is INTERRUPTIVE — it has to win attention you haven't
    /// given it — whereas a brightness/volume HUD is confirmatory: you just
    /// pressed the key and you're already looking. Same mechanics, opposite
    /// jobs, so the meeting variant slides in, sits larger and carries an
    /// accent rim (BL-05 / bump variant B3). Amber stays reserved for
    /// "needs you" per DESIGN.md, so the indigo accent does the work.
    private var isMeeting: Bool { hud.text != nil }

    var body: some View {
        ZStack {
            if hud.isShowingHUD {
                pill
                    .transition(transition)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 2)
        .animation(.easeOut(duration: isMeeting && !reduceMotion ? 0.34 : 0.22), value: hud.isShowingHUD)
    }

    /// Peripheral vision detects motion far better than opacity change, which
    /// is why the meeting bump slides out from behind the notch instead of
    /// fading in place. Reduce Motion falls back to the plain fade.
    private var transition: AnyTransition {
        if isMeeting && !reduceMotion {
            return .move(edge: .top).combined(with: .opacity)
        }
        return .opacity.combined(with: .scale(scale: 0.92))
    }

    private var pill: some View {
        HStack(spacing: Tokens.Spacing.sm) {
            Image(systemName: hud.glyph.systemName)
                .font(Tokens.Font.data)
                .foregroundStyle(Tokens.Color.text)

            if let text = hud.text {
                // Meeting bump (CAL-01/D-02): neutral truncating text row in
                // place of the level bar — never accent/amber (T-04-07), and
                // non-interactive (no tap target) per the plan's prohibitions.
                Text(text)
                    .font(Tokens.Font.data)
                    .foregroundStyle(Tokens.Color.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else {
                Capsule()
                    .fill(Tokens.Color.hairline)
                    .frame(width: barWidth, height: 4)
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(Tokens.Color.text)
                            .frame(width: barWidth * max(0, min(1, hud.level)))
                            .animation(.easeOut(duration: 0.18), value: hud.level)
                    }
            }
        }
        .padding(.horizontal, isMeeting ? Tokens.Spacing.xl : Tokens.Spacing.lg)
        .padding(.vertical, isMeeting ? Tokens.Spacing.md : Tokens.Spacing.sm)
        // A touch of tint gives the glass more presence on bright wallpapers.
        .glassEffect(.regular.tint(Color.black.opacity(0.12)), in: .capsule)
        // Bright rim + soft outer glow make it read clearly against any
        // background; the dark shadow separates it from the wallpaper.
        .overlay {
            Capsule().strokeBorder(
                isMeeting ? Tokens.Color.accent.opacity(0.85) : .white.opacity(0.4),
                lineWidth: isMeeting ? 1 : 0.75
            )
        }
        .shadow(color: .black.opacity(isMeeting ? 0.4 : 0.35), radius: 6, y: 2)
        .shadow(color: isMeeting ? Tokens.Color.accent.opacity(0.5) : .white.opacity(0.22), radius: isMeeting ? 16 : 9)
    }
}
