import AppKit
import SwiftUI
import OSLog
import MyIslandCore

/// D-03 measurement harness. Production code never references this type — `AppDelegate` only
/// constructs it when the `MyIslandFluidSpike` launch default is set, and it replaces
/// `NotchPanelController` entirely for that launch (the harness runs alone so nothing else draws
/// over it). Draws the ported outline in a real, alpha-hit-tested, non-activating `NSPanel` on
/// every connected display and logs one `clickProbe` line per settled state.
///
/// Task 2 note (deviation, documented in 07-01-SUMMARY.md): the droplet/alert states below use
/// `FluidMotion.jump(to:)` to land on each state's REST geometry rather than fully reproducing
/// the sketch's live `setHot`/`startExtra` spring choreography (asym continuity, pinch-off
/// hysteresis, the neck's transient bridging shape). The pill↔band↔close transitions DO run
/// through real `FluidMotion.goTo` springs with the design agreement's presets/stagger — what
/// this simplifies is droplet/alert ENTRY animation, not the SETTLED shape D-04's click-through
/// measurement actually tests.
@MainActor
final class FluidSpikeController: NSObject {
    static let enabledKey = "MyIslandFluidSpike"
    static let holdKey = "MyIslandFluidSpikeHold"
    static let clickModeKey = "MyIslandFluidSpikeClickMode"
    static let materialKey = "MyIslandFluidSpikeMaterial"

    enum SpikeState: String, CaseIterable {
        case pill, band, dropEdge, dropMiddle, alert
    }

    enum Hold: String {
        case cycle, pill, band, dropEdge, dropMiddle, alert
    }

    enum ClickMode: String {
        case alpha, toggle
    }

    enum Material: String {
        case black, glass, glassContainer
    }

    private let logger = AppLog.make("FluidSpike")
    private var displays: [DisplayContext] = []

    private let hold: Hold
    private let clickMode: ClickMode
    private let material: Material

    override init() {
        let d = UserDefaults.standard
        hold = Hold(rawValue: d.string(forKey: Self.holdKey) ?? "cycle") ?? .cycle
        clickMode = ClickMode(rawValue: d.string(forKey: Self.clickModeKey) ?? "alpha") ?? .alpha
        material = Material(rawValue: d.string(forKey: Self.materialKey) ?? "black") ?? .black
        super.init()

        for screen in NSScreen.screens {
            let context = DisplayContext(
                screen: screen,
                material: material,
                clickMode: clickMode,
                logger: logger,
                maxPanelSize: Self.maxPanelSize
            )
            displays.append(context)
            context.panel.orderFrontRegardless()
            context.motion.startClock(on: screen)
            if clickMode == .toggle {
                context.installToggleMonitors()
            }
            context.onMouseDown = { [weak self, weak context] event in
                guard let self, let context else { return }
                self.logSpikeClick(event: event, context: context)
            }
            runSequence(context: context)
        }
    }

    private static var maxPanelSize: CGSize {
        let physicalBand = FluidParams.band(moduleCount: 5, contentTop: FluidShapeGeometry.bandContentTopPhysical)
        let width = 2 * physicalBand.half + 40
        let height = physicalBand.d + physicalBand.sag + FluidShapeGeometry.dropletHeight + 18 + 7 + 40
        return CGSize(width: width, height: height)
    }

    private static func restParams(for screen: NSScreen, state: SpikeState) -> FluidParams {
        let mode = screen.notchMode
        let contentTop = mode.isPhysical ? FluidShapeGeometry.bandContentTopPhysical : FluidShapeGeometry.bandContentTopSynthetic
        switch state {
        case .pill:
            return mode.isPhysical
                ? .macBookPill(menuBarHeight: screen.menuBarHeight, notchHeight: mode.anchorRect.height)
                : .desktopPill(width: mode.anchorRect.width, height: mode.anchorRect.height)
        case .band:
            return .band(moduleCount: 5, contentTop: contentTop)
        case .dropEdge:
            var q = FluidParams.band(moduleCount: 5, contentTop: contentTop)
            let f = FluidShapeGeometry.frameOf(q, cx: 0)
            q.dip = FluidShapeGeometry.dropletHeight
            q.m = 125
            q.s2 = FluidShapeGeometry.dropletFlank
            q.mx = f.x0 + q.m - 1
            return q
        case .dropMiddle:
            var q = FluidParams.band(moduleCount: 5, contentTop: contentTop)
            q.dip = FluidShapeGeometry.dropletHeight
            q.m = 125
            q.s2 = FluidShapeGeometry.dropletFlank
            q.mx = 0
            return q
        case .alert:
            return mode.isPhysical
                ? .macBookPill(menuBarHeight: screen.menuBarHeight, notchHeight: mode.anchorRect.height)
                : .desktopPill(width: mode.anchorRect.width, height: mode.anchorRect.height)
        }
    }

