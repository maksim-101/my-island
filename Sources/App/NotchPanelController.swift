import AppKit
import SwiftUI
import OSLog
import MyIslandCore

@MainActor
final class NotchPanelController: NSObject {
    private var panels: [NotchPanel] = []
    // One per notched screen: the collapsed notch's "extended pill" — a single
    // continuous black shape spanning the cutout plus equal ear strips, with the
    // running-timer readout on the right (see NotchBarView). The collapsed strip
    // over the cutout is invisible to the eye, so the readout must live in the
    // visible ears; drawing it as one shape avoids seams. Kept separate from the
    // notch panel so it never participates in the open/HUD morph.
    private var barPanels: [NSPanel] = []
    // One per notched screen: the detached Liquid Glass Ambient HUD pill that
    // floats just below the notch (HUDPillView). Independent of the notch/wings
    // so its width never has to match them.
    private var hudPanels: [NSPanel] = []
    private let logger = Logger(subsystem: AppIdentity.bundleID, category: "NotchPanelController")
    nonisolated(unsafe) private var screenObserver: NSObjectProtocol?
    // Observe-only mouse monitors (never intercept clicks) that let a hover over
    // the timer wings drive the same dwell-to-expand as a hover over the notch.
    // The wing pill window itself is click-through (ignoresMouseEvents), so it
    // can't host tracking areas — position monitoring is how we detect the hover.
    nonisolated(unsafe) private var localMouseMonitor: Any?
    nonisolated(unsafe) private var globalMouseMonitor: Any?

    // Owned ONCE here (not inside `rebuildPanels`) so a running timer
    // survives a screen-parameter change — every rebuilt panel is injected
    // with this SAME instance, never a fresh one.
    private let timer = TimerViewModel()

    // Also owned ONCE here — the HUD providers/arbiter must not be recreated
    // per-screen or their listeners would leak/duplicate every time
    // `rebuildPanels` runs (clamshell open/close, display attach/detach).
    private let volumeProvider = VolumeProvider()
    private let brightnessProvider = BrightnessProvider()
    private let hud = HUDViewModel()

    // Owned ONCE here too, alongside the other providers above — the
    // Calendar auth state (and the fetched next event) must persist across a
    // screen-parameter rebuild and later feed the HUD. No HUD/threshold
    // callback wiring yet (that lands in plan 04-04). Exposed (not private)
    // so `AppDelegate.showSettings()` can thread this SAME instance into
    // `SettingsView`'s per-calendar picker (Task 3) rather than creating a
    // second, unsynchronized `CalendarProvider`.
    let calendarProvider = CalendarProvider()

    // Owned ONCE here too (Phase 5, D-05/D-13): the adapter subprocess must
    // survive a screen-parameter rebuild exactly like the other providers
    // above, and must be a SINGLE instance so its subprocess is never
    // launched twice. Exposed (not private) so `AppDelegate` can stop the
    // adapter subprocess at quit (D-13's "stopped at quit").
    let nowPlayingProvider = NowPlayingProvider()

