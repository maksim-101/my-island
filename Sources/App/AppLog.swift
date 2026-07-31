import OSLog
import MyIslandCore

/// The app's logger factory. Returns a real `os.Logger` in **Debug** builds (logging is for testing)
/// and a **fully-disabled** logger in **Release** so the shipped app emits NO logging whatsoever —
/// `OSLog.disabled` discards every message at every level without even building it. Call sites keep
/// the exact `os.Logger` API, privacy annotations and all; only the destination changes by build.
enum AppLog {
    static func make(_ category: String) -> Logger {
        #if DEBUG
        return Logger(subsystem: AppIdentity.bundleID, category: category)
        #else
        return Logger(OSLog.disabled)
        #endif
    }
}
