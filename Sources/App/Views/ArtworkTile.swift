import SwiftUI
import AppKit

/// Shared artwork tile used by both the expanded Now Playing panel (44pt) and
/// the collapsed left ear (20pt). Draws the cover art with an always-on 1px
/// inner hairline ring at `white 0.14` PLUS an artwork-derived bloom — a
/// scaled-up, blurred, higher-saturation copy of the same image behind the
/// tile — so the cover separates from the near-black ground without any color
/// extraction. Never indigo, never amber (the bloom is derived from the artwork
/// itself). The no-artwork fallback keeps the identical footprint.
@MainActor
struct ArtworkTile: View {
    let artwork: NSImage?
    let size: CGFloat
    var cornerRadius: CGFloat = Tokens.Radius.sm
    /// Blur radius of the derived bloom — softer (small) on the collapsed ear,
    /// wider on the panel tile.
    var bloomRadius: CGFloat = 10
    var bloomOpacity: Double = 0.4

    var body: some View {
        ZStack {
            if let artwork {
                // Artwork-derived bloom: a scaled-up, blurred, more-saturated
                // copy behind the tile. No dominant-hue extraction needed — the
                // blurred image IS the glow color.
                Image(nsImage: artwork)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .saturation(1.5)
                    .scaleEffect(1.2)
                    .blur(radius: bloomRadius)
                    .opacity(bloomOpacity)
                    .allowsHitTesting(false)

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
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius)
                .stroke(SwiftUI.Color.white.opacity(0.14), lineWidth: 1)
        }
    }
}
