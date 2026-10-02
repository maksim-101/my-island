import AppKit
import SwiftUI
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
    private let logger = AppLog.make("AppDelegate")

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.dropRemovedSettings()

        notchPanelController = NotchPanelController()

        // PANEL-09 (07-12): the dedicated hotkey entry point — takes key focus (the one
        // documented exception, see `NotchPanel.canBecomeKey`'s own doc comment) and seeds
        // `BandFocus`; `NotchPanelController.toggle()` (used by no other caller) stays the
        // plain, non-key-taking open/close.
        KeyboardShortcuts.onKeyDown(for: .toggleNotchPanel) { [weak self] in
            self?.notchPanelController?.toggleFromHotkey()
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(showSettings),
            name: .openMyIslandSettings,
            object: nil
        )
    }

    /// The app has no menu-bar item; launching it again (Spotlight, Finder) is the way in when no
    /// notch panel is on screen.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }

    private static func dropRemovedSettings() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "com.myisland.surfaceMaterial")
        defaults.removeObject(forKey: "NSStatusItem Preferred Position Item-0")
        defaults.removeObject(forKey: "NSWindow Frame com_apple_SwiftUI_Settings_window")
        defaults.removeObject(forKey: "com.myisland.wingLeftContent")
        if let stored = defaults.string(forKey: NotchPanelController.enabledModulesKey) {
            let kept = BandModules.enabled(from: stored.split(separator: ",").map(String.init)).map(\.rawValue).joined(separator: ",")
            if kept != stored { defaults.set(kept, forKey: NotchPanelController.enabledModulesKey) }
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

        guard let calendarProvider = notchPanelController?.calendarProvider,
              let controller = notchPanelController else {
            logger.error("showSettings() called before notchPanelController was initialized")
            return
        }

        if settingsWindow == nil {
            let hosting = NSHostingController(rootView: SettingsView(calendar: calendarProvider, panels: controller))
            let win = NSWindow(contentViewController: hosting)
            win.title = "my-island Settings"
            win.styleMask = [.titled, .closable]
            win.isReleasedWhenClosed = false
            win.delegate = self
            win.center()
            settingsWindow = win
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
