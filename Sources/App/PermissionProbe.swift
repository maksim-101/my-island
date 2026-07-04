import AppKit
import OSLog
import MyIslandCore

@MainActor
enum PermissionProbe {
    private static let logger = Logger(subsystem: AppIdentity.bundleID, category: "PermissionProbe")

    static func run() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "tell application \"System Events\" to count processes"]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            logger.error("Failed to launch osascript: \(error.localizedDescription, privacy: .public)")
            showAlert(style: .warning, message: "Could not run the Automation probe: \(error.localizedDescription)")
            return
        }

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        _ = outputData

        let stderr = String(data: errorData, encoding: .utf8) ?? ""

        if process.terminationStatus == 0 {
            logger.info("Automation permission granted")
            showAlert(style: .informational, message: "Automation permitted")
        } else if stderr.contains("-1743") || stderr.contains("Not authorized to send Apple events") {
            logger.warning("Automation permission denied: \(stderr, privacy: .public)")
            showAlert(style: .warning, message: "Automation not permitted. Open System Settings \u{2192} Privacy & Security \u{2192} Automation and enable my-island.")
        } else {
            logger.error("Automation probe failed: \(stderr, privacy: .public)")
            showAlert(style: .warning, message: stderr.isEmpty ? "Automation probe failed." : stderr)
        }
    }

    private static func showAlert(style: NSAlert.Style, message: String) {
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = message
        alert.runModal()
    }
}
