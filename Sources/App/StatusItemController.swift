import AppKit

@MainActor
final class StatusItemController: NSObject {
    private let statusItem: NSStatusItem

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        statusItem.button?.title = "◐"

        let menu = NSMenu()
        let testItem = NSMenuItem(title: "Test Automation Permission…", action: #selector(testAutomationPermission), keyEquivalent: "")
        let quitItem = NSMenuItem(title: "Quit my-island", action: #selector(quit), keyEquivalent: "q")
        for item in [testItem, quitItem] {
            item.target = self
        }
        menu.addItem(testItem)
        menu.addItem(.separator())
        menu.addItem(quitItem)
        statusItem.menu = menu
    }

    @objc private func testAutomationPermission() {
        PermissionProbe.run()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
