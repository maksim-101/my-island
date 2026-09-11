import AppKit
import SwiftUI
import OSLog
import MyIslandCore

@MainActor
final class NotchPanelController: NSObject {
    // One entry per connected screen, keyed by `NSScreen.displayKey` (Phase 6
    // SHELL-07): the interactive notch panel, the non-interactive extended-pill
    // bar (readouts, see NotchBarView), and the detached Ambient HUD pill
    // (HUDPillView). Replaces the old parallel `panels`/`barPanels`/`hudPanels`
    // arrays keyed only by rebuild order.
    private struct PanelSet {
        let panel: NotchPanel
        let bar: NSPanel
        let hud: NSPanel
        let model: NotchViewModel
    }
    private var panelSets: [String: PanelSet] = [:]
    // Kept so `toggle()`/`handleMouseMoved()`/`applyHover` — which only ever
    // need "every panel", not the key — compile unchanged against the new
    // dictionary-backed storage.
    private var panels: [NotchPanel] { panelSets.values.map(\.panel) }
    private let logger = AppLog.make("NotchPanelController")
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

    // Owned ONCE here too (Phase 5, D-10/D-11): the fullscreen signal must
    // survive a screen-parameter rebuild exactly like the other providers
    // above — creating it inside `rebuildPanels` would tear down and restart
    // its poll timer on every clamshell open/close or display change.
    private let fullscreenObserver = FullscreenObserver()

