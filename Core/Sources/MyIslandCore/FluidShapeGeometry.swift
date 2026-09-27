import CoreGraphics

/// D-02: the fluid outline parameter vector — every notch surface on every display (pill,
/// desktop pill, fullscreen bulge, band, detail droplet, alert/HUD drop) is one value of this
/// type. Fields and their idle values (`Z` in the sketch) are ported verbatim from
/// `.planning/sketches/006-design-round/index.html:226-227`. This is a RED-phase stub: fields
/// and signatures are final, bodies are placeholders that intentionally fail the behavior tests.
public struct FluidParams: Equatable, Sendable {
    public var half: CGFloat
    public var run: CGFloat
    public var d: CGFloat
    public var sd: CGFloat
    public var r: CGFloat
    public var sag: CGFloat
    public var tp: CGFloat
    public var dip: CGFloat
    public var m: CGFloat
    public var s2: CGFloat
    public var mx: CGFloat
    public var sym: CGFloat
    public var belly: CGFloat
    public var lean: CGFloat
    public var sx: CGFloat
    public var asym: CGFloat

    public init(
        half: CGFloat,
        run: CGFloat,
        d: CGFloat,
        sd: CGFloat,
        sag: CGFloat,
        r: CGFloat = 0,
        tp: CGFloat = 0,
        dip: CGFloat = 0,
        m: CGFloat = 0,
        s2: CGFloat = 44,
        mx: CGFloat = 0,
        sym: CGFloat = 1,
        belly: CGFloat = 0,
        lean: CGFloat = 0,
        sx: CGFloat = 1,
        asym: CGFloat = 0
    ) {
        self.half = half
        self.run = run
        self.d = d
        self.sd = sd
        self.r = r
        self.sag = sag
        self.tp = tp
        self.dip = dip
        self.m = m
        self.s2 = s2
        self.mx = mx
        self.sym = sym
        self.belly = belly
        self.lean = lean
        self.sx = sx
        self.asym = asym
    }

    /// 07-DESIGN-AGREEMENT.md §1: MacBook pill, 257×36, 18pt shoulders, 3pt sag.
    public static let macBookPill = FluidParams(half: 128.5, run: 18, d: 36, sd: 36, sag: 3)

    /// 07-DESIGN-AGREEMENT.md §1: Dell desktop pill at menu-bar height, 24pt shoulders, 2pt sag.
    public static func desktopPill(width: CGFloat, height: CGFloat) -> FluidParams {
        FluidParams(half: width / 2, run: 24, d: height, sd: height, sag: 2)
    }

    /// 07-DESIGN-AGREEMENT.md §1: Dell fullscreen bulge, 72pt shoulders, 2pt sag.
    public static func fullscreenBulge(width: CGFloat) -> FluidParams {
        FluidParams(half: width / 2, run: 72, d: 9, sd: 9, sag: 2)
    }

    /// Ported from `BAND()` (index.html:259-262): content width floors at 560pt, half adds
    /// `FluidShapeGeometry.bandRun` beyond the content half-width.
    public static func band(moduleCount: Int, contentTop: CGFloat) -> FluidParams {
        let n = max(0, moduleCount)
        let content = max(CGFloat(n) * FluidShapeGeometry.cellWidth + 12, 560)
        let half = content / 2 + FluidShapeGeometry.bandRun
        let depth = contentTop + 54
        return FluidParams(half: half, run: FluidShapeGeometry.bandRun, d: depth, sd: depth, sag: 9)
    }
}

/// One field of `FluidParams`, named for spring-per-parameter stepping (Task 2's `FluidMotion`).
public enum FluidParamKey: CaseIterable, Hashable, Sendable {
    case half, run, d, sd, r, sag, tp, dip, m, s2, mx, sym, belly, lean, sx, asym
}

extension FluidParams {
    public subscript(key: FluidParamKey) -> CGFloat {
        get {
            switch key {
            case .half: return half
            case .run: return run
            case .d: return d
            case .sd: return sd
            case .r: return r
            case .sag: return sag
            case .tp: return tp
            case .dip: return dip
            case .m: return m
            case .s2: return s2
            case .mx: return mx
            case .sym: return sym
            case .belly: return belly
            case .lean: return lean
            case .sx: return sx
            case .asym: return asym
            }
        }
        set {
            switch key {
            case .half: half = newValue
            case .run: run = newValue
            case .d: d = newValue
            case .sd: sd = newValue
            case .r: r = newValue
            case .sag: sag = newValue
            case .tp: tp = newValue
            case .dip: dip = newValue
            case .m: m = newValue
            case .s2: s2 = newValue
            case .mx: mx = newValue
            case .sym: sym = newValue
            case .belly: belly = newValue
            case .lean: lean = newValue
            case .sx: sx = newValue
            case .asym: asym = newValue
            }
        }
    }
}

/// Mirrors `frameOf`'s return in the sketch (index.html:264-271).
public struct FluidFrame: Equatable, Sendable {
    public let h: CGFloat
    public let run: CGFloat
    public let d: CGFloat
    public let sd: CGFloat
    public let v: CGFloat
    public let xs: CGFloat
    public let xe: CGFloat
    public let tp: CGFloat
    public let r: CGFloat
    public let x0: CGFloat
    public let x1: CGFloat
}

/// Pure-Swift port (D-02) of `.planning/sketches/005-band-droplet/index.html` /
/// `006-design-round/index.html`'s `frameOf` / `floorY` / `shape` / `pebble` / `neck` — no
/// AppKit/SwiftUI import, y grows downward from the caller's own origin, x is relative to a
/// caller-supplied `cx`, exactly the sketch's coordinate space.
public enum FluidShapeGeometry {
    /// index.html:235 `CELL_W`.
    public static let cellWidth: CGFloat = 178
    /// index.html:235 `BAND_RUN`.
    public static let bandRun: CGFloat = 132
    /// index.html:272 `DROP_H`.
    public static let dropletHeight: CGFloat = 188
    /// index.html:359 `s2 = 122` (the detail droplet's flank width at rest).
    public static let dropletFlank: CGFloat = 122
    /// index.html:234 `TOP.builtin`.
    public static let bandContentTopPhysical: CGFloat = 38
    /// index.html:234 `TOP.dell` / `TOP.dellfs`.
    public static let bandContentTopSynthetic: CGFloat = 12

    public static func frameOf(_ q: FluidParams, cx: CGFloat) -> FluidFrame {
        FluidFrame(h: 0, run: 0, d: 0, sd: 0, v: 0, xs: 0, xe: 0, tp: 0, r: 0, x0: 0, x1: 0)
    }

    public static func floorY(x: CGFloat, q: FluidParams, cx: CGFloat) -> CGFloat {
        0
    }

    public static func outline(cx: CGFloat, q: FluidParams, closed: Bool) -> CGPath {
        CGMutablePath()
    }

    public static func pebble(w: CGFloat, y: CGFloat, h: CGFloat, ox: CGFloat = 0) -> CGPath {
        CGMutablePath()
    }

    public static func neck(a: CGFloat, y0: CGFloat, y1: CGFloat, waist: CGFloat) -> CGPath {
        CGMutablePath()
    }

    public static func contains(_ p: CGPoint, cx: CGFloat, q: FluidParams) -> Bool {
        false
    }

    public static func boundaryY(atX x: CGFloat, cx: CGFloat, q: FluidParams) -> CGFloat {
        0
    }

    public static func probePoints(cx: CGFloat, q: FluidParams, count: Int, offset: CGFloat) -> [(inside: CGPoint, outside: CGPoint)] {
        []
    }
}
