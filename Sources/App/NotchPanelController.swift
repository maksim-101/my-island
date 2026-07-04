import AppKit
import SwiftUI
import OSLog
import MyIslandCore

@MainActor
final class NotchPanelController: NSObject {
    private static let expandedWidthMultiplier: CGFloat = 3.5
    private static let expandedHeight: CGFloat = 200

    private var panels: [NotchPanel] = []
    private let viewModel = NotchViewModel()
    private let logger = Logger(subsystem: AppIdentity.bundleID, category: "NotchPanelController")

    override init() {
        super.init()

        for screen in NSScreen.screens {
            guard let notchFrame = screen.notchFrame else {
                logger.info("No notch on this screen — dormant, no panel created (SHELL-05/D-11)")
                continue
            }

            let panel = Self.makePanel(notchFrame: notchFrame, screen: screen, model: viewModel)
            panels.append(panel)
            panel.orderFrontRegardless()
        }

        logger.info("Initialized with \(self.panels.count, privacy: .public) notch panel(s)")
    }

    private static func makePanel(notchFrame: NSRect, screen: NSScreen, model: NotchViewModel) -> NotchPanel {
        let width = notchFrame.width * expandedWidthMultiplier
        let height = expandedHeight
        let contentRect = NSRect(x: 0, y: 0, width: width, height: height)
        let styleMask: NSWindow.StyleMask = [.borderless, .nonactivatingPanel, .utilityWindow]

        let panel = NotchPanel(contentRect: contentRect, styleMask: styleMask, backing: .buffered, defer: false)
        panel.contentView = NSHostingView(rootView: NotchContentView(model: model))

        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = false
        panel.isReleasedWhenClosed = false

        panel.setFrameOrigin(NSPoint(
            x: notchFrame.midX - panel.frame.width / 2,
            y: screen.frame.maxY - panel.frame.height
        ))

        return panel
    }

    func toggle() {
        withAnimation(.interactiveSpring(response: 0.38, dampingFraction: 0.8)) {
            viewModel.toggle()
        }
    }
}

private final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