    /// Alert/HUD drop geometry (pebble only — the settled, detached rest state D-04 measures;
    /// the transient neck bridge is not separately click-tested, see the type doc comment).
    private static func alertPebble(for screen: NSScreen) -> (w: CGFloat, y: CGFloat, h: CGFloat) {
        let isPhysical = screen.notchMode.isPhysical
        let base = restParams(for: screen, state: .alert)
        let floor = base.d + base.sag
        return (w: isPhysical ? 80 : 70, y: floor + 8, h: 22)
    }

    private func runSequence(context: DisplayContext) {
        switch hold {
        case .cycle:
            runCycle(context: context, index: 0)
        case .pill, .band, .dropEdge, .dropMiddle, .alert:
            let state = SpikeState(rawValue: hold.rawValue) ?? .pill
            enter(state: state, context: context)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self, weak context] in
                guard let self, let context else { return }
                self.probeAndLog(context: context)
            }
        }
    }

    /// Ported cycle order (index.html cycle comment, D-06): pill → band (open, pour) → droplet
    /// edge → droplet middle → droplet edge → close (drain) → alert → end → pill.
    private func runCycle(context: DisplayContext, index: Int) {
        let sequence: [SpikeState] = [.pill, .band, .dropEdge, .dropMiddle, .dropEdge, .band, .alert, .pill]
        let step = sequence[index % sequence.count]
        enter(state: step, context: context)
        let probeableStates: Set<SpikeState> = [.pill, .band, .dropEdge, .dropMiddle, .alert]
        let delay = 2.5
        if probeableStates.contains(step), !context.probedStates.contains(step) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay * 0.6) { [weak self, weak context] in
                guard let self, let context else { return }
                self.probeAndLog(context: context)
                context.probedStates.insert(step)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak context] in
            guard let self, let context else { return }
            self.runCycle(context: context, index: index + 1)
        }
    }

    private func enter(state: SpikeState, context: DisplayContext) {
        context.currentState = state
        let target = Self.restParams(for: context.screen, state: state)
        switch state {
        case .pill:
            context.motion.goTo(target, preset: .close, lag: FluidTiming.lag, stagger: FluidStagger.drain)
            context.motion.setChannel(.glow, to: 0.2, response: MOTPreset.sticky.response, damping: MOTPreset.sticky.damping)
            context.showAlert = false
        case .band:
            context.motion.goTo(target, preset: .open, lag: 0, stagger: FluidStagger.pour)
            context.motion.setChannel(.glow, to: 0.28, response: MOTPreset.open.response, damping: MOTPreset.open.damping)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { [weak context] in
                context?.motion.setChannel(.bandAlpha, to: 1, response: 0.45, damping: 1)
            }
            context.showAlert = false
        case .dropEdge, .dropMiddle:
            context.motion.jump(to: target)
            context.showAlert = false
        case .alert:
            context.motion.jump(to: target)
            context.showAlert = true
        }
        context.refreshContent()
    }

    private func probeAndLog(context: DisplayContext) {
        let params = context.motion.params
        let cx = Self.maxPanelSize.width / 2

        if clickMode == .alpha {
            let probes = FluidShapeGeometry.probePoints(cx: cx, q: params, count: 24, offset: 1)
            var insideHit = 0
            var outsidePass = 0
            for pair in probes {
                let insideGlobal = CGPoint(x: context.panel.frame.minX + pair.inside.x, y: context.panel.frame.maxY - pair.inside.y)
                let outsideGlobal = CGPoint(x: context.panel.frame.minX + pair.outside.x, y: context.panel.frame.maxY - pair.outside.y)
                let insideWindow = NSWindow.windowNumber(at: insideGlobal, belowWindowWithWindowNumber: 0)
                let outsideWindow = NSWindow.windowNumber(at: outsideGlobal, belowWindowWithWindowNumber: 0)
                if insideWindow == context.panel.windowNumber { insideHit += 1 }
                if outsideWindow != context.panel.windowNumber { outsidePass += 1 }
            }
            logger.notice("clickProbe state=\(context.currentState.rawValue, privacy: .public) display=\(context.screen.displayKey, privacy: .public) mode=alpha material=\(self.material.rawValue, privacy: .public) insideHit=\(insideHit, privacy: .public)/\(probes.count, privacy: .public) outsidePass=\(outsidePass, privacy: .public)/\(probes.count, privacy: .public)")
        } else {
            logger.notice("clickProbe state=\(context.currentState.rawValue, privacy: .public) display=\(context.screen.displayKey, privacy: .public) mode=toggle material=\(self.material.rawValue, privacy: .public) skipped=window-state-depends-on-pointer")
        }

        let stats = context.motion.frameStats()
        logger.notice("frameStats state=\(context.currentState.rawValue, privacy: .public) material=\(self.material.rawValue, privacy: .public) p50Ms=\(stats.p50Ms, privacy: .public) p99Ms=\(stats.p99Ms, privacy: .public) maxMs=\(stats.maxMs, privacy: .public) dropped=\(stats.dropped, privacy: .public) of=\(stats.total, privacy: .public)")
        context.motion.resetFrameStats()
    }

    private func logSpikeClick(event: NSEvent, context: DisplayContext) {
        let globalPoint = NSEvent.mouseLocation
        let localX = globalPoint.x - context.panel.frame.minX
        let localY = context.panel.frame.maxY - globalPoint.y
        let cx = Self.maxPanelSize.width / 2
        let inside = FluidShapeGeometry.contains(CGPoint(x: localX, y: localY), cx: cx, q: context.motion.params)
        logger.notice("spikeClick inside=\(inside, privacy: .public) state=\(context.currentState.rawValue, privacy: .public) x=\(localX, privacy: .public) y=\(localY, privacy: .public)")
    }

    /// Local aliases so `enter(state:)` doesn't repeat `FluidMotionPreset.open.response` chains.
    private enum MOTPreset {
        static let open = FluidMotionPreset.open
        static let sticky = FluidMotionPreset.sticky
    }
}

