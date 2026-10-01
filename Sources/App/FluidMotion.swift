import AppKit
import QuartzCore
import SwiftUI
import MyIslandCore

/// Named channels ported from the sketch's `glow, bandA, dropA, xdy, xh, xw, tprog` (index.html:305).
enum FluidChannel: String, CaseIterable {
    case glow, bandAlpha, dropAlpha, dropOffset, dropHeight, dropHalfWidth, timerProgress
}

/// One `FluidSpring` per `FluidParamKey` plus the named channels above, stepped from a single
/// `CADisplayLink` tick with `ceil(dt*240)` substeps (index.html:501-538 `frame`). Publishes
/// `params`/`channels` after every tick on one clock — no `withAnimation`, SwiftUI never
/// interpolates this state itself (RESEARCH.md Pitfall 2).
@MainActor
@Observable
final class FluidMotion: NSObject {
    private(set) var params: FluidParams
    private(set) var channels: [FluidChannel: CGFloat] = [:]

    /// 07-13 (FEEL-07 §10, DESIGN.md "Motion & feedback"): read at init and kept live via the
    /// matching NSWorkspace accessibility-display-options change notification (registered in
    /// `init` below) — while `true`, `goTo`/`set`/`setChannel` jump straight to their targets
    /// instead of springing (each call site below), so switching System Settings' Reduce Motion on
    /// or off takes effect without a relaunch. Views read this to cross-fade content instead of
    /// following the (now step-function) spring channels (`NotchContentView`/`FluidOverlayView`).
    private(set) var reduceMotion: Bool = FluidMotion.currentReduceMotion()
    nonisolated(unsafe) private var reduceMotionObserver: NSObjectProtocol?

    /// The 0.2s cross-fade every Reduce Motion view transition uses (agreement §10) — one source so
    /// `NotchContentView`/`FluidOverlayView` can never disagree about the duration.
    static let reduceMotionCrossFadeDuration: TimeInterval = 0.2

    private static func currentReduceMotion() -> Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// 07-05: the HUD/alert drop's attachment hysteresis (detached at `.dropOffset` >= 7,
    /// reattached below -2), ported from the sketch's `st.detached` (index.html:550). Kept HERE —
    /// not on the transient `AlertDropView` struct — so it survives that view being torn down and
    /// recreated on every SwiftUI re-render. `g` (the drop's fall past its own floor, `yT - baseY`
    /// in the sketch) is exactly the `.dropOffset` channel's own value once `baseY` cancels out, so
    /// no geometry lookup is needed to update this.
    private(set) var dropDetached: Bool = false

    private var springs: [FluidParamKey: FluidSpring] = [:]
    private var channelSprings: [FluidChannel: FluidSpring] = [:]

    private var displayLink: CADisplayLink?
    private var lastTimestamp: CFTimeInterval?
    /// 2026-09-27 (regression found live): the stable CoreGraphics identifier of the screen this
    /// clock belongs to — deliberately NOT a cached `NSScreen` reference (weak or strong).
    /// `NSScreen` instances are documented to be unstable across ANY display/Space reconfiguration
    /// (Apple's own guidance: re-fetch from `NSScreen.screens` after
    /// `NSApplication.didChangeScreenParametersNotification` rather than holding one). A `weak`
    /// reference here (the original WR-01 fix) went nil across exactly that class of event —
    /// switching fullscreen apps/Spaces, even on another display — and `resume()`'s fallback to
    /// `NSScreen.main` could then either resolve the wrong display or, in the narrow window before
    /// it did, leave `displayLink` nil: every channel/spring set via `setChannel`/`set`/`goTo` in
    /// that window had its TARGET updated but never STEPPED (`tick()` never ran), freezing
    /// `channels[.timerProgress]` at a stale, usually-low value — exactly "the timer border isn't
    /// fully shown, especially near the ends" the user reported, and "more prominent after
    /// open/close" (the burst of other `goTo`/`set` calls that follow eventually got a working
    /// `resume()` and caught every frozen spring up at once).
    private var ownerDisplayID: CGDirectDisplayID?

    /// 07-08 (D-06 Wave 2): one-shot "the springs settled" notification, replacing the fixed
    /// `NotchLayout.collapseWindowDelay` timer for the band's close-then-shrink window sequencing.
    /// A pointer lingering near the collapsed pill after close keeps `belly`/`lean`/`glow`
    /// retargeting (never `allSettled`) — the 1.5s backstop below is what guarantees this always
    /// fires, not just the ideal "sprang actually stopped" path.
    private var settledCallback: (() -> Void)?
    private var settledBackstop: DispatchWorkItem?

