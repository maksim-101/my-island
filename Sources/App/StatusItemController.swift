import AppKit

/// Owns the menu-bar status item that replaces the in-panel Settings/Quit chrome (PANEL-03).
/// Constructed once, as the first statement of `applicationDidFinishLaunching` — before the 07-01
/// spike branch — so Settings and Quit are reachable in every launch mode, independent of how many
/// notch panel sets exist. Mirrors `NotchPanelController`'s owning-controller convention: an
/// `NSObject` subclass, owned once by `AppDelegate`, logging via `AppLog.make`.
@MainActor
final class StatusItemController: NSObject {
    private let statusItem: NSStatusItem
    private let logger = AppLog.make("StatusItemController")

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        if let button = statusItem.button {
            let image = NSImage(
                systemSymbolName: "rectangle.topthird.inset.filled",
                accessibilityDescription: "my-island"
            )
            image?.isTemplate = true
            button.image = image
        }

        let menu = NSMenu()

        let settingsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit my-island",
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu

        logger.notice("statusItem ready")
    }

    /// Reuses the same notification `AppDelegate.showSettings()` already observes — choosing this
    /// item twice brings the one existing window forward rather than opening a second.
    @objc private func openSettings() {
        NotificationCenter.default.post(name: .openMyIslandSettings, object: nil)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
