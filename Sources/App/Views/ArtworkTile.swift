import SwiftUI
import AppKit

/// Shared artwork tile used by both the expanded Now Playing panel (44pt) and
/// the collapsed left ear (20pt). Draws the cover art with a crisp "neon" edge:
/// a bright 1px border plus a faint same-color outer glow, so the cover
/// separates cleanly from the near-black ground WITHOUT the large blurred bloom
/// (the user found the bloom distracting — a defined border reads calmer). No
/// color extraction, never indigo, never amber. The no-artwork fallback keeps
/// the identical footprint.
@MainActor
struct ArtworkTile: View {
    let artwork: NSImage?
    let size: CGFloat
    var cornerRadius: CGFloat = Tokens.Radius.sm

    var body: some View {
        Group {
            if let artwork {
                Image(nsImage: artwork)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            } else {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(Tokens.Color.surfaceRaised)
                    .frame(width: size, height: size)
                    .overlay {
                        Image(systemName: "music.note")
                            .font(.system(size: size * 0.4, weight: .medium))
                            .foregroundStyle(Tokens.Color.textFaint)
                    }
            }
        }
        .frame(width: size, height: size)
        // Neon edge: a bright hairline + a small same-color halo. Restrained —
        // a defined luminous border, not a light-show.
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(SwiftUI.Color.white.opacity(0.55), lineWidth: 1)
        }
        .shadow(color: SwiftUI.Color.white.opacity(0.22), radius: 2.5)
    }
}
