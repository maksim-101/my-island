import AppKit
import SwiftUI
import MyIslandCore

/// D-03 measurement harness. Production code never references this type — `AppDelegate` only
/// constructs it when the `MyIslandFluidSpike` launch default is set, and it replaces
/// `NotchPanelController` entirely for that launch (the harness runs alone so nothing else draws
/// over it). Draws the ported outline in a real, alpha-hit-tested, non-activating `NSPanel` on
/// every connected display and logs one `clickProbe` line per settled state.
@MainActor
final class FluidSpikeController: NSObject {
    static let enabledKey = "MyIslandFluidSpike"
    /// Task 1 only recognizes the auto pill→band sequence (no value needed). Task 2 adds `pill`,
    /// `band`, `dropEdge`, `dropMiddle`, `alert`, and the default `cycle`.
    static let holdKey = "MyIslandFluidSpikeHold"

    private enum SpikeState: String {
        case pill, band
    }

    private let logger = AppLog.make("FluidSpike")
    private var panels: [FluidSpikePanel] = []

    override init() {
        super.init()
        for screen in NSScreen.screens {
            let panel = Self.makePanel(screen: screen)
            panels.append(panel)
            panel.orderFrontRegardless()
            runProbeSequence(panel: panel, screen: screen)
        }
    }

    /// Sized to the largest scripted extent (the physical band, 5 modules) so alpha hit-testing
    /// is measured over the widest transparent area on every display, per the plan's Task 1
    /// action — width `1166 + 40`, height `d + sag + 188 + 18 + 7 + 40`.
    private static var maxPanelSize: CGSize {
        let physicalBand = FluidParams.band(moduleCount: 5, contentTop: FluidShapeGeometry.bandContentTopPhysical)
        let width = 2 * physicalBand.half + 40
        let height = physicalBand.d + physicalBand.sag + FluidShapeGeometry.dropletHeight + 18 + 7 + 40
        return CGSize(width: width, height: height)
    }

    private static func restParams(for screen: NSScreen, state: SpikeState) -> FluidParams {
        let mode = screen.notchMode
        switch state {
        case .pill:
            return mode.isPhysical
                ? .macBookPill
                : .desktopPill(width: mode.anchorRect.width, height: mode.anchorRect.height)
        case .band:
            let contentTop = mode.isPhysical ? FluidShapeGeometry.bandContentTopPhysical : FluidShapeGeometry.bandContentTopSynthetic
            return .band(moduleCount: 5, contentTop: contentTop)
        }
    }

    private static func makePanel(screen: NSScreen) -> FluidSpikePanel {
        let size = maxPanelSize
        let anchorRect = screen.notchMode.anchorRect
        let origin = CGPoint(x: anchorRect.midX - size.width / 2, y: screen.frame.maxY - size.height)
        let frame = NSRect(origin: origin, size: size)
        let styleMask: NSWindow.StyleMask = [.borderless, .nonactivatingPanel, .utilityWindow]
        let panel = FluidSpikePanel(contentRect: frame, styleMask: styleMask, backing: .buffered, defer: false)

        // Plain NSView container, never the window's own contentView as an NSHostingView — see
        // NotchPanelController.makePanel's comment on the resize-abort this avoids. Layer-backed
        // exactly like that panel's own HoverTrackingView container — alpha-based click-through
        // is a WindowServer compositing behavior, and a non-layer-backed container measured
        // insideHit=24/24 outsidePass=0/24 (every outside probe still hit) before this fix.
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        container.autoresizesSubviews = true
        container.wantsLayer = true
        container.layer?.masksToBounds = true

        let hosting = NSHostingView(rootView: AnyView(FluidSpikeContentView(params: restParams(for: screen, state: .pill))))
        hosting.sizingOptions = []
        hosting.translatesAutoresizingMaskIntoConstraints = true
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        panel.contentView = container
        panel.hostingView = hosting

        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        return panel
    }

    private func show(state: SpikeState, on panel: FluidSpikePanel, screen: NSScreen) {
        panel.hostingView?.rootView = AnyView(FluidSpikeContentView(params: Self.restParams(for: screen, state: state)))
    }

    /// One second after order-front: probe `pill`, switch to `band`, one second later probe
    /// `band` — the "first alpha click-through measurement for the pill and the band" Task 1's
    /// `<done>` requires. Task 2 replaces this with the full `holdKey`-driven cycle.
    private func runProbeSequence(panel: FluidSpikePanel, screen: NSScreen) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self, weak panel] in
            guard let self, let panel else { return }
            self.probe(state: .pill, panel: panel, screen: screen)
            self.show(state: .band, on: panel, screen: screen)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self, weak panel] in
                guard let self, let panel else { return }
                self.probe(state: .band, panel: panel, screen: screen)
            }
        }
    }

    /// `NSWindow.windowNumber(at:belowWindowWithWindowNumber:)` — does a click at point P outside
    /// the drawn path resolve to the window behind (D-04's measurement, per RESEARCH.md Standard
    /// Stack)? `insideHit` counts "inside" probes that correctly hit this panel; `outsidePass`
    /// counts "outside" probes that correctly resolve to something else (desktop/another app).
    private func probe(state: SpikeState, panel: FluidSpikePanel, screen: NSScreen) {
        let params = Self.restParams(for: screen, state: state)
        let cx = Self.maxPanelSize.width / 2
        let probes = FluidShapeGeometry.probePoints(cx: cx, q: params, count: 24, offset: 1)
        var insideHit = 0
        var outsidePass = 0
        for pair in probes {
            let insideGlobal = CGPoint(x: panel.frame.minX + pair.inside.x, y: panel.frame.maxY - pair.inside.y)
            let outsideGlobal = CGPoint(x: panel.frame.minX + pair.outside.x, y: panel.frame.maxY - pair.outside.y)
            let insideWindow = NSWindow.windowNumber(at: insideGlobal, belowWindowWithWindowNumber: 0)
            let outsideWindow = NSWindow.windowNumber(at: outsideGlobal, belowWindowWithWindowNumber: 0)
            if insideWindow == panel.windowNumber { insideHit += 1 }
            if outsideWindow != panel.windowNumber { outsidePass += 1 }
        }
        logger.notice("clickProbe state=\(state.rawValue, privacy: .public) display=\(screen.displayKey, privacy: .public) mode=alpha material=black insideHit=\(insideHit, privacy: .public)/\(probes.count, privacy: .public) outsidePass=\(outsidePass, privacy: .public)/\(probes.count, privacy: .public)")
    }
}

/// Never becomes key — the harness only measures, it never accepts keyboard input.
final class FluidSpikePanel: NSPanel {
    var hostingView: NSHostingView<AnyView>?

    override var canBecomeKey: Bool { false }
}

private struct FluidSpikeContentView: View {
    let params: FluidParams

    var body: some View {
        FluidOutlineShape(params: params)
            .fill(Color(red: 5.0 / 255, green: 5.0 / 255, blue: 6.0 / 255))
    }
}