    init(rest: FluidParams) {
        params = rest
        super.init()
        for key in FluidParamKey.allCases {
            springs[key] = FluidSpring(rest[key])
        }
        for channel in FluidChannel.allCases {
            channelSprings[channel] = FluidSpring(0)
            channels[channel] = 0
        }
        reduceMotionObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.reduceMotion = FluidMotion.currentReduceMotion()
            }
        }
    }

    deinit {
        if let reduceMotionObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(reduceMotionObserver)
        }
    }

    // MARK: - Public API (ported from index.html:308-372 `goTo`/`setHot`/etc, generalized)

    /// Ported from index.html:308-315 `goTo` — skips dip/m/s2/mx (the droplet-only keys), applies
    /// `lag` to `run`/`sd` only.
    func goTo(_ target: FluidParams, preset: FluidMotionPreset, lag: CGFloat = 0, stagger: [FluidParamKey: CGFloat] = [:]) {
        // 07-13 (FEEL-07 §10): Reduce Motion jumps every key straight to its target, per-key
        // (never the droplet-only keys `goTo` always skips) — the SAME loop shape as the normal
        // spring path below, just `jump` instead of `to`, and no lag/stagger (nothing to stagger
        // once nothing springs).
        if reduceMotion {
            for key in FluidParamKey.allCases {
                if key == .dip || key == .m || key == .s2 || key == .mx { continue }
                springs[key]?.jump(target[key])
            }
            syncParams()
            return
        }
        for key in FluidParamKey.allCases {
            if key == .dip || key == .m || key == .s2 || key == .mx { continue }
            let scale = stagger[key] ?? 1
            if lag > 0, key == .run || key == .sd {
                let capturedKey = key
                let capturedScale = scale
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(lag)) { [weak self] in
                    self?.springs[capturedKey]?.to(target[capturedKey], preset: preset, scale: capturedScale)
                }
            } else {
                springs[key]?.to(target[key], preset: preset, scale: scale)
            }
        }
        resume()
    }

    func set(_ key: FluidParamKey, to value: CGFloat, preset: FluidMotionPreset, scale: CGFloat = 1) {
        if reduceMotion {
            springs[key]?.jump(value)
            syncParams()
            return
        }
        springs[key]?.to(value, preset: preset, scale: scale)
        resume()
    }

    func jump(to target: FluidParams) {
        for key in FluidParamKey.allCases {
            springs[key]?.jump(target[key])
        }
        syncParams()
    }

    /// 07-08 Task 2 (deviation, Rule 3 — blocking): a single-key `jump`, ported from the sketch's
    /// own per-spring `P.mx.jump(mx)` (index.html:364) — `showDroplet`'s first-droplet branch snaps
    /// `mx` straight to its target while `m` jumps to only 60% of target and animates the rest, so
    /// the first droplet visibly drips/grows in place rather than sliding in from elsewhere. The
    /// existing `jump(to:)` only jumps every key at once (to a full `FluidParams`), which would also
    /// reset the band's own open half/run/d/sd/sag — not what a droplet show should ever do.
    func jumpParam(_ key: FluidParamKey, to value: CGFloat) {
        springs[key]?.jump(value)
        syncParams()
    }

    func setChannel(_ channel: FluidChannel, to value: CGFloat, response: CGFloat, damping: CGFloat) {
        if reduceMotion {
            jumpChannel(channel, to: value)
            return
        }
        channelSprings[channel]?.to(value, preset: FluidMotionPreset(response: response, damping: damping))
        resume()
    }

    func jumpChannel(_ channel: FluidChannel, to value: CGFloat) {
        channelSprings[channel]?.jump(value)
        channels[channel] = value
        if channel == .dropOffset { updateDropAttachment(g: value) }
    }

    func velocity(of key: FluidParamKey) -> CGFloat {
        springs[key]?.v ?? 0
    }

    /// One-shot: fires `callback` once every spring/channel has settled, or after a 1.5s backstop —
    /// whichever comes first — then clears itself. Cancelled by `cancelWhenSettled()`, which every
    /// caller that supersedes a pending close (a reopen, a fresh probe step) must call first so a
    /// stale registration never fires against the wrong state. Only one registration is live at a
    /// time — a second call replaces, not queues, the first.
    func whenSettled(_ callback: @escaping () -> Void) {
        cancelWhenSettled()
        if allSettled {
            callback()
            return
        }
        settledCallback = callback
        let backstop = DispatchWorkItem { [weak self] in
            guard let self, let pending = self.settledCallback else { return }
            self.settledCallback = nil
            self.settledBackstop = nil
            pending()
        }
        settledBackstop = backstop
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: backstop)
    }

    /// Cancels any pending `whenSettled` registration without firing it.
    func cancelWhenSettled() {
        settledCallback = nil
        settledBackstop?.cancel()
        settledBackstop = nil
    }

    /// 07-13 (FEEL-04): a one-shot callback fired on the very next `CADisplayLink` tick after it is
    /// registered — `NotchPanelController`'s latency signposts (`hotkeyToFrame`/`dwellToFrame`/
    /// `actionToFrame`) end their interval from here, since "first frame" is exactly what this
    /// clock's own tick already means. Calls `resume()` so a callback still fires even when nothing
    /// else is currently animating (e.g. every value already settled, or Reduce Motion just jumped
    /// straight to rest).
    func onNextFrame(_ callback: @escaping () -> Void) {
        nextFrameCallbacks.append(callback)
        resume()
    }

    private var nextFrameCallbacks: [() -> Void] = []

    // MARK: - Clock

    func startClock(on screen: NSScreen) {
        guard displayLink == nil else { return }
        ownerDisplayID = screen.displayID
        let link = screen.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func stopClock() {
        displayLink?.invalidate()
        displayLink = nil
        lastTimestamp = nil
    }

    /// Re-resolves a live `NSScreen` from `NSScreen.screens` by the stored stable `displayID`
    /// every time, rather than trusting any cached `NSScreen` reference — see `ownerDisplayID`'s
    /// own doc comment for why. Falls back to `NSScreen.main` only when the owning display is
    /// genuinely gone (disconnected), matching the pre-WR-01 behaviour for that case.
    private func resume() {
        guard displayLink == nil else { return }
        let ownerScreen = ownerDisplayID.flatMap { id in NSScreen.screens.first { $0.displayID == id } }
        guard let screen = ownerScreen ?? NSScreen.main else { return }
        startClock(on: screen)
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.targetTimestamp
        let last = lastTimestamp ?? now
        let dt = min(now - last, 1.0 / 30.0)
        lastTimestamp = now

        let n = max(1, Int((dt * 240).rounded(.up)))
        let subDt = CGFloat(dt) / CGFloat(n)
        for _ in 0..<n {
            for key in FluidParamKey.allCases { springs[key]?.step(subDt) }
            for channel in FluidChannel.allCases { channelSprings[channel]?.step(subDt) }
        }
        syncParams()

        if !nextFrameCallbacks.isEmpty {
            let callbacks = nextFrameCallbacks
            nextFrameCallbacks.removeAll()
            for callback in callbacks { callback() }
        }

        if allSettled {
            stopClock()
            if let pending = settledCallback {
                settledCallback = nil
                settledBackstop?.cancel()
                settledBackstop = nil
                pending()
            }
        }
    }

    private func syncParams() {
        var next = params
        for key in FluidParamKey.allCases {
            next[key] = springs[key]?.x ?? next[key]
        }
        // Ported from index.html:502-503 `q()`'s asym derivation.
        let mxVelocity = velocity(of: .mx)
        next.asym = FluidShapeGeometry.wallSafeAsym(max(-0.45, min(0.45, mxVelocity / 1400)), q: next)
        params = next

        var nextChannels: [FluidChannel: CGFloat] = [:]
        for channel in FluidChannel.allCases {
            nextChannels[channel] = channelSprings[channel]?.x ?? 0
        }
        channels = nextChannels
        if let g = nextChannels[.dropOffset] { updateDropAttachment(g: g) }
    }

    private func updateDropAttachment(g: CGFloat) {
        if g >= 7 { dropDetached = true } else if g < -2 { dropDetached = false }
    }

    private var allSettled: Bool {
        springs.values.allSatisfy(\.isSettled) && channelSprings.values.allSatisfy(\.isSettled)
    }
}
