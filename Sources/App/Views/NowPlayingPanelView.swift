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
///
/// **G-05-5c fix:** the original 05-06 shape let the scrolling `Text` itself decide this view's
/// frame — `fixedSize(horizontal: true)` forced it to always report its full intrinsic width no
/// matter what was proposed, the flexible frame wrapped around it could only grow to fit that
/// refusal, and the geometry reader measuring the viewport was chained downstream of that same
/// ballooned frame — so it measured the text's own width back at itself. `MarqueePass.overflow`
/// therefore always saw `textWidth ≈ viewportWidth` and returned 0: the marquee never took its
/// first tick, and the mid-word cut the user actually saw was `NotchPanelController`'s window-edge
/// layer mask catching the overflow this view never clipped. The fix below breaks that circularity
/// by never letting the scrolling copy influence the frame it scrolls inside of: a hidden, ordinary,
/// flexible single-line text — the **layout twin** — is this view's real content and accepts the
/// proposed width like any normal text; the scrolling copy lives entirely inside an `.overlay`,
/// which by construction can never feed its size back into the view it decorates, so nothing the
/// scrolling copy does can re-inflate the frame. The overlay's `GeometryReader` reads the twin's
/// real resolved width and hands it to `runScrollPass(viewportWidth:)` as a call argument in the
/// same layout pass that produced it — never through a state write a task has to catch up to. Do
/// not "simplify" this back into a single `Text` that decides its own frame; that shape is exactly
/// what shipped broken.
struct ScrollingTrackText: View {
    let text: String
    /// True during the paused-in-grace window: halts the scroll immediately at whatever offset it
    /// currently holds and suppresses further motion while set, matching the group's 55% dim.
    let isFrozen: Bool
    /// Point size for both the visible/twin text and the measuring font — defaults to the panel's
    /// `Tokens.Font.bodyMDSize` (the existing call site keeps this default, rendering identically);
    /// the synthetic pill's center slot passes a scaled size instead (D-04).
    var pointSize: CGFloat = Tokens.Font.bodyMDSize

    @State private var offset: CGFloat = 0
    /// Live mirror of `isFrozen`, read from inside `runScrollPass()` instead of `isFrozen` directly.
    /// The pass's `.task(id:)` is keyed on the bounded text and viewport width, and does NOT
    /// restart when `isFrozen` changes, so a plain captured `let` would go stale the moment the
    /// grace window opens or closes mid-pass — the exact bug WR-02 fixed in the removed ear version.
    @State private var frozenNow = false

    /// Measured directly via `NSFont`/`NSString` sizing rather than a `GeometryReader` round-trip,
    /// so the scroll/no-scroll decision is made synchronously with no first-layout race. An instance
    /// property (not the former `static let`) so it tracks `pointSize` per call site.
    private var measuringFont: NSFont {
        NSFont.systemFont(ofSize: pointSize, weight: .regular)
    }
    private static let tickInterval: Double = 1.0 / 30.0

    private var boundedText: String {
        MarqueePass.bounded(text)
    }

    private var measuredWidth: CGFloat {
        (boundedText as NSString).size(withAttributes: [.font: measuringFont]).width
    }

    var body: some View {
        // Layout twin: an ordinary flexible single-line text that accepts the proposed width and
        // is never drawn. Its resolved frame — not the scrolling text's intrinsic width — is what
        // pins this view's size, which is the entire fix for G-05-5c.
        Text(boundedText)
            .font(.system(size: pointSize, weight: .regular))
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .hidden()
            .overlay {
                // Scrolling copy: overlay content never feeds its size back into the twin it
                // decorates, so proxy.size here is genuinely the twin's real, unballooned width.
                GeometryReader { proxy in
                    Text(boundedText)
                        .font(.system(size: pointSize, weight: .regular))
                        .foregroundStyle(Tokens.Color.text)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .offset(x: offset)
                        .task(id: "\(boundedText)#\(proxy.size.width)") {
                            await runScrollPass(viewportWidth: proxy.size.width)
                        }
                }
            }
            .clipped()
            .onChange(of: isFrozen, initial: true) { _, newValue in
                frozenNow = newValue
            }
    }

    private func runScrollPass(viewportWidth: CGFloat) async {
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
