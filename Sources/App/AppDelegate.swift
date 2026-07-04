import AppKit
import ServiceManagement
import OSLog
import MyIslandCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemController: StatusItemController?
    private let logger = Logger(subsystem: AppIdentity.bundleID, category: "AppDelegate")

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItemController = StatusItemController()

        do {
            try SMAppService.mainApp.register()
        } catch {
            logger.error("Login item registration failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        .terminateNow
    }
}
