import AppKit
import SwiftUI
import ServiceManagement
import OSLog
import MyIslandCore
import KeyboardShortcuts

extension Notification.Name {
    static let openMyIslandSettings = Notification.Name("openMyIslandSettings")
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var notchPanelController: NotchPanelController?
    private var settingsWindow: NSWindow?
    private let logger = Logger(subsystem: AppIdentity.bundleID, category: "AppDelegate")

    func applicationDidFinishLaunching(_ notification: Notification) {
        notchPanelController = NotchPanelController()

        KeyboardShortcuts.onKeyDown(for: .toggleNotchPanel) { [weak self] in
            self?.notchPanelController?.toggle()
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(showSettings),
            name: .openMyIslandSettings,
            object: nil
        )

        do {
            try SMAppService.mainApp.register()
        } catch {
            logger.error("Login item registration failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        .terminateNow
    }

    // D-13: the adapter subprocess runs for the app's whole lifetime, started
    // at launch (NowPlayingProvider.init()) and stopped at quit — without
    // this, the perl subprocess would outlive the app as an orphan process.
    func applicationWillTerminate(_ notification: Notification) {
        notchPanelController?.nowPlayingProvider.stopService()
    }

    // Promotes the app to `.regular` and activates it while the Settings
    // window is open — the notch panel is a non-activating overlay, so its
    // hosted KeyboardShortcuts.Recorder (and the system's conflict-alert
    // modal) has no activated app to anchor to (Dicticus pattern).
    @objc func showSettings() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        guard let calendarProvider = notchPanelController?.calendarProvider else {
            logger.error("showSettings() called before notchPanelController was initialized")
            return
        }

        if settingsWindow == nil {
            let hosting = NSHostingController(rootView: SettingsView(calendar: calendarProvider))
            let win = NSWindow(contentViewController: hosting)
            win.title = "my-island Settings"
            win.styleMask = [.titled, .closable]
            win.isReleasedWhenClosed = false
            win.delegate = self
            win.setContentSize(NSSize(width: 420, height: 460))
            win.center()
            settingsWindow = win
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
