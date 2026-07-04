import AppKit
import ServiceManagement
import OSLog
import MyIslandCore
import KeyboardShortcuts

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var notchPanelController: NotchPanelController?
    private let logger = Logger(subsystem: AppIdentity.bundleID, category: "AppDelegate")

    func applicationDidFinishLaunching(_ notification: Notification) {
        notchPanelController = NotchPanelController()

        KeyboardShortcuts.onKeyDown(for: .toggleNotchPanel) { [weak self] in
            self?.notchPanelController?.toggle()
        }

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
