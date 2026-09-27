import SwiftUI
import MyIslandCore

/// D-06 Wave 2 (PANEL-04): the band's one detail droplet — ported per D-02 from
/// `.planning/sketches/006-design-round/index.html`'s `renderDrop` (line 691-696). Fixed 180pt
/// tall content box (188 minus the 8pt the sketch keeps for the rim), width `2m`, positioned at
/// the droplet's own TARGET placement (`frame`, set once per `NotchPanelController.showDroplet`
/// call — never re-derived from the live, still-animating outline springs; only the OUTLINE
/// itself, drawn separately via `FluidOutlineShape(params: motion.params)`, animates toward this
/// target). Hosts today's existing detail views unchanged — `TimerPanelView`, `NowPlayingPanelView`,
/// `CalendarPanelView`, `ClipboardPanelView` — refitted to the droplet's own narrower width in
/// plans 09/10. Nothing here wires a tap/click handler back to the band's own open/close or pin
/// paths (F1) — every control inside is one of the hosted detail views' own buttons.
@MainActor
struct DropletView: View {
    let module: BandModule
    /// The droplet's own TARGET `(mx, m)` — see `DropletFrame`'s own doc comment.
    let frame: DropletFrame
    /// The band's own rest depth (`BandLayout.frame.d`) — the droplet's own top sits at `d + 4`.
    let d: CGFloat
    /// The SwiftUI-local `cx` the SAME `BandLayout` NotchContentView already positions the band
    /// row with — `frame.mx` is relative to this, matching `renderDrop`'s own `dropBox.x = cx + mx - m`.
    let cx: CGFloat
    let timer: TimerViewModel
    let nowPlaying: NowPlayingProvider
    let calendar: CalendarProvider
    let clipboard: ClipboardViewModel
    /// 07-14 (CLAUDE-01/02/03): the read-only, already-sorted session list — `ClaudePanelView`'s
    /// own data source, replacing plan 08's `EmptyView()` placeholder.
    let claudeSessions: [ClaudeSession]

    private static let contentHeight: CGFloat = 180

    var body: some View {
        let width = frame.m * 2
        content
            .padding(Tokens.Spacing.md)
            .frame(width: width, height: Self.contentHeight, alignment: .top)
            // `dropBox.x + width/2 == (cx + mx - m) + m == cx + mx` — the sketch's own left-edge
            // arithmetic collapses to a straight `cx + mx` center once expressed as SwiftUI's
            // center-anchored `.position(_:_:)`.
            .position(x: cx + frame.mx, y: d + 4 + Self.contentHeight / 2)
    }

    @ViewBuilder
    private var content: some View {
        switch module {
        case .timer: TimerPanelView(timer: timer)
        case .nowPlaying: NowPlayingPanelView(nowPlaying: nowPlaying)
        case .nextMeeting: CalendarPanelView(calendar: calendar)
        case .clipboard: ClipboardPanelView(clipboard: clipboard)
        case .claude: ClaudePanelView(sessions: claudeSessions)
        }
    }
}
