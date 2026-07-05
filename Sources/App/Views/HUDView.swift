import SwiftUI

/// The Ambient HUD bump content (HUD-01, HUD-02): a glyph + a rounded level
/// bar, rendered in the downward bump strip below the camera housing. The
/// fill is ALWAYS neutral (`Tokens.Color.text`) — never the amber attention
/// token (D-06), and is visually compact/distinct from the full hover-expand
/// panel.
@MainActor
struct HUDView: View {
    let hud: HUDViewModel

    var body: some View {
        HStack(spacing: Tokens.Spacing.sm) {
            Image(systemName: hud.glyph.systemName)
                .font(Tokens.Font.data)
                .foregroundStyle(Tokens.Color.text)

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: Tokens.Radius.sm)
                        .fill(Tokens.Color.hairline)
                    RoundedRectangle(cornerRadius: Tokens.Radius.sm)
                        .fill(Tokens.Color.text)
                        .frame(width: proxy.size.width * max(0, min(1, hud.level)))
                        // Interpolate each level change so poll-driven brightness
                        // updates ramp smoothly instead of jumping in visible
                        // steps (fixes the stutter on rapid brightness keys).
                        .animation(.easeOut(duration: 0.18), value: hud.level)
                }
            }
            .frame(height: 4)
        }
        .padding(.horizontal, Tokens.Spacing.lg)
        .padding(.bottom, Tokens.Spacing.md)
        .padding(.top, Tokens.Spacing.xs)
    }
}
