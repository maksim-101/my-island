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

    private let barWidth: CGFloat = 88

    var body: some View {
        ZStack {
            if hud.isShowingHUD {
                pill
                    .transition(.opacity.combined(with: .scale(scale: 0.92)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 2)
        .animation(.easeOut(duration: 0.22), value: hud.isShowingHUD)
    }

    private var pill: some View {
        HStack(spacing: Tokens.Spacing.sm) {
            Image(systemName: hud.glyph.systemName)
                .font(Tokens.Font.data)
                .foregroundStyle(Tokens.Color.text)

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
        .padding(.horizontal, Tokens.Spacing.lg)
        .padding(.vertical, Tokens.Spacing.sm)
        // A touch of tint gives the glass more presence on bright wallpapers.
        .glassEffect(.regular.tint(Color.black.opacity(0.12)), in: .capsule)
        // Bright rim + soft outer glow make it read clearly against any
        // background; the dark shadow separates it from the wallpaper.
        .overlay { Capsule().strokeBorder(.white.opacity(0.4), lineWidth: 0.75) }
        .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
        .shadow(color: .white.opacity(0.22), radius: 9)
    }
}
