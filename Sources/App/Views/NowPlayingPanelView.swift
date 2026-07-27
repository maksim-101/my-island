import SwiftUI
import AppKit
import MyIslandCore

/// Expanded-panel Now Playing group (D-08, D-12): a 44pt artwork tile, the "{Title} — {Artist}"
/// line, the source app's caption, and — only when a usable duration exists — a thin
/// elapsed/duration progress bar. Structured like `CalendarPanelView`'s group shape (label +
/// content), but with NO internal empty branch: per D-12 the entire group, including its label, is
/// omitted from `ExpandedPanelView` via `if nowPlaying.displayPanel` — this view never expresses
/// that empty state itself.
@MainActor
struct NowPlayingPanelView: View {
    let nowPlaying: NowPlayingProvider

    private static let artworkSize: CGFloat = 44

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.sm) {
            // UI-SPEC specifies uppercase "NOW PLAYING," matching the "CALENDAR"/"CLIPBOARD"
            // convention it describes — but Tokens.Font.label applies no uppercasing/tracking, so
            // the shipped sibling groups (CalendarPanelView, ClipboardPanelView) actually render
            // Title Case in practice. Rendering "Now Playing" here matches what the siblings
            // really look like, which is the point of the convention clause. Flagged in the
            // SUMMARY for a quick user confirmation.
            Text("Now Playing")
                .font(Tokens.Font.label)
                .foregroundStyle(Tokens.Color.textMuted)

            HStack(spacing: Tokens.Spacing.md) {
                artworkTile

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
        }
        // UI-SPEC "Paused-in-grace": the whole panel group — including the progress bar frozen at
        // its last known position — dims to 55% opacity during the 30s grace window, matching the
        // ear's identical treatment.
        .opacity(nowPlaying.isPausedInGrace ? 0.55 : 1)
    }

    @ViewBuilder
    private var artworkTile: some View {
        if let artwork = nowPlaying.artwork {
            Image(nsImage: artwork)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: Self.artworkSize, height: Self.artworkSize)
                .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.sm))
        } else {
            // No-artwork fallback (spike 002: a real playing session — e.g. the Apple TV app — can
            // have artworkData == nil): the identical 44x44 footprint, never a collapsed layout.
            RoundedRectangle(cornerRadius: Tokens.Radius.sm)
                .fill(Tokens.Color.surfaceRaised)
                .frame(width: Self.artworkSize, height: Self.artworkSize)
                .overlay {
                    Image(systemName: "music.note")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Tokens.Color.textFaint)
                }
        }
    }
}

/// The panel group's progress bar (D-08): a 2pt-tall hairline `Capsule` track with an `accent`
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
