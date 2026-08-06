import Foundation
import OSLog
import MyIslandCore

/// The app's logger factory. In **Debug** builds every call site always gets a real `os.Logger`
/// (logging is for testing). In **Release** builds the shipped app emits NO logging by default —
/// `OSLog.disabled` discards every message at every level without even building it — unless a
/// human has explicitly opted in on this one machine by setting the `MyIslandVerboseLogging`
/// UserDefaults key (`defaults write com.maksim101.myisland MyIslandVerboseLogging -bool YES`, or
/// a matching `-MyIslandVerboseLogging YES` launch argument). `defaults delete` removes the opt-in
/// entirely, restoring silence. This exists because a Release build has to be able to prove things
/// about itself during on-hardware verification — the smallest opening that allows that without
/// making everyday runs noisy.
///
/// `isEnabled` is resolved once, as a `static let`, not re-read on every `make(_:)` call — so
/// flipping the preference takes effect only after the app is relaunched, since every long-lived
/// object builds its logger during startup. Call sites keep the exact `os.Logger` API, privacy
/// annotations and all; only the destination changes.
enum AppLog {
    private static let verboseKey = "MyIslandVerboseLogging"

    static let isEnabled: Bool = {
        #if DEBUG
        return true
        #else
        return UserDefaults.standard.bool(forKey: verboseKey)
        #endif
    }()

    static func make(_ category: String) -> Logger {
        guard isEnabled else {
            return Logger(OSLog.disabled)
        }
        return Logger(subsystem: AppIdentity.bundleID, category: category)
    }
}
