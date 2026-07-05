import AppKit
import SwiftUI
import OSLog
import MyIslandCore

@MainActor
final class NotchPanelController: NSObject {
    private var panels: [NotchPanel] = []
    private let logger = Logger(subsystem: AppIdentity.bundleID, category: "NotchPanelController")
    nonisolated(unsafe) private var screenObserver: NSObjectProtocol?

    override init() {
        super.init()

        rebuildPanels()

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.rebuildPanels()
            }
        }
    }

    deinit {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
    }

    /// Rebuilds `panels` from the current `NSScreen.screens` (SHELL-05,
    /// WR-01) — closes panels for screens that disappeared and creates
    /// panels for newly notched screens. Called at launch and whenever
    /// `NSApplication.didChangeScreenParametersNotification` fires (clamshell
    /// open/close, display attach/detach).
    private func rebuildPanels() {
        for panel in panels {
            panel.pendingCollapse?.cancel()
            panel.orderOut(nil)
        }
        panels.removeAll()

        for screen in NSScreen.screens {
            guard let notchFrame = screen.notchFrame else {
                logger.info("No notch on this screen — dormant, no panel created (SHELL-05/D-11)")
                continue
            }

            let model = NotchViewModel()
            let panel = Self.makePanel(notchFrame: notchFrame, screen: screen, model: model)
            model.onOpenChange = { [weak self, weak panel] isOpen in
                guard let self, let panel else { return }
                self.applyFrame(to: panel, isOpen: isOpen)
            }
            panels.append(panel)
            panel.orderFrontRegardless()
        }

        logger.info("Initialized with \(self.panels.count, privacy: .public) notch panel(s)")
    }

    private static func makePanel(notchFrame: NSRect, screen: NSScreen, model: NotchViewModel) -> NotchPanel {
        let anchorMaxY = screen.frame.maxY
        let collapsedFrame = Self.collapsedFrame(notchFrame: notchFrame, anchorMaxY: anchorMaxY)
        let styleMask: NSWindow.StyleMask = [.borderless, .nonactivatingPanel, .utilityWindow]

        // The panel window is created at the COLLAPSED (notch) size, not the
        // expanded size — this is the core fix for the dead click-zone: when
        // collapsed there is no window area below the notch, so nothing there
        // can be blocked. `applyFrame(to:isOpen:)` resizes it as the model
        // opens/closes.
        let panel = NotchPanel(contentRect: collapsedFrame, styleMask: styleMask, backing: .buffered, defer: false)
        panel.viewModel = model
        panel.notchFrame = notchFrame
        panel.anchorMaxY = anchorMaxY

        let hostingView = NSHostingView(rootView: NotchContentView(model: model, notchSize: notchFrame.size))
        // Decouple from the window's Auto Layout / constraint-update cycle:
        // `applyFrame` resizes the panel manually via `setFrame`, and letting
        // the hosting view participate in constraint-based sizing causes an
        // uncaught NSException (abort) the first time that manual resize
        // fires. Frame/autoresize-based sizing avoids the window display
        // cycle entirely while still tracking the window's content bounds.
        hostingView.sizingOptions = []
        hostingView.translatesAutoresizingMaskIntoConstraints = true

        // The hosting view is NOT the window's contentView. `NSHostingView`
        // calls `updateAnimatedWindowSize(_:)` on ITS OWN WINDOW whenever it
        // detects a `windowDidLayout` pass — if it IS the contentView, that
        // resizes the panel directly and collides with `applyFrame`'s manual
        // `setFrame`, aborting with an uncaught NSException. Wrapping it in a
        // plain `NSView` container means the window's contentView is never an
        // `NSHostingView`, so no window-resize feedback can originate from
        // SwiftUI's layout pass — `applyFrame` remains the ONLY code that
        // resizes the window.
        let expandedWidth = notchFrame.width * NotchLayout.expandedWidthMultiplier
        let expandedHeight = NotchLayout.expandedHeight

        let container = NSView(frame: NSRect(origin: .zero, size: collapsedFrame.size))
        container.autoresizesSubviews = true
        container.wantsLayer = true
        container.layer?.masksToBounds = true

        // Fixed at the expanded size (matches the constant SwiftUI content
        // size in `NotchContentView`), centered horizontally and top-pinned
        // within the container. While the container is collapsed (notch
        // sized), only the top-center notch region is visible; the rest is
        // clipped by `masksToBounds`. When `applyFrame` grows the window, the
        // full hosting content becomes visible without ever resizing itself.
        hostingView.frame = NSRect(
            x: (container.bounds.width - expandedWidth) / 2,
            y: container.bounds.height - expandedHeight,
            width: expandedWidth,
            height: expandedHeight
        )
        hostingView.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin]
        container.addSubview(hostingView)
        panel.contentView = container

        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = false
        panel.isReleasedWhenClosed = false

        return panel
    }

    /// The window frame while collapsed — exactly the physical notch, top
    /// edge flush with the screen's top edge, horizontally centered on it.
    private static func collapsedFrame(notchFrame: NSRect, anchorMaxY: CGFloat) -> NSRect {
        NSRect(
            x: notchFrame.midX - notchFrame.width / 2,
            y: anchorMaxY - notchFrame.height,
            width: notchFrame.width,
            height: notchFrame.height
        )
    }

    /// The window frame while expanded — grows downward from the notch,
    /// staying horizontally centered on it.
    private static func expandedFrame(notchFrame: NSRect, anchorMaxY: CGFloat) -> NSRect {
        let width = notchFrame.width * NotchLayout.expandedWidthMultiplier
        let height = NotchLayout.expandedHeight
        return NSRect(
            x: notchFrame.midX - width / 2,
            y: anchorMaxY - height,
            width: width,
            height: height
        )
    }

    /// Drives the AppKit window frame in step with the model's open/close
    /// state, regardless of whether that state change came from hover dwell
    /// or the global-hotkey `toggle()`.
    ///
    /// On expand, the window grows to its full size immediately — the extra
    /// area is transparent, so the jump is invisible, and the SwiftUI content
    /// morph (already animating via `NotchLayout.morphAnimation`) grows into
    /// it. On collapse, the window shrink is deferred until the content morph
    /// has visually finished (DEFECT B ordering), so the box never appears to
    /// pop/jump.
    private func applyFrame(to panel: NotchPanel, isOpen: Bool) {
        panel.pendingCollapse?.cancel()
        panel.pendingCollapse = nil

        if isOpen {
            panel.setFrame(Self.expandedFrame(notchFrame: panel.notchFrame, anchorMaxY: panel.anchorMaxY), display: true)
        } else {
            let work = DispatchWorkItem { [weak panel] in
                guard let panel, panel.viewModel?.isOpen != true else { return }
                panel.setFrame(
                    NotchPanelController.collapsedFrame(notchFrame: panel.notchFrame, anchorMaxY: panel.anchorMaxY),
                    display: true
                )
            }
            panel.pendingCollapse = work
            DispatchQueue.main.asyncAfter(deadline: .now() + NotchLayout.collapseWindowDelay, execute: work)
        }
    }

    func toggle() {
        withAnimation(NotchLayout.morphAnimation) {
            for panel in panels {
                panel.viewModel?.toggle()
            }
        }
    }
}

/// Each screen's panel owns its own `NotchViewModel` (IN-02) — hovering or
/// toggling one screen's notch must not open/close another screen's.
private final class NotchPanel: NSPanel {
    weak var viewModel: NotchViewModel?
    var notchFrame: NSRect = .zero
    var anchorMaxY: CGFloat = 0
    var pendingCollapse: DispatchWorkItem?

    // Becomes key only while expanded, so KeyboardShortcuts.Recorder can
    // capture a keystroke (CR-02); flips back to false once collapsed so the
    // ambient/non-activating hover behavior is preserved (no focus theft).
    override var canBecomeKey: Bool { viewModel?.isOpen ?? false }
    override var canBecomeMain: Bool { viewModel?.isOpen ?? false }
}