    override init() {
        super.init()

        volumeProvider.onChange = { [weak self] in
            guard let self else { return }
            self.hud.showVolume(level: Double(self.volumeProvider.level), muted: self.volumeProvider.isMuted)
        }
        // Only wired when the private brightness bridge actually resolved —
        // an unavailable BrightnessProvider must never surface a HUD row
        // (T-03-B2).
        if brightnessProvider.isAvailable {
            brightnessProvider.onChange = { [weak self] in
                guard let self, let level = self.brightnessProvider.level else { return }
                self.hud.showBrightness(level: Double(level))
            }
        }
        // The Ambient HUD is now a detached glass pill below the notch
        // (HUDPillView in its own window), so it no longer resizes the notch
        // window — the pill window is always present and shows/hides its content
        // as SwiftUI observes `hud.isShowingHUD`.

        // Meeting bump (CAL-01/D-02): same [weak self] guard-let idiom as
        // volumeProvider.onChange/brightnessProvider.onChange above — no new
        // panel window, the bump reuses the existing detached hudPanels.
        // calendarProvider's own init() already kicks off the initial
        // fetch/scheduling when authorization is already granted.
        calendarProvider.onThresholdCrossed = { [weak self] text in
            guard let self else { return }
            self.hud.showMeeting(text: text)
        }

        rebuildPanels()

        // Mouse-position monitors (observe-only — return the event unmodified /
        // consume nothing) so a hover over a timer wing expands the notch like a
        // hover over the notch itself. Global fires while another app is active
        // (the usual case for this accessory app); local fires while our own
        // Settings window is key. Mouse-moved monitors need no special TCC grant.
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            self?.handleMouseMoved()
            return event
        }
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            self?.handleMouseMoved()
        }

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
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
    }

    /// Rebuilds `panels` from the current `NSScreen.screens` (SHELL-05,
    /// WR-01) — closes panels for screens that disappeared and creates
    /// panels for newly notched screens. Called at launch and whenever
    /// `NSApplication.didChangeScreenParametersNotification` fires (clamshell
    /// open/close, display attach/detach).
    private func rebuildPanels() {
        for panel in panels {
            panel.pendingCollapse?.cancel()
            panel.pendingDwellOpen?.cancel()
            panel.pendingHoverClose?.cancel()
            panel.orderOut(nil)
        }
        panels.removeAll()
        barPanels.forEach { $0.orderOut(nil) }
        barPanels.removeAll()
        hudPanels.forEach { $0.orderOut(nil) }
        hudPanels.removeAll()

        for screen in NSScreen.screens {
            guard let notchFrame = screen.notchFrame else {
                logger.info("No notch on this screen — dormant, no panel created (SHELL-05/D-11)")
                continue
            }

            let model = NotchViewModel()
            let panel = Self.makePanel(notchFrame: notchFrame, screen: screen, model: model, timer: timer, calendar: calendarProvider)
            model.onOpenChange = { [weak self, weak panel] isOpen in
                guard let self, let panel else { return }
                self.applyFrame(to: panel, isOpen: isOpen)
            }
            panels.append(panel)
            panel.orderFrontRegardless()

            let bar = Self.makeBarPanel(notchFrame: notchFrame, anchorMaxY: screen.frame.maxY, timer: timer, model: model, nowPlaying: nowPlayingProvider)
            barPanels.append(bar)
            bar.orderFrontRegardless()

            let hudPanel = Self.makeHudPanel(notchFrame: notchFrame, anchorMaxY: screen.frame.maxY, hud: hud)
            hudPanels.append(hudPanel)
            hudPanel.orderFrontRegardless()
        }

        logger.info("Initialized with \(self.panels.count, privacy: .public) notch panel(s)")
    }

    private static func makePanel(notchFrame: NSRect, screen: NSScreen, model: NotchViewModel, timer: TimerViewModel, calendar: CalendarProvider) -> NotchPanel {
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

        let hostingView = NSHostingView(rootView: NotchContentView(model: model, notchSize: notchFrame.size, timer: timer, calendar: calendar))
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

        // A plain `NSView` cannot be relied upon for hover detection here:
        // `ExpandedPanelView`'s `KeyboardShortcuts.Recorder` (an AppKit
        // `NSView` bridged via `NSViewRepresentable`) is positioned on the
        // left of the panel and does not reliably honor SwiftUI's
        // `.allowsHitTesting(false)` for its own event tracking, so it
        // silently swallows hover over the left half of the collapsed notch
        // and SwiftUI's `.onHover` never fires there (SHELL-11). A
        // `NSTrackingArea` on this container — whose bounds always equal the
        // window's full content rect, collapsed or expanded — sidesteps
        // SwiftUI/NSView hit-testing entirely and is coordinate-exact for
        // both notch halves.
        let container = HoverTrackingView(frame: NSRect(origin: .zero, size: collapsedFrame.size))
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
        // Horizontal centering + top-pinning across window resizes is owned by
        // `HoverTrackingView.resizeSubviews(withOldSize:)`, NOT an
        // `autoresizingMask`. The mask corrupts this: because the hosting view
        // is WIDER than the collapsed container (expandedWidth 2.2× the notch),
        // AppKit's autoresizing snaps the overflowing view to x=0 on the
        // collapsed→HUD-bump `setFrame` (height grows, width stays notch-sized),
        // which right-shifts the centered HUD content into the clipped right
        // half of the notch (only half the bump shows). Verified via an
        // offscreen render harness reproducing the exact geometry.
        container.addSubview(hostingView)
        container.onHoverChange = { [weak panel] hovering in
            guard let panel else { return }
            panel.notchHovering = hovering
            NotchPanelController.applyHover(panel: panel)
        }
        panel.contentView = container

        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = false
        panel.isReleasedWhenClosed = false
        // Stay non-activating, but allow the panel to become key ONLY when a
        // view that needs first-responder status is clicked — i.e. the duration
        // text field. Plain buttons (Start, presets) don't trigger it, so the
        // ambient overlay never steals focus except to accept typed input.
        panel.becomesKeyOnlyIfNeeded = true

        return panel
    }

    /// The non-interactive "extended pill" window: spans the notch cutout plus
    /// an equal ear strip on each side, and hosts `NotchBarView`, which draws a
    /// single continuous black `NotchShape` across the whole span (seamless — no
    /// join with the notch) with the running-timer readout on the right. The
    /// symmetric left strip keeps the extended notch balanced.
    /// How far the extended pill reaches into each ear beyond the cutout. Wide
    /// enough for the longest readout (e.g. a 180-minute countdown, "180:00");
    /// equal on both sides so the extended notch reads symmetric.
    private static let barEar: CGFloat = 84

    /// Global-coordinate frame of the extended pill (also the wing hover
    /// region), shared by `makeBarPanel` and the wing mouse-monitor.
    private static func barFrame(notchFrame: NSRect, anchorMaxY: CGFloat) -> NSRect {
        NSRect(
            x: notchFrame.minX - barEar,
            y: anchorMaxY - notchFrame.height,
            width: notchFrame.width + barEar * 2,
            height: notchFrame.height
        )
    }

    /// The Ambient HUD pill window — floats centered just below the notch, sized
    /// generously so the Liquid Glass capsule + its transition never clip. The
    /// pill content shows/hides itself as SwiftUI observes `hud`.
    private static func makeHudPanel(notchFrame: NSRect, anchorMaxY: CGFloat, hud: HUDViewModel) -> NSPanel {
        // Generous window so the pill's glow/shadow never clip; HUDPillView pins
        // its capsule to the top so it hangs just under the notch, with the
        // extra height below reserved for the glow.
        let width: CGFloat = 220
        let height: CGFloat = 56
        let frame = NSRect(
            x: notchFrame.midX - width / 2,
            y: anchorMaxY - notchFrame.height - NotchLayout.hudPillGap - height,
            width: width,
            height: height
        )
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel, .utilityWindow], backing: .buffered, defer: false)

        let container = NSView(frame: NSRect(origin: .zero, size: frame.size))
        container.autoresizesSubviews = true
        let hosting = NSHostingView(rootView: HUDPillView(hud: hud))
        hosting.frame = NSRect(origin: .zero, size: frame.size)
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        panel.contentView = container

        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        return panel
    }

    private static func makeBarPanel(notchFrame: NSRect, anchorMaxY: CGFloat, timer: TimerViewModel, model: NotchViewModel, nowPlaying: NowPlayingProvider) -> NSPanel {
        let frame = barFrame(notchFrame: notchFrame, anchorMaxY: anchorMaxY)
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel, .utilityWindow], backing: .buffered, defer: false)

        let container = NSView(frame: NSRect(origin: .zero, size: frame.size))
        container.autoresizesSubviews = true
        let hosting = NSHostingView(rootView: NotchBarView(timer: timer, model: model, nowPlaying: nowPlaying))
        hosting.frame = NSRect(origin: .zero, size: frame.size)
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        panel.contentView = container

        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true   // readout only — never intercept clicks
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

    /// The one place that decides whether a given panel's window is at its
    /// collapsed (notch) or expanded size. The Ambient HUD no longer factors in
    /// here — it's a detached pill in its own window.
    private func resolvedFrame(for panel: NotchPanel) -> NSRect {
        if panel.viewModel?.isOpen == true {
            return Self.expandedFrame(notchFrame: panel.notchFrame, anchorMaxY: panel.anchorMaxY)
        }
        return Self.collapsedFrame(notchFrame: panel.notchFrame, anchorMaxY: panel.anchorMaxY)
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

        // DIAGNOSTIC ONLY (plan 04-02 checkpoint round 5): correlate frame
        // changes against the hover-transition log in NotchViewModel and the
        // click-probe log lines from round 4 — testing whether the panel is
        // collapsing right around the moment a click on Grant Access lands.
        let frame = resolvedFrame(for: panel)

        if isOpen {
            panel.setFrame(frame, display: true)
        } else {
            let work = DispatchWorkItem { [weak self, weak panel] in
                guard let self, let panel, panel.viewModel?.isOpen != true else {
                    return
                }
                let collapseFrame = self.resolvedFrame(for: panel)
                panel.setFrame(collapseFrame, display: true)
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

    /// Drives the hover-dwell state machine from the `HoverTrackingView`'s
    /// AppKit `NSTrackingArea` enter/exit events (SHELL-11 fix), replacing
    /// SwiftUI `.onHover` — which the left half of the notch never received
    /// (see `container` comment in `makePanel`). Mirrors the previous
    /// `NotchContentView.handleHover` timing exactly (0.25s open dwell,
    /// 0.1s close grace, cancel-on-new-event) but uses `DispatchWorkItem`s
    /// hung off the panel instead of a SwiftUI `@State` `Task`, matching the
    /// existing `pendingCollapse` pattern in this controller.
    private static func handleHoverChange(panel: NotchPanel, hovering: Bool) {
        panel.pendingDwellOpen?.cancel()
        panel.pendingDwellOpen = nil
        panel.pendingHoverClose?.cancel()
        panel.pendingHoverClose = nil

        guard let model = panel.viewModel else { return }


        if hovering {
            model.hoverBegan()
            let work = DispatchWorkItem { [weak panel] in
                guard let model = panel?.viewModel else { return }
                withAnimation(NotchLayout.morphAnimation) {
                    model.dwellElapsed()
                }
            }
            panel.pendingDwellOpen = work
            DispatchQueue.main.asyncAfter(deadline: .now() + NotchLayout.hoverDwellDelay, execute: work)
        } else {
            let work = DispatchWorkItem { [weak panel] in
                guard let model = panel?.viewModel else { return }
                withAnimation(NotchLayout.morphAnimation) {
                    model.hoverEnded()
                }
            }
            panel.pendingHoverClose = work
            DispatchQueue.main.asyncAfter(deadline: .now() + NotchLayout.hoverCollapseGrace, execute: work)
        }
    }

    /// Updates each panel's `wingHovering` from the current mouse position: the
    /// mouse is "over a wing" when the pill is visible — a timer is running OR
    /// the Now Playing ear has content (D-05 disjunction) — and the cursor is
    /// inside the extended-pill frame but outside the notch's own tracking
    /// region (which the `NSTrackingArea` already owns). Only fires the dwell
    /// logic on an actual change, so this is cheap on every move.
    private func handleMouseMoved() {
        let mouse = NSEvent.mouseLocation
        for panel in panels {
            let inBar = (timer.isRunning || nowPlayingProvider.displayEar)
                && Self.barFrame(notchFrame: panel.notchFrame, anchorMaxY: panel.anchorMaxY).contains(mouse)
            let inNotch = Self.collapsedFrame(notchFrame: panel.notchFrame, anchorMaxY: panel.anchorMaxY).contains(mouse)
            let wing = inBar && !inNotch
            if panel.wingHovering != wing {
                panel.wingHovering = wing
                Self.applyHover(panel: panel)
            }
        }
    }

    /// Collapses the notch-tracking-area and wing-monitor hover sources into a
    /// single dwell state, so moving the cursor between the notch and a wing
    /// never reads as a leave (which would flicker the panel closed).
    private static func applyHover(panel: NotchPanel) {
        let hovering = panel.notchHovering || panel.wingHovering
        guard hovering != panel.lastHoverApplied else { return }
        panel.lastHoverApplied = hovering
        handleHoverChange(panel: panel, hovering: hovering)
    }
}

/// Tracks hover over the container's full bounds via AppKit's
/// `NSTrackingArea` rather than SwiftUI `.onHover`, which is unreliable here
/// (see `container` comment in `NotchPanelController.makePanel`). `.zero` +
/// `.inVisibleRect` keeps the tracking rect pinned to the view's current
/// bounds automatically as `applyFrame` resizes the window between the
/// collapsed notch size and the expanded panel size.
private final class HoverTrackingView: NSView {
    var onHoverChange: ((Bool) -> Void)?

    /// Keeps the (wider-than-container) hosting subview horizontally centered
    /// and top-pinned on every window resize, replacing the `autoresizingMask`
    /// that corrupted the hosting view's x (snapping it to 0 on the
    /// collapsed→HUD-bump resize, clipping the HUD to the notch's right half).
    /// Does NOT call `super` — this view owns its single subview's geometry.
    override func resizeSubviews(withOldSize oldSize: NSSize) {
        guard let hosting = subviews.first else { return }
        hosting.setFrameOrigin(NSPoint(
            x: ((bounds.width - hosting.frame.width) / 2).rounded(),
            y: bounds.height - hosting.frame.height
        ))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) { onHoverChange?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChange?(false) }
}

/// Each screen's panel owns its own `NotchViewModel` (IN-02) — hovering or
/// toggling one screen's notch must not open/close another screen's.
private final class NotchPanel: NSPanel {
    weak var viewModel: NotchViewModel?
    var notchFrame: NSRect = .zero
    var anchorMaxY: CGFloat = 0
    var pendingCollapse: DispatchWorkItem?
    var pendingDwellOpen: DispatchWorkItem?
    var pendingHoverClose: DispatchWorkItem?
    // Two independent hover sources unified into one dwell state (see
    // `applyHover`): the notch's `NSTrackingArea` and the wing mouse-monitor.
    var notchHovering = false
    var wingHovering = false
    var lastHoverApplied = false

    // Purely non-activating (Dicticus pattern): the hotkey recorder now lives
    // in a dedicated, activated Settings window (AppDelegate.showSettings),
    // so the notch panel never needs to become key/main and never steals
    // focus or activation from whatever the user is doing.
    // Can become key (so the duration text field accepts typing) but only when
    // needed — `becomesKeyOnlyIfNeeded` limits that to text-field clicks, so the
    // panel stays a non-activating ambient overlay otherwise. Never main.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    // The notch overlay is a fixed, level-27 ambient window — it must never be
    // miniaturized or closed by the standard Window menu commands (⌘M / ⌘W),
    // which would otherwise reset its window level and position. Kept as a
    // defensive no-op even though the panel no longer becomes key.
    override func miniaturize(_ sender: Any?) { /* no-op: notch panel is not miniaturizable */ }
    override func performMiniaturize(_ sender: Any?) { /* no-op */ }
    override func performClose(_ sender: Any?) { /* no-op: not user-closable; Quit is via the panel's power button */ }
}
