import CoreGraphics

/// Ported (D-02) from `.planning/sketches/005-band-droplet/index.html:134-143`'s `Spring` class —
/// identical semi-implicit Euler integrator (`k = (2π/resp)²`, `c = 4π·damp/resp`, velocity
/// updated before position), identical field names. RED-phase stub: signatures final, bodies are
/// placeholders that intentionally fail the behavior tests.
public final class FluidSpring {
    public var x: CGFloat
    public var v: CGFloat = 0
    public var t: CGFloat
    public var resp: CGFloat = 0.4
    public var damp: CGFloat = 0.8

    public init(_ x: CGFloat) {
        self.x = x
        self.t = x
    }

    /// Ported from index.html:136 `to(t, c, s = 1)`.
    public func to(_ target: CGFloat, preset: FluidMotionPreset? = nil, scale: CGFloat = 1) {
        t = target
        if let preset {
            resp = preset.response * scale
            damp = preset.damping
        }
    }

    /// Ported from index.html:137 `jump(x)`.
    public func jump(_ x: CGFloat) {
        self.x = x
        self.t = x
        self.v = 0
    }

    /// Ported from index.html:138-142 `step(dt)` — semi-implicit Euler, velocity updated first,
    /// then position, identical order of operations.
    public func step(_ dt: CGFloat) {
        let k = pow(2 * CGFloat.pi / resp, 2)
        let c = 4 * CGFloat.pi * damp / resp
        v += (-k * (x - t) - c * v) * dt
        x += v * dt
    }

    public var isSettled: Bool {
        abs(x - t) < 0.001 && abs(v) < 0.001
    }
}

/// The five named spring pairs (07-DESIGN-AGREEMENT.md §10; the sketch calls `close` "retract").
public struct FluidMotionPreset: Equatable, Sendable {
    public let response: CGFloat
    public let damping: CGFloat

    public init(response: CGFloat, damping: CGFloat) {
        self.response = response
        self.damping = damping
    }

    public static let open = FluidMotionPreset(response: 0.55, damping: 0.78)
    public static let close = FluidMotionPreset(response: 0.50, damping: 0.92)
    public static let droplet = FluidMotionPreset(response: 0.60, damping: 0.80)
    public static let slide = FluidMotionPreset(response: 0.55, damping: 0.86)
    public static let sticky = FluidMotionPreset(response: 0.70, damping: 0.90)
}

/// Ported from index.html:210-211 `POUR`/`DRAIN` — per-key response multipliers for the
/// opening-pours / closing-drains stagger.
public enum FluidStagger {
    public static let pour: [FluidParamKey: CGFloat] = [.half: 0.8, .run: 0.9, .d: 1.35, .sd: 1.35]
    public static let drain: [FluidParamKey: CGFloat] = [.d: 0.8, .sd: 0.8, .half: 1.35, .run: 1.35]
}

/// Ported from index.html:208-212's timing constants.
public enum FluidTiming {
    public static let dwell: CGFloat = 0.25
    public static let intent: CGFloat = 0.14
    public static let lag: CGFloat = 0.12
    public static let contentDelay: CGFloat = 0.16
    public static let pull: CGFloat = 5
}