    override init() {
        super.init()

        // `level` is now `Float?` (T-7h2 §1.3): a device with no readable volume property hides
        // the row rather than showing the previous device's stale value, mirroring how
        // `brightnessProvider.onChange` already guards below.
        volumeProvider.onChange = { [weak self] in
            guard let self, let level = self.volumeProvider.level else { return }
            self.hud.showVolume(level: Double(level), muted: self.volumeProvider.isMuted)
        }
        // Only wired when the private brightness bridge actually resolved —
        // an unavailable BrightnessProvider must never surface a HUD row
        // (T-03-B2). `BrightnessScale.barFraction` is applied at this single wiring point only —
        // the volume path above keeps passing its raw level through unchanged (T-7h2 Task 1 step D).
        if brightnessProvider.isAvailable {
            brightnessProvider.onChange = { [weak self] in
                guard let self, let level = self.brightnessProvider.level else { return }
                self.hud.showBrightness(level: Double(BrightnessScale.barFraction(for: level)))
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

        // T-02-03 (02-SECURITY.md): a non-global replacement was evaluated first and rejected —
        // three checkable facts about this file rule it out. (a) The wing/bar panel window is
        // created click-through by design (its ignoresMouseEvents flag), so it cannot host a
        // tracking area — a tracking area needs a window that actually hit-tests the cursor.
        // (b) The interactive notch panel's HoverTrackingView tracking area is pinned to that
        // window's own content rect, which spans only the notch cutout, not the wider wing
        // strip — the wings sit outside the tracked region. (c) This app is LSUIElement and
        // never activates, and the interactive panel never opts in to mouse-moved events, so a
        // mouse-moved event over the wings while another app is frontmost never enters this
        // app's own event queue for a local monitor to see. The only way to make the wing strip
        // itself hit-testable would be a non-click-through window sitting on the menu-bar strip
        // beside the notch — which would swallow clicks on menu-bar and status items there, a
        // worse outcome than this finding.
        //
        // The monitor below is therefore kept, with the trade-off made explicit: it is
        // observe-only and non-consuming — it reads mouse-movement position only, never a
        // keystroke event mask, and never a low-level event-tap creation/enable call — so it
        // needs no TCC grant of any kind, and neither Info.plist nor MyIsland.entitlements
        // declares an input-monitoring or accessibility usage key. It lets a hover over a timer
        // wing expand the notch like a hover over the notch itself. Global fires while another
        // app is active (the usual case for this accessory app); local fires while our own
        // Settings window is key.
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
        for set in panelSets.values {
            set.panel.pendingCollapse?.cancel()
            set.panel.pendingDwellOpen?.cancel()
            set.panel.pendingHoverClose?.cancel()
            set.panel.orderOut(nil)
            set.bar.orderOut(nil)
            set.hud.orderOut(nil)
        }
        panelSets.removeAll()

        for screen in NSScreen.screens {
            // Every screen resolves to a Mode — physical cutout or synthetic
            // top-center pill (Phase 6 SHELL-06/07). The Phase 2 "dormant
            // elsewhere" skip is superseded; no screen is ever left without a
            // panel set.
            let mode = screen.notchMode
            let anchorRect = mode.anchorRect
            let key = screen.displayKey

            let model = NotchViewModel()
            let panel = Self.makePanel(notchFrame: anchorRect, screen: screen, isPhysical: mode.isPhysical, model: model, timer: timer, calendar: calendarProvider, nowPlaying: nowPlayingProvider)
            panel.displayID = screen.displayID
            model.onOpenChange = { [weak self, weak panel] isOpen in
                guard let self, let panel else { return }
                self.applyFrame(to: panel, isOpen: isOpen)
            }
            panel.orderFrontRegardless()

            let bar = Self.makeBarPanel(notchFrame: anchorRect, anchorMaxY: screen.frame.maxY, timer: timer, model: model, nowPlaying: nowPlayingProvider, fullscreen: fullscreenObserver, calendar: calendarProvider, mode: mode, displayID: screen.displayID)
            bar.orderFrontRegardless()

            let hudPanel = Self.makeHudPanel(notchFrame: anchorRect, anchorMaxY: screen.frame.maxY, hud: hud)
            hudPanel.orderFrontRegardless()

            panelSets[key] = PanelSet(panel: panel, bar: bar, hud: hudPanel, model: model)

            // `.notice` persists to the log store even in Release (`.info` does
            // not — see FullscreenObserver.swift). The printed height
            // distinguishes the launched-app menu-bar value from the 22pt
            // status-bar fallback.
            logger.notice("panel set key=\(key, privacy: .public) mode=\(mode.isPhysical ? "physical" : "synthetic", privacy: .public) anchor=\(NSStringFromRect(anchorRect), privacy: .public) menuBar=\(screen.menuBarHeight, privacy: .public)")
        }
    }

    private static func makePanel(notchFrame: NSRect, screen: NSScreen, isPhysical: Bool, model: NotchViewModel, timer: TimerViewModel, calendar: CalendarProvider, nowPlaying: NowPlayingProvider) -> NotchPanel {
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
        panel.isPhysical = isPhysical
        panel.screenFrame = screen.frame

        let hostingView = NSHostingView(rootView: NotchContentView(model: model, notchSize: notchFrame.size, timer: timer, calendar: calendar, nowPlaying: nowPlaying, isPhysical: isPhysical))
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
        let expandedWidth = NotchLayout.expandedWidth
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
    /// How far the extended pill reaches into each ear beyond the cutout —
    /// ASYMMETRIC per the idle-wing mockup: the right ear is sized to the
    /// longest realistic readout ("600:22" ≈ 75pt), the left ear only carries
    /// the ~20pt artwork/sound-wave so it hugs tight. A symmetric 76pt
    /// left ear left ~40pt of dead black beside the artwork (UAT: "wings too
    /// wide").
    ///
    /// **260801-7h2-regressions round 4:** was 40 — left the artwork tile only 4pt of
    /// clearance from the notch cutout (`40 - (Tokens.Spacing.lg leading pad + 20pt artwork)`),
    /// which read as "scraping the border" once round 3's glow/staleness fixes made the pill
    /// render reliably. Bumped to 48 (+8pt): widens the wing itself, and — since the artwork's
    /// panel-local offset is unchanged while the panel's own global origin (`notchFrame.minX -
    /// leftEar`) shifts left with it — also moves the artwork's absolute screen position further
    /// left/away from the notch by the same 8pt, landing clearance at 12pt. Verified this cannot
    /// reintroduce GLOW-GEOMETRY: the glow's absolute edge position is `notchFrame.minX -
    /// glowLineOutset` / `notchFrame.maxX + glowLineOutset` — `leftEar` cancels out of that
    /// formula entirely (panel origin moves left by `leftEar` while the notch's local offset
    /// within the panel grows by the same `leftEar`), confirmed via a closed-form re-derivation
    /// of NotchShape.path(in:)'s corner arithmetic at both leftEar=40 and leftEar=48.
    private static let leftEar: CGFloat = 48
    private static let rightEar: CGFloat = 76

    /// Global-coordinate frame of the extended pill (also the wing hover
    /// region), shared by `makeBarPanel` and the wing mouse-monitor.
    private static func barFrame(notchFrame: NSRect, anchorMaxY: CGFloat) -> NSRect {
        NSRect(
            x: notchFrame.minX - leftEar,
            y: anchorMaxY - notchFrame.height,
            width: notchFrame.width + leftEar + rightEar,
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

    /// How far the bar panel (and its glow-outset content view) extends BELOW the notch cutout's
    /// bottom edge (T-7h2 Task 3). The physical notch is a camera cutout — pixels drawn inside it
    /// are never displayed — so a hairline stroked on or inside the cutout outline would be
    /// half-invisible or fully invisible; the glow needs a few points of real, rendered panel
    /// below the notch to actually show. `barFrame(notchFrame:anchorMaxY:)` itself is unchanged —
    /// `handleMouseMoved` computes the wing hover region from that function independently of the
    /// panel frame, so the hover geometry must not move — only `makeBarPanel`'s own window/content
    /// frame grows by this amount, downward only (top edge, flush with the physical notch top,
    /// stays fixed).
    private static let glowOutset: CGFloat = 3

    private static func makeBarPanel(notchFrame: NSRect, anchorMaxY: CGFloat, timer: TimerViewModel, model: NotchViewModel, nowPlaying: NowPlayingProvider, fullscreen: FullscreenObserver, calendar: CalendarProvider, mode: NotchGeometry.Mode, displayID: CGDirectDisplayID?) -> NSPanel {
        let frame: NSRect
        let notchLocalFrame: CGRect

        if mode.isPhysical {
            let bar = barFrame(notchFrame: notchFrame, anchorMaxY: anchorMaxY)
            frame = NSRect(
                x: bar.minX,
                y: bar.minY - glowOutset,
                width: bar.width,
                height: bar.height + glowOutset
            )
            // The notch's position within the (now taller) bar view, in SwiftUI's top-down
            // coordinate space: the pill content and the glow's un-outset top edge both anchor to
            // this rect's origin (y: 0 — the physical notch top, unchanged by the outward growth
            // below it).
            notchLocalFrame = CGRect(x: leftEar, y: 0, width: notchFrame.width, height: notchFrame.height)
        } else {
            // Phase 6 Plan 02 (SHELL-08/D-01): the bar window is sized to the WIDEST the drawn
            // pill can ever get (every readout shown at once) so it never has to resize as
            // content comes and goes — only the pill `NotchBarView.syntheticPill` draws inside it
            // changes width. No glow outset — there is no cutout to locate on a drawn pill.
            let scale = NotchGeometry.readoutScale(pillHeight: notchFrame.height)
            let width = SyntheticPillLayout.maxPillWidth(idleWidth: notchFrame.width, scale: scale)
            frame = NSRect(
                x: notchFrame.midX - width / 2,
                y: anchorMaxY - notchFrame.height,
                width: width,
                height: notchFrame.height
            )
            // Centers the anchor's own local frame within the (wider) window, so
            // `notchLocalFrame.midX` always equals the window's own horizontal center — exactly
            // where `NotchBarView.syntheticPill` centers its drawn, content-driven-width pill.
            notchLocalFrame = CGRect(x: (width - notchFrame.width) / 2, y: 0, width: notchFrame.width, height: notchFrame.height)
        }

        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel, .utilityWindow], backing: .buffered, defer: false)

        let container = NSView(frame: NSRect(origin: .zero, size: frame.size))
        container.autoresizesSubviews = true
        let hosting = NSHostingView(rootView: NotchBarView(timer: timer, model: model, nowPlaying: nowPlaying, fullscreen: fullscreen, notchLocalFrame: notchLocalFrame, calendar: calendar, mode: mode, displayID: displayID))
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
        let width = NotchLayout.expandedWidth
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
        let container = panel.contentView as? HoverTrackingView

        if isOpen {
            // The whole expanded window is the hover target again.
            container?.hoverRect = nil
            panel.setFrame(frame, display: true)
        } else {
            // D-11: shrink the tracking rect to the collapsed pill immediately —
            // before the window itself shrinks — so a cursor sweeping through
            // the dead zone below the still-oversized window never re-arms the
            // dwell, while moving onto the pill itself still gets a fresh
            // `mouseEntered` at any point during the 0.45s collapse animation.
            container?.hoverRect = NotchGeometry.collapsedHoverRect(
                containerSize: panel.frame.size,
                notchSize: panel.notchFrame.size
            )
            let work = DispatchWorkItem { [weak self, weak panel] in
                guard let self, let panel, panel.viewModel?.isOpen != true else {
                    return
                }
                let collapseFrame = self.resolvedFrame(for: panel)
                panel.setFrame(collapseFrame, display: true)
                // The collapsed window now IS the pill — `.inVisibleRect`
                // tracking is correct again, and cheaper.
                (panel.contentView as? HoverTrackingView)?.hoverRect = nil
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

    /// The CURRENT drawn pill's global-coordinate rect — the wing-hover region on a synthetic
    /// screen. Unlike the physical `barFrame` (a fixed rect for the asymmetric ear geometry), the
    /// synthetic pill's own width changes with its content, so this is recomputed from live state
    /// on every hover check using the exact same `SyntheticPillLayout` math
    /// `NotchBarView.syntheticPill` draws from — the hover region always equals the drawn pill
    /// (SHELL-08). Physical panels fall back to the unchanged `barFrame`.
    private func pillHoverFrame(for panel: NotchPanel) -> NSRect {
        guard !panel.isPhysical else {
            return Self.barFrame(notchFrame: panel.notchFrame, anchorMaxY: panel.anchorMaxY)
        }
        let earVisible = nowPlayingProvider.displayEar && !fullscreenObserver.isAmbientSuppressed(on: panel.displayID)
        let center = SyntheticPillLayout.centerText(timer: timer, calendar: calendarProvider, nowPlaying: nowPlayingProvider, earVisible: earVisible) != nil
        let scale = NotchGeometry.readoutScale(pillHeight: panel.notchFrame.height)
        let width = SyntheticPillLayout.pillWidth(
            idleWidth: panel.notchFrame.width,
            scale: scale,
            showsArtwork: earVisible,
            showsWave: earVisible,
            showsCenter: center,
            showsTimer: timer.isRunning
        )
        return NSRect(
            x: panel.notchFrame.midX - width / 2,
            y: panel.anchorMaxY - panel.notchFrame.height,
            width: width,
            height: panel.notchFrame.height
        )
    }

    /// Updates each panel's `wingHovering` from the current mouse position: the
    /// mouse is "over a wing" when the pill is visible — a timer is running OR
    /// the Now Playing ear has content (D-05 disjunction), for a physical panel;
    /// always, for a synthetic one (D-03) — and the cursor is inside the pill's
    /// current frame but outside the notch's own tracking region (which the
    /// `NSTrackingArea` already owns). Only fires the dwell logic on an actual
    /// change, so this is cheap on every move.
    private func handleMouseMoved() {
        let mouse = NSEvent.mouseLocation
        for panel in panels {
            let inBar: Bool
            if panel.isPhysical {
                // Mirrors NotchBarView's pill gate exactly (T-7h2 Task 2): the timer
                // disjunct sits OUTSIDE the fullscreen suppression, so the wing
                // hover region never disappears out from under a running timer.
                inBar = (timer.isRunning || (nowPlayingProvider.displayEar && !fullscreenObserver.isAmbientSuppressed(on: panel.displayID)))
                    && Self.barFrame(notchFrame: panel.notchFrame, anchorMaxY: panel.anchorMaxY).contains(mouse)
            } else {
                // D-03: the synthetic pill is always visible — no timer/ear gate, just "is the
                // cursor over whatever the pill currently draws."
                inBar = pillHoverFrame(for: panel).contains(mouse)
            }
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
/// (see `container` comment in `NotchPanelController.makePanel`). Two
/// regimes (D-11): when `hoverRect` is nil, `.zero` + `.inVisibleRect` keeps
/// the tracking rect pinned to the view's current bounds automatically as
/// `applyFrame` resizes the window between the collapsed notch size and the
/// expanded panel size — used while open/expanded and once fully collapsed.
/// When `hoverRect` is set (during the collapse animation, before the window
/// itself has shrunk), the tracking area is pinned to that explicit rect
/// instead, so the dead zone below the still-oversized window never re-arms
/// the hover dwell.
private final class HoverTrackingView: NSView {
    var onHoverChange: ((Bool) -> Void)?
    var hoverRect: NSRect? { didSet { updateTrackingAreas() } }

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
        if let hoverRect {
            // Explicit rect — no `.inVisibleRect`, which would override it and
            // track the full (still-oversized, mid-collapse) bounds instead.
            addTrackingArea(NSTrackingArea(
                rect: hoverRect,
                options: [.mouseEnteredAndExited, .activeAlways],
                owner: self,
                userInfo: nil
            ))
        } else {
            addTrackingArea(NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self,
                userInfo: nil
            ))
        }
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
    // Phase 6 SHELL-06/07: which `NotchGeometry.Mode` case this panel was
    // built from, and the owning screen's full frame — both set once in
    // `makePanel`, read by `NotchContentView`'s corner-radius branch and any
    // future per-display logic that needs the screen back.
    var isPhysical = true
    var screenFrame: NSRect = .zero
    /// Phase 6 Plan 03 (D-06/D-07): the `CGDirectDisplayID` this panel was built for, set once in
    /// `rebuildPanels()` from `screen.displayID`. Feeds `FullscreenObserver`'s per-display queries
    /// and `canBecomeKey`'s pointer-display gate below.
    var displayID: CGDirectDisplayID?
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
    //
    // Phase 6 Plan 03 (D-07): the hotkey opens every panel at once, but only ONE panel may ever
    // become key — the one whose `screenFrame` contains the pointer — so typed input (today: the
    // minutes field after a click; Phase 8: keyboard navigation) always lands on the display the
    // user is actually looking at, never on a panel the pointer isn't over. `toggle()` itself
    // calls nothing that requests key status, so this gate alone (combined with
    // `becomesKeyOnlyIfNeeded`) is what enforces the rule — no forced-key AppKit call exists
    // anywhere in this file.
    override var canBecomeKey: Bool { screenFrame.contains(NSEvent.mouseLocation) }
    override var canBecomeMain: Bool { false }

    // The notch overlay is a fixed, level-27 ambient window — it must never be
    // miniaturized or closed by the standard Window menu commands (⌘M / ⌘W),
    // which would otherwise reset its window level and position. Kept as a
    // defensive no-op even though the panel no longer becomes key.
    override func miniaturize(_ sender: Any?) { /* no-op: notch panel is not miniaturizable */ }
    override func performMiniaturize(_ sender: Any?) { /* no-op */ }
    override func performClose(_ sender: Any?) { /* no-op: not user-closable; Quit is via the panel's power button */ }
}
