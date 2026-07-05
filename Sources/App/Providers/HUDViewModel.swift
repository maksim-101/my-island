import Foundation

/// Which ambient signal the HUD is currently showing.
enum HUDGlyph {
    case brightness
    case volume
    case volumeMuted

    /// SF Symbol name for `Image(systemName:)`.
    var systemName: String {
        switch self {
        case .brightness: return "sun.max"
        case .volume: return "speaker.wave.2"
        case .volumeMuted: return "speaker.slash"
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

    private func show(glyph: HUDGlyph, level: Double) {
        self.glyph = glyph
        self.level = level

        if !isShowingHUD {
            isShowingHUD = true
            onVisibilityChange?(true)
        }

        armFade()
    }

    private func armFade() {
        pendingFade?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.isShowingHUD = false
            self.onVisibilityChange?(false)
        }
        pendingFade = work
        DispatchQueue.main.asyncAfter(deadline: .now() + NotchLayout.hudFadeDelay, execute: work)
    }
}
