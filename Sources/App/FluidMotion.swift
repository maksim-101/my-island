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

    // Frame-timing ring buffer for `frameStats()` (D-03(a)/FEEL-05 measurement).
    private var intervalsMs: [Double] = []
    private let maxSamples = 3600

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
    }

    // MARK: - Public API (ported from index.html:308-372 `goTo`/`setHot`/etc, generalized)

    /// Ported from index.html:308-315 `goTo` — skips dip/m/s2/mx (the droplet-only keys), applies
    /// `lag` to `run`/`sd` only.
    func goTo(_ target: FluidParams, preset: FluidMotionPreset, lag: CGFloat = 0, stagger: [FluidParamKey: CGFloat] = [:]) {
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
        springs[key]?.to(value, preset: preset, scale: scale)
        resume()
    }

    func jump(to target: FluidParams) {
        for key in FluidParamKey.allCases {
            springs[key]?.jump(target[key])
        }
        syncParams()
    }

    func setChannel(_ channel: FluidChannel, to value: CGFloat, response: CGFloat, damping: CGFloat) {
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

    // MARK: - Clock

    func startClock(on screen: NSScreen) {
        guard displayLink == nil else { return }
        let link = screen.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func stopClock() {
        displayLink?.invalidate()
        displayLink = nil
        lastTimestamp = nil
    }

    private func resume() {
        guard displayLink == nil, let screen = NSScreen.main else { return }
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
        recordInterval(frameDuration: link.duration, elapsed: now - last)

        if allSettled {
            stopClock()
        }
    }

    private func syncParams() {
        var next = params
        for key in FluidParamKey.allCases {
            next[key] = springs[key]?.x ?? next[key]
        }
        // Ported from index.html:502-503 `q()`'s asym derivation.
        let mxVelocity = velocity(of: .mx)
        next.asym = max(-0.45, min(0.45, mxVelocity / 1400))
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

    // MARK: - Frame stats (D-03(a)/FEEL-05)

    private func recordInterval(frameDuration: CFTimeInterval, elapsed: CFTimeInterval) {
        intervalsMs.append(elapsed * 1000)
        if intervalsMs.count > maxSamples { intervalsMs.removeFirst() }
        lastFrameDurationMs = frameDuration * 1000
    }

    private var lastFrameDurationMs: Double = 1000.0 / 60.0

    /// A dropped frame is an interval above 1.5× the link's own frame duration.
    func frameStats() -> (p50Ms: Double, p99Ms: Double, maxMs: Double, dropped: Int, total: Int) {
        guard !intervalsMs.isEmpty else { return (0, 0, 0, 0, 0) }
        let sorted = intervalsMs.sorted()
        let p50 = sorted[sorted.count / 2]
        let p99 = sorted[Int(Double(sorted.count - 1) * 0.99)]
        let maxMs = sorted.last ?? 0
        let dropped = intervalsMs.filter { $0 > lastFrameDurationMs * 1.5 }.count
        return (p50, p99, maxMs, dropped, intervalsMs.count)
    }

    func resetFrameStats() {
        intervalsMs.removeAll()
    }
}