/// Per-display state: panel, motion clock, current logical state, and (toggle mode) the
/// mouse-moved monitors that drive `ignoresMouseEvents`.
@MainActor
private final class DisplayContext {
    let screen: NSScreen
    let panel: FluidSpikePanel
    let motion: FluidMotion
    let material: FluidSpikeController.Material
    let clickMode: FluidSpikeController.ClickMode
    let logger: Logger
    let maxPanelSize: CGSize
    var currentState: FluidSpikeController.SpikeState = .pill
    var showAlert = false
    var probedStates: Set<FluidSpikeController.SpikeState> = []
    var onMouseDown: ((NSEvent) -> Void)? {
        didSet { panel.onMouseDown = onMouseDown }
    }

    nonisolated(unsafe) private var localMonitor: Any?
    nonisolated(unsafe) private var globalMonitor: Any?

    init(screen: NSScreen, material: FluidSpikeController.Material, clickMode: FluidSpikeController.ClickMode, logger: Logger, maxPanelSize: CGSize) {
        self.screen = screen
        self.material = material
        self.clickMode = clickMode
        self.logger = logger
        self.maxPanelSize = maxPanelSize

        let mode = screen.notchMode
        let contentTop = mode.isPhysical ? FluidShapeGeometry.bandContentTopPhysical : FluidShapeGeometry.bandContentTopSynthetic
        _ = contentTop
        let restPill: FluidParams = mode.isPhysical ? .macBookPill(menuBarHeight: screen.menuBarHeight, notchHeight: mode.anchorRect.height) : .desktopPill(width: mode.anchorRect.width, height: mode.anchorRect.height)
        motion = FluidMotion(rest: restPill)

        let anchorRect = mode.anchorRect
        let origin = CGPoint(x: anchorRect.midX - maxPanelSize.width / 2, y: screen.frame.maxY - maxPanelSize.height)
        let frame = NSRect(origin: origin, size: maxPanelSize)
        let styleMask: NSWindow.StyleMask = [.borderless, .nonactivatingPanel, .utilityWindow]
        let p = FluidSpikePanel(contentRect: frame, styleMask: styleMask, backing: .buffered, defer: false)

        let container = NSView(frame: NSRect(origin: .zero, size: maxPanelSize))
        container.autoresizesSubviews = true
        container.wantsLayer = true
        container.layer?.masksToBounds = true

        let hosting = NSHostingView(rootView: AnyView(EmptyView()))
        hosting.sizingOptions = []
        hosting.translatesAutoresizingMaskIntoConstraints = true
        hosting.frame = NSRect(origin: .zero, size: maxPanelSize)
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        p.contentView = container
        p.hostingView = hosting

        p.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = false
        p.isReleasedWhenClosed = false
        p.becomesKeyOnlyIfNeeded = true
        panel = p

        refreshContent()
    }

