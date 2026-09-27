import Foundation

/// Which ambient signal the HUD is currently showing.
enum HUDGlyph {
    case brightness
    case volume
    case volumeMuted
    /// The transient meeting-countdown bump (CAL-01/D-02) — a structured `MeetingAlert`, not a
    /// level-bar glyph; see `HUDViewModel.meeting` and `AlertDropView`'s meeting-content branch.
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

/// 07-05 Task 2 (PANEL-07): the meeting alert's structured payload — title, a short lead
/// ("60m"/"15m"/"now") and an optional join link — replacing the old pre-built "{title} in {N}m"
/// sentence so `AlertDropView` can measure/lay out and size each piece independently (Task 3)
/// instead of truncating one opaque string.
struct MeetingAlert: Equatable {
    let title: String
    let lead: String
    let joinURL: URL?
}

/// The single arbiter (Pitfall 4) that coalesces `VolumeProvider` and
/// `BrightnessProvider` into one transient HUD takeover state. Does NOT own
/// either provider — `NotchPanelController` wires their `onChange` callbacks
/// into `showVolume`/`showBrightness`. Every change (re)arms a ~1.5s fade via
/// a cancel-then-reschedule `DispatchWorkItem`, mirroring
/// `NotchPanelController`'s `pendingCollapse` idiom, so the HUD stays up
/// until `NotchLayout.hudFadeDelay` after the LAST change.
///
/// 07-05: `isShowingHUD`'s flips are the sole trigger for the HUD/alert
/// drop's own fall/rise (`onVisibilityChange`, wired in
/// `NotchPanelController.init`) — this class owns none of that geometry
/// itself, only the arbitration of WHICH content (level glyph+bar, or a
/// meeting bump) is currently live.
@MainActor
@Observable
final class HUDViewModel {
    private(set) var isShowingHUD: Bool = false
    private(set) var level: Double = 0
    private(set) var glyph: HUDGlyph = .volume
    /// Non-nil only for the meeting bump (set by the meeting entry point below) — nil for the
    /// brightness/volume level-bar glyphs. `AlertDropView`/`NotchPanelController` branch their drop
    /// content and sizing on this.
    private(set) var meeting: MeetingAlert?

    /// Fired synchronously whenever `isShowingHUD` flips — the controller
    /// uses this to start/end the HUD/alert drop's fall and rise on every
    /// collapsed panel's own `FluidMotion` clock.
    var onVisibilityChange: ((Bool) -> Void)?

    private var pendingFade: DispatchWorkItem?

    func showBrightness(level: Double) {
        show(glyph: .brightness, level: level)
    }

    func showVolume(level: Double, muted: Bool) {
        show(glyph: muted ? .volumeMuted : .volume, level: level)
    }

    /// The meeting-bump entry point (CAL-01/D-02) — reuses this same arbiter
    /// and the shared HUD/alert drop mechanism, but arms a longer
    /// `NotchLayout.meetingBumpFadeDelay` dwell (a full sentence needs more
    /// read time than the ~1.5s brightness/volume nudge) instead of
    /// `hudFadeDelay`.
    func showMeeting(title: String, lead: String, joinURL: URL?) {
        show(glyph: .meeting, level: 0, meeting: MeetingAlert(title: title, lead: lead, joinURL: joinURL), fadeDelay: NotchLayout.meetingBumpFadeDelay)
    }

    private func show(glyph: HUDGlyph, level: Double, meeting: MeetingAlert? = nil, fadeDelay: TimeInterval = NotchLayout.hudFadeDelay) {
        self.glyph = glyph
        self.level = level
        self.meeting = meeting

        if !isShowingHUD {
            isShowingHUD = true
            onVisibilityChange?(true)
        }

        armFade(after: fadeDelay)
    }

    /// 07-05 Task 3: Join ends the meeting drop 0.5s after being pressed, rather than waiting out
    /// the full `NotchLayout.meetingBumpFadeDelay` — re-arms the same fade path `armFade` already
    /// drives, just at a much shorter delay, so the drop's own retract animation (`endAlertDrop`)
    /// still runs exactly as it would at a normal timeout.
    func endSoon(after delay: TimeInterval = 0.5) {
        guard isShowingHUD else { return }
        armFade(after: delay)
    }

    /// 07-05 Task 3 (sketch's own `openBand`): opening the band by hotkey or hover-dwell ends any
    /// HUD/alert drop immediately, rather than waiting out its own fade delay — a drop and the
    /// expanding band must never show at once.
    func dismissNow() {
        guard isShowingHUD else { return }
        pendingFade?.cancel()
        pendingFade = nil
        isShowingHUD = false
        onVisibilityChange?(false)
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
