import Foundation

/// DIAGNOSTIC ONLY (plan 04-02 checkpoint rounds 3-6, Calendar TCC prompt
/// investigation). Round 5's real-hardware log capture showed our own NSLog
/// content redacted as `<private>` by the unified logging system's default
/// privacy policy for third-party processes — the diagnostic code paths WERE
/// executing, but the string content was invisible in `log stream`. Appending
/// to a plain file guarantees visibility regardless of system log privacy
/// rules. Remove this file (and all `DebugLog.write` call sites) once the
/// Calendar TCC checkpoint (plan 04-02 Task 3) is confirmed passing.
enum DebugLog {
    private static let path = "/tmp/my-island-swift-debug.log"
    private static let queue = DispatchQueue(label: "com.maksim101.myisland.debuglog")

    static func write(_ message: String) {
        queue.async {
            let line = "\(Date()) \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            if FileManager.default.fileExists(atPath: path), let handle = FileHandle(forWritingAtPath: path) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: URL(fileURLWithPath: path))
            }
        }
    }
}
