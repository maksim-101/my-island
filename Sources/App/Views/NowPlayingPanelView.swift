import SwiftUI
import AppKit
import MyIslandCore

/// The Now Playing stage body (popup-cockpit3-FINAL.html "Now Playing
/// selected"): current track only — the 44pt glowing `ArtworkTile`, the "{Title}
/// — {Artist}" line, the source app's caption, and — only when a usable duration
/// exists — the thin elapsed/duration scrubber. No source list/picker. Has NO
/// internal empty branch: per D-12 the whole stage is simply not selected when
/// there is no session, and the tile strip's value falls back to "—".
///
/// **Superseded 05-06 (G-05-5):** the title/artist line below no longer truncates
/// with a tail ellipsis — see `ScrollingTrackText`.
@MainActor
struct NowPlayingPanelView: View {
    let nowPlaying: NowPlayingProvider

    private static let artworkSize: CGFloat = 44

    var body: some View {
        HStack(spacing: Tokens.Spacing.md) {
            ArtworkTile(artwork: nowPlaying.artwork, size: Self.artworkSize)

            VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                ScrollingTrackText(
                    text: NowPlayingFormatting.earText(title: nowPlaying.currentModel?.title, artist: nowPlaying.currentModel?.artist),
                    isFrozen: nowPlaying.isPausedInGrace
                )

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

/// The panel's "{Title} — {Artist}" line (G-05-5, 05-06): static when it fits, otherwise a single
/// repeating horizontal pass — hold, walk left to reveal the end, hold, return — timed by the pure
/// `MarqueePass` schedule. This view drives no timing or geometry rule of its own; it only measures
/// and ticks.
///
/// Prior art: the removed `ScrollingEarText` (see `git show d08cffe -- Sources/App/Views/NotchBarView.swift`)
/// established the manual per-tick offset loop — chosen over a single animated block so a freeze
/// flag can be sampled every tick, not only at coarse `await` points (WR-02, commit 94c920b) — and
/// the live `@State` mirror of the freeze flag read from inside the loop. This view keeps both, but
/// replaces the fixed 40pt viewport and fixed-duration timing with a measured viewport and
/// `MarqueePass`'s rate-based schedule, and repeats indefinitely instead of parking after one pass.
private struct ScrollingTrackText: View {
    let text: String
    /// True during the paused-in-grace window: halts the scroll immediately at whatever offset it
    /// currently holds and suppresses further motion while set, matching the group's 55% dim.
    let isFrozen: Bool

    @State private var viewportWidth: CGFloat = 0
    @State private var offset: CGFloat = 0
    /// Live mirror of `isFrozen`, read from inside `runScrollPass()` instead of `isFrozen` directly.
    /// The pass's `.task(id:)` is keyed on the bounded text and viewport width, and does NOT
    /// restart when `isFrozen` changes, so a plain captured `let` would go stale the moment the
    /// grace window opens or closes mid-pass — the exact bug WR-02 fixed in the removed ear version.
    @State private var frozenNow = false

    /// Matches `Tokens.Font.bodyMD` (`SwiftUI.Font.system(size: 12.5, weight: .regular)`) — measured
    /// directly via `NSFont`/`NSString` sizing rather than a `GeometryReader` round-trip, so the
    /// scroll/no-scroll decision is made synchronously with no first-layout race.
    private static let measuringFont = NSFont.systemFont(ofSize: 12.5, weight: .regular)
    private static let tickInterval: Double = 1.0 / 30.0

    private var boundedText: String {
        MarqueePass.bounded(text)
    }

    private var measuredWidth: CGFloat {
        (boundedText as NSString).size(withAttributes: [.font: Self.measuringFont]).width
    }

    var body: some View {
        Text(boundedText)
            .font(Tokens.Font.bodyMD)
            .foregroundStyle(Tokens.Color.text)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .offset(x: offset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipped()
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { viewportWidth = proxy.size.width }
                        .onChange(of: proxy.size.width) { _, newValue in
                            viewportWidth = newValue
                        }
                }
            )
            .onChange(of: isFrozen, initial: true) { _, newValue in
                frozenNow = newValue
            }
            .task(id: "\(boundedText)#\(viewportWidth)") {
                await runScrollPass()
            }
    }

    private func runScrollPass() async {
        offset = 0
        let overflow = MarqueePass.overflow(textWidth: measuredWidth, viewportWidth: viewportWidth)
        guard overflow > 0 else { return }

        var elapsed: Double = 0
        var lastTick = Date()
        while !Task.isCancelled {
            let now = Date()
            if !frozenNow {
                elapsed += now.timeIntervalSince(lastTick)
                offset = MarqueePass.offset(overflow: overflow, elapsed: elapsed)
            }
            lastTick = now
            try? await Task.sleep(for: .seconds(Self.tickInterval))
        }
    }
}
