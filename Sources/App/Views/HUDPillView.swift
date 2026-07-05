import SwiftUI

/// The Ambient HUD (HUD-01, HUD-02) as a detached Liquid Glass pill floating
/// just BELOW the notch — a self-contained rounded capsule, independent of the
/// notch/wing shapes so it never has to match their width. Shows a glyph + a
/// neutral level bar; the fill is ALWAYS neutral (`Tokens.Color.text`), never
/// the amber attention token (D-06). Appears while `isShowingHUD` and fades out
/// after the arbiter's timeout.
@MainActor
struct HUDPillView: View {
    let hud: HUDViewModel

    private let barWidth: CGFloat = 88

    var body: some View {
        ZStack {
            if hud.isShowingHUD {
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
                .glassEffect(.regular, in: .capsule)
                .transition(.opacity.combined(with: .offset(y: -6)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeOut(duration: 0.22), value: hud.isShowingHUD)
    }
}
