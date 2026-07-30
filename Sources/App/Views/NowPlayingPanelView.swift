import SwiftUI
import AppKit
import MyIslandCore

/// The Now Playing stage body (popup-cockpit3-FINAL.html "Now Playing
/// selected"): current track only — the 44pt glowing `ArtworkTile`, the "{Title}
/// — {Artist}" line, the source app's caption, and — only when a usable duration
/// exists — the thin elapsed/duration scrubber. No source list/picker. Has NO
/// internal empty branch: per D-12 the whole stage is simply not selected when
/// there is no session, and the tile strip's value falls back to "—".
@MainActor
struct NowPlayingPanelView: View {
    let nowPlaying: NowPlayingProvider

    private static let artworkSize: CGFloat = 44

    var body: some View {
        HStack(spacing: Tokens.Spacing.md) {
            ArtworkTile(artwork: nowPlaying.artwork, size: Self.artworkSize)

            VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                Text(NowPlayingFormatting.earText(title: nowPlaying.currentModel?.title, artist: nowPlaying.currentModel?.artist))
                    .font(Tokens.Font.bodyMD)
                    .foregroundStyle(Tokens.Color.text)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Text(nowPlaying.currentModel?.applicationName ?? "")
                    .font(Tokens.Font.label)
                    .foregroundStyle(Tokens.Color.textMuted)
                    .lineLimit(1)
                    .truncationMode(.tail)

                // Omitted entirely (no indeterminate/looping animation) when the payload
                // carries no usable duration — a live stream with no fixed length — per
                // UI-SPEC's "omit rather than fake" convention.
                if let fraction = nowPlaying.elapsedFraction {
                    NowPlayingProgressBar(fraction: fraction)
                        .padding(.top, Tokens.Spacing.xs)
                }
            }
        }
        // UI-SPEC "Paused-in-grace": the whole stage — including the progress bar frozen at
        // its last known position — dims to 55% opacity during the 30s grace window, matching the
        // ear's identical treatment.
        .opacity(nowPlaying.isPausedInGrace ? 0.55 : 1)
    }
}

/// The stage's progress bar (D-08): a 2pt-tall hairline `Capsule` track with an `accent`
/// fill sized to `fraction` of the available width, measured via `GeometryReader` so it spans the
/// text column exactly — the ONLY accent usage in this phase; no buttons, no selection state, no
/// action surface at all (playback control is deferred out of this phase).
private struct NowPlayingProgressBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Tokens.Color.hairline)
                Capsule()
                    .fill(Tokens.Color.accent)
                    .frame(width: proxy.size.width * fraction)
            }
        }
        .frame(height: 2)
    }
}
