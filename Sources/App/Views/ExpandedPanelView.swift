import SwiftUI
import AppKit

/// The expanded notch panel, Cockpit-3 layout (popup-cockpit3-FINAL.html): a 3-tile strip that
/// selects the active stage, a content-sized STAGE showing exactly one module
/// (Timer/Calendar/Now Playing), and a Clipboard that grows to fill the remaining vertical space.
/// The header row (title, gear, power) is gone — Settings and Quit now live in the menu-bar
/// status item (`StatusItemController`, PANEL-03). Styled entirely from `Tokens` — never a
/// hardcoded color/spacing/type value.
@MainActor
struct ExpandedPanelView: View {
    let timer: TimerViewModel
    let calendar: CalendarProvider
    let nowPlaying: NowPlayingProvider

    /// Which module the stage currently shows — driven by the tile strip.
    enum Stage {
        case timer
        case calendar
        case nowPlaying
    }

    // Owned here (not in NotchPanelController) so the clipboard slice stays
    // fully decoupled from the HUD/Timer slices (documented trade). Because
    // history is in-memory and clears on quit anyway (D-14), the negligible
    // reset on a rare screen-parameter rebuild of this view is acceptable.
    @State private var clipboard = ClipboardViewModel()
    @State private var stage: Stage = .timer

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.sm) {
            CockpitTileStripView(stage: $stage, timer: timer, calendar: calendar, nowPlaying: nowPlaying)

            stageContainer

            // The stage sizes to its content; the Clipboard takes whatever
            // vertical space is left so there is never a dead whitespace band
            // under a compact stage.
            ClipboardPanelView(clipboard: clipboard)
                .frame(maxHeight: .infinity, alignment: .top)
        }
        .padding(Tokens.Spacing.md)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// The inset stage panel: a slightly-darker-than-tiles ground with a
    /// hairline border, sized to its content (no fixed/min height) so the
    /// Clipboard below can claim the rest.
    private var stageContainer: some View {
        Group {
            switch stage {
            case .timer:
                TimerPanelView(timer: timer)
            case .calendar:
                CalendarPanelView(calendar: calendar)
            case .nowPlaying:
                NowPlayingPanelView(nowPlaying: nowPlaying)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Tokens.Spacing.md)
        .background(Tokens.Color.surface)
        .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.md))
        .overlay {
            RoundedRectangle(cornerRadius: Tokens.Radius.md)
                .stroke(Tokens.Color.hairline, lineWidth: 1)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
