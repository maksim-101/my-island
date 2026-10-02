import Foundation

/// HUD-05: whether my-island's own volume drop is shown. FineTune (`com.finetuneapp.FineTune`) keeps
/// the volume keys and its own HUD (user decision 2026-09-11), so the automatic choice steps aside
/// while it runs. A stored `override` replaces the automatic choice in both directions.
public enum VolumeHUDPolicy {
    public static func shouldShow(override: Bool?, fineTuneRunning: Bool) -> Bool {
        override ?? !fineTuneRunning
    }
}
