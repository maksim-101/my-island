import Foundation

/// Which ambient signal the HUD is currently showing.
enum HUDGlyph {
    case brightness
    case volume
    case volumeMuted
    /// The transient meeting-countdown bump (CAL-01/D-02) — a text-content
    /// glyph, not a level-bar one; see `HUDViewModel.text` and
    /// `HUDPillView`'s text-branch.
    case meeting

    /// SF Symbol name for `Image(systemName:)`.
    var systemName: String {
        switch self {
        case .brightness: return "sun.max"
        case .volume: return "speaker.wave.2"
        case .volumeMuted: return "speaker.slash"
        case .meeting: return "calendar"
        }
    }
}

/// The single arbiter (Pitfall 4) that coalesces `VolumeProvider` and
/// `BrightnessProvider` into one transient HUD takeover state. Does NOT own
/// either provider — `NotchPanelController` wires their `onChange` callbacks
/// into `showVolume`/`showBrightness`. Every change (re)arms a ~1.5s fade via
/// a cancel-then-reschedule `DispatchWorkItem`, mirroring
/// `NotchPanelController`'s `pendingCollapse` idiom, so the HUD stays up
/// until `NotchLayout.hudFadeDelay` after the LAST change.
@MainActor
@Observable
final class HUDViewModel {
    private(set) var isShowingHUD: Bool = false
    private(set) var level: Double = 0
    private(set) var glyph: HUDGlyph = .volume
    /// Non-nil only for the meeting bump (`showMeeting(text:)`) — nil for the
    /// brightness/volume level-bar glyphs. `HUDPillView` branches its pill
    /// content on this.
    private(set) var text: String?

    /// Fired synchronously whenever `isShowingHUD` flips — the controller
    /// uses this to grow/shrink the collapsed window frame.
    var onVisibilityChange: ((Bool) -> Void)?

    private var pendingFade: DispatchWorkItem?

    func showBrightness(level: Double) {
        show(glyph: .brightness, level: level)
    }

    func showVolume(level: Double, muted: Bool) {
        show(glyph: muted ? .volumeMuted : .volume, level: level)
    }

    /// The meeting-bump entry point (CAL-01/D-02) — reuses this same arbiter
    /// and the detached `HUDPillView` mechanism, but arms a longer
    /// `NotchLayout.meetingBumpFadeDelay` dwell (a full sentence needs more
    /// read time than the ~1.5s brightness/volume nudge) instead of
    /// `hudFadeDelay`.
    func showMeeting(text: String) {
        show(glyph: .meeting, level: 0, text: text, fadeDelay: NotchLayout.meetingBumpFadeDelay)
    }

    private func show(glyph: HUDGlyph, level: Double, text: String? = nil, fadeDelay: TimeInterval = NotchLayout.hudFadeDelay) {
        self.glyph = glyph
        self.level = level
        self.text = text

        if !isShowingHUD {
            isShowingHUD = true
            onVisibilityChange?(true)
        }

        armFade(after: fadeDelay)
    }

    private func armFade(after delay: TimeInterval) {
        pendingFade?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.isShowingHUD = false
            self.onVisibilityChange?(false)
        }
        pendingFade = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}