    func refreshContent() {
        let alertPebble = showAlert ? FluidSpikeController.alertGeometry(for: screen) : nil
        panel.hostingView?.rootView = AnyView(
            FluidSpikeContentView(params: motion.params, material: material, glowOpacity: motion.channels[.glow] ?? 0.2, alertPebble: alertPebble)
        )
    }

    func installToggleMonitors() {
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            self?.handleToggleMouseMoved(event: event)
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            self?.handleToggleMouseMoved(event: event)
        }
    }

    private func handleToggleMouseMoved(event: NSEvent) {
        let globalPoint = NSEvent.mouseLocation
        let localX = globalPoint.x - panel.frame.minX
        let localY = panel.frame.maxY - globalPoint.y
        let cx = maxPanelSize.width / 2
        var inside = FluidShapeGeometry.contains(CGPoint(x: localX, y: localY), cx: cx, q: motion.params)
        if !inside, showAlert {
            let pebble = FluidSpikeController.alertGeometry(for: screen)
            let path = FluidShapeGeometry.pebble(w: pebble.w, y: pebble.y, h: pebble.h, ox: cx)
            inside = path.contains(CGPoint(x: localX, y: localY), using: .winding, transform: .identity)
        }
        panel.ignoresMouseEvents = !inside
        let lagMs = (ProcessInfo.processInfo.systemUptime - event.timestamp) * 1000
        logger.notice("toggle inside=\(inside, privacy: .public) lagMs=\(lagMs, privacy: .public)")
    }

    deinit {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
    }
}

extension FluidSpikeController {
    /// Shared with `DisplayContext.handleToggleMouseMoved` — the alert pebble's rest geometry.
    fileprivate static func alertGeometry(for screen: NSScreen) -> (w: CGFloat, y: CGFloat, h: CGFloat) {
        alertPebble(for: screen)
    }
}

/// Never becomes key — the harness only measures, it never accepts keyboard input.
final class FluidSpikePanel: NSPanel {
    var hostingView: NSHostingView<AnyView>?
    var onMouseDown: ((NSEvent) -> Void)?

    override var canBecomeKey: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown {
            onMouseDown?(event)
        }
        super.sendEvent(event)
    }
}

private struct FluidSpikeContentView: View {
    let params: FluidParams
    let material: FluidSpikeController.Material
    let glowOpacity: Double
    let alertPebble: (w: CGFloat, y: CGFloat, h: CGFloat)?

    private let rim = Color(red: 124.0 / 255, green: 107.0 / 255, blue: 255.0 / 255)
    private let fillColor = Color(red: 5.0 / 255, green: 5.0 / 255, blue: 6.0 / 255)

    var body: some View {
        ZStack {
            silhouette(FluidOutlineShape(params: params))
            if let alertPebble {
                silhouette(PebbleShape(w: alertPebble.w, y: alertPebble.y, h: alertPebble.h))
            }
        }
    }

    @ViewBuilder
    private func silhouette<S: Shape>(_ shape: S) -> some View {
        switch material {
        case .black:
            shape
                .fill(fillColor)
                .overlay { shape.stroke(rim.opacity(0.32), lineWidth: 0.9) }
                .overlay { shape.fill(rim.opacity(glowOpacity)).blur(radius: 5) }
        case .glass:
            Color.clear
                .glassEffect(.regular.tint(Color.black.opacity(0.12)), in: shape)
                .overlay { shape.stroke(rim.opacity(0.32), lineWidth: 0.9) }
        case .glassContainer:
            GlassEffectContainer {
                Color.clear
                    .glassEffect(.regular.tint(Color.black.opacity(0.12)), in: shape)
                    .overlay { shape.stroke(rim.opacity(0.32), lineWidth: 0.9) }
            }
        }
    }
}

/// Local `Shape` wrapper around `FluidShapeGeometry.pebble` — the settled alert/HUD drop.
private struct PebbleShape: Shape {
    let w: CGFloat
    let y: CGFloat
    let h: CGFloat

    func path(in rect: CGRect) -> Path {
        Path(FluidShapeGeometry.pebble(w: w, y: y, h: h, ox: rect.midX))
    }
}
