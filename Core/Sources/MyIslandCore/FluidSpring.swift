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

    public func to(_ target: CGFloat, preset: FluidMotionPreset? = nil, scale: CGFloat = 1) {
        // stub
    }

    public func jump(_ x: CGFloat) {
        // stub
    }

    public func step(_ dt: CGFloat) {
        // stub
    }

    public var isSettled: Bool {
        false
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

    public static let open = FluidMotionPreset(response: 0, damping: 0)
    public static let close = FluidMotionPreset(response: 0, damping: 0)
    public static let droplet = FluidMotionPreset(response: 0, damping: 0)
    public static let slide = FluidMotionPreset(response: 0, damping: 0)
    public static let sticky = FluidMotionPreset(response: 0, damping: 0)
}

/// Ported from index.html:210-211 `POUR`/`DRAIN` — per-key response multipliers for the
/// opening-pours / closing-drains stagger.
public enum FluidStagger {
    public static let pour: [FluidParamKey: CGFloat] = [:]
    public static let drain: [FluidParamKey: CGFloat] = [:]
}

/// Ported from index.html:208-212's timing constants.
public enum FluidTiming {
    public static let dwell: CGFloat = 0
    public static let intent: CGFloat = 0
    public static let lag: CGFloat = 0
    public static let contentDelay: CGFloat = 0
    public static let pull: CGFloat = 0
}
