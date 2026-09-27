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

    /// 07-DESIGN-AGREEMENT.md §1, amended 2026-09-27 (07-15, D-06 gap closure): MacBook pill,
    /// 257pt wide, 18pt shoulders, 3pt sag — depth is the display's measured menu-bar height,
    /// the same rule `desktopPill` already uses below, floored at the notch height so a zero read
    /// (Pitfall 3, `NSScreen.menuBarHeight` before launch completes) or an auto-hidden menu bar
    /// can never uncover the camera housing (FLUID-01). The retired fixed depth (36pt) calibrated
    /// against the design sketch's own 37pt-tall built-in menu bar; this Mac's hardware bar
    /// measures 33pt, which is what made the fixed depth overhang by 6pt (07-06 gate row 1;
    /// uat-evidence/gap-15/01-baseline-probe.txt).
    public static func macBookPill(menuBarHeight: CGFloat, notchHeight: CGFloat) -> FluidParams {
        let depth = max(menuBarHeight, notchHeight)
        return FluidParams(half: 128.5, run: 18, d: depth, sd: depth, sag: 3)
    }

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

    /// Ported verbatim from index.html:264-271 `frameOf`. Same clamps, same order of operations.
    public static func frameOf(_ q: FluidParams, cx: CGFloat) -> FluidFrame {
        let h = q.half * q.sx
        let run = max(min(q.run, h - 2), 0.5)
        let d = max(q.d, 0.5)
        let sd = min(max(q.sd, 0.5), d)
        let v = max(0, min(1, (d - sd) / sd))
        let xs = cx - h + run
        let xe = cx + h - run
        let tp0 = max(0, q.tp) * v
        let r = max(0, min(q.r * v, (d - sd) * 0.8, (xe - xs) / 2 - tp0))
        let tq = tp0 * max(0, min(1, (d - r - sd) / 60))
        return FluidFrame(h: h, run: run, d: d, sd: sd, v: v, xs: xs, xe: xe, tp: tq, r: r, x0: xs + tq + r, x1: xe - tq - r)
    }

    /// Ported verbatim from index.html:273-285 `floorY` — the smootherstep flank, belly and
    /// drawdown terms for the detail droplet's depth, layered on top of the resting sag.
    public static func floorY(x: CGFloat, q: FluidParams, cx: CGFloat) -> CGFloat {
        let f0 = frameOf(q, cx: cx)
        let u = max(-1, min(1, (x - (cx + q.lean)) / max(1, (f0.x1 - f0.x0) / 2)))
        let y = f0.d + (q.sag + q.belly) * (1 - u * u)
        let dip = max(0, q.dip)
        guard dip >= 0.01 else { return y }
        let k = dip / dropletHeight
        let sxv = x - (cx + q.mx)
        let a = abs(sxv)
        let m = max(0, q.m)
        let s2 = max(1, q.s2 * (1 + (sxv < 0 ? 1 : -1) * q.asym))
        func smootherstep(_ t: CGFloat) -> CGFloat { t * t * t * (t * (t * 6 - 15) + 10) }
        let f: CGFloat = a <= m ? 1 : (a < m + s2 ? smootherstep(1 - (a - m) / s2) : 0)
        let belly: CGFloat = a <= m
            ? min(18 * k, dip * 0.25) * (1 - (a / max(1, m)) * (a / max(1, m))) * (1 - (a / max(1, m)) * (a / max(1, m)))
            : 0
        let draw = min(7 * k, dip * 0.12) * exp(-((sxv / (m + s2 + 70)) * (sxv / (m + s2 + 70))))
        return y + dip * f + belly + draw
    }

    /// Ported verbatim from index.html:286-302 `shape` — the same cubic control points, `k1`/`k2`
    /// from `sym`, the pure-S branch (when `d == sd`), and 120 floor samples joined by lines.
    public static func outline(cx: CGFloat, q: FluidParams, closed: Bool) -> CGPath {
        let f = frameOf(q, cx: cx)
        let h = f.h, run = f.run, d = f.d, sd = f.sd, v = f.v, xs = f.xs, xe = f.xe, tp = f.tp, r = f.r
        let L = cx - h, R = cx + h
        func lerp(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * v }
        let cy = lerp(sd * 0.88, sd * 0.35)
        let H = d - r - sd
        let bl = xs + tp, br = xe - tp
        let pureS = d - sd <= 0.5
        let sl = pureS ? floorY(x: f.x0, q: q, cx: cx) : sd
        let sr = pureS ? floorY(x: f.x1, q: q, cx: cx) : sd
        let k1 = 0.52 - 0.12 * q.sym
        let k2 = 0.76 - 0.14 * q.sym
        let dl = run * (1 - k2)
        let gl = (floorY(x: f.x0 + 0.5, q: q, cx: cx) - sl) / 0.5
        let gr = (sr - floorY(x: f.x1 - 0.5, q: q, cx: cx)) / 0.5

        let path = CGMutablePath()
        path.move(to: CGPoint(x: L, y: 0))
        path.addCurve(
            to: CGPoint(x: xs, y: sl),
            control1: CGPoint(x: L + run * k1, y: 0),
            control2: CGPoint(x: lerp(L + run * k2, xs), y: pureS ? sl - gl * dl : cy)
        )
        if d - sd > 0.5 {
            path.addCurve(
                to: CGPoint(x: bl, y: d - r),
                control1: CGPoint(x: xs, y: sd + H * 0.45),
                control2: CGPoint(x: bl, y: d - r - H * 0.3)
            )
            path.addCurve(
                to: CGPoint(x: bl + r, y: d),
                control1: CGPoint(x: bl, y: d - r * 0.45),
                control2: CGPoint(x: bl + r * 0.45, y: d)
            )
        }
        let N = 120
        for i in 0...N {
            let x = f.x0 + (f.x1 - f.x0) * CGFloat(i) / CGFloat(N)
            path.addLine(to: CGPoint(x: x, y: floorY(x: x, q: q, cx: cx)))
        }
        if d - sd > 0.5 {
            path.addCurve(
                to: CGPoint(x: br, y: d - r),
                control1: CGPoint(x: br - r * 0.45, y: d),
                control2: CGPoint(x: br, y: d - r * 0.45)
            )
            path.addCurve(
                to: CGPoint(x: xe, y: sd),
                control1: CGPoint(x: br, y: d - r - H * 0.3),
                control2: CGPoint(x: xe, y: sd + H * 0.45)
            )
        } else {
            path.addLine(to: CGPoint(x: xe, y: sr))
        }
        path.addCurve(
            to: CGPoint(x: R, y: 0),
            control1: CGPoint(x: lerp(R - run * k2, xe), y: pureS ? sr + gr * dl : cy),
            control2: CGPoint(x: R - run * k1, y: 0)
        )
        if closed { path.closeSubpath() }
        return path
    }

    /// Ported verbatim from index.html:412-418 `pebble` — a separate drop with a soft, slightly
    /// sagging top and a rounded belly, same winding as the outline.
    public static func pebble(w: CGFloat, y: CGFloat, h: CGFloat, ox: CGFloat = 0) -> CGPath {
        let r = min(h / 2, w)
        let a = -w + ox
        let b = w + ox
        let path = CGMutablePath()
        path.move(to: CGPoint(x: b - r, y: y))
        path.addCurve(
            to: CGPoint(x: a + r, y: y),
            control1: CGPoint(x: w / 3 + ox, y: y + 2.5),
            control2: CGPoint(x: -w / 3 + ox, y: y + 2.5)
        )
        path.addCurve(
            to: CGPoint(x: a, y: y + r),
            control1: CGPoint(x: a + r * 0.45, y: y),
            control2: CGPoint(x: a, y: y + r * 0.55)
        )
        path.addCurve(
            to: CGPoint(x: a + r, y: y + h),
            control1: CGPoint(x: a, y: y + h - r * 0.55),
            control2: CGPoint(x: a + r * 0.45, y: y + h)
        )
        path.addCurve(
            to: CGPoint(x: b - r, y: y + h),
            control1: CGPoint(x: -w / 3 + ox, y: y + h + 3),
            control2: CGPoint(x: w / 3 + ox, y: y + h + 3)
        )
        path.addCurve(
            to: CGPoint(x: b, y: y + h - r),
            control1: CGPoint(x: b - r * 0.45, y: y + h),
            control2: CGPoint(x: b, y: y + h - r * 0.55)
        )
        path.addCurve(
            to: CGPoint(x: b - r, y: y),
            control1: CGPoint(x: b, y: y + r * 0.55),
            control2: CGPoint(x: b - r * 0.45, y: y)
        )
        path.closeSubpath()
        return path
    }

    /// Ported verbatim from index.html:420-424 `neck` — the liquid bridge between floor and drop;
    /// its waist narrows as the drop falls.
    public static func neck(a: CGFloat, y0: CGFloat, y1: CGFloat, waist: CGFloat) -> CGPath {
        let my = (y0 + y1) / 2
        let path = CGMutablePath()
        path.move(to: CGPoint(x: -a, y: y0 - 4))
        path.addLine(to: CGPoint(x: a, y: y0 - 4))
        path.addCurve(
            to: CGPoint(x: waist, y: my),
            control1: CGPoint(x: a, y: y0 + 1),
            control2: CGPoint(x: waist, y: my - 1.5)
        )
        path.addCurve(
            to: CGPoint(x: a, y: y1 + 4),
            control1: CGPoint(x: waist, y: my + 1.5),
            control2: CGPoint(x: a, y: y1 - 1)
        )
        path.addLine(to: CGPoint(x: -a, y: y1 + 4))
        path.addCurve(
            to: CGPoint(x: -waist, y: my),
            control1: CGPoint(x: -a, y: y1 - 1),
            control2: CGPoint(x: -waist, y: my + 1.5)
        )
        path.addCurve(
            to: CGPoint(x: -a, y: y0 - 4),
            control1: CGPoint(x: -waist, y: my - 1.5),
            control2: CGPoint(x: -a, y: y0 + 1)
        )
        path.closeSubpath()
        return path
    }

    /// Not named in the sketch (a DOM `getBoundingClientRect`/pointer-hit-test stood in for it
    /// there); the closed outline's own winding fill, exactly what the WindowServer's alpha
    /// hit-test approximates on a real panel.
    public static func contains(_ p: CGPoint, cx: CGFloat, q: FluidParams) -> Bool {
        outline(cx: cx, q: q, closed: true).contains(p, using: .winding, transform: .identity)
    }

    /// Not named in the sketch. Bisection on `contains` between `y = 0` (never tested directly —
    /// on-boundary is undefined, so the search starts strictly above it) and
    /// `d + sag + dip + 60` (always below the deepest possible drawn floor), 40 iterations.
    public static func boundaryY(atX x: CGFloat, cx: CGFloat, q: FluidParams) -> CGFloat {
        let path = outline(cx: cx, q: q, closed: true)
        var lo: CGFloat = 0
        var hi: CGFloat = q.d + q.sag + q.dip + 60
        for _ in 0..<40 {
            let mid = (lo + hi) / 2
            if path.contains(CGPoint(x: x, y: mid), using: .winding, transform: .identity) {
                lo = mid
            } else {
                hi = mid
            }
        }
        return (lo + hi) / 2
    }

    /// Not named in the sketch. `count` x positions evenly spread over
    /// `(cx - half + 1) ... (cx + half - 1)`, each pair straddling `boundaryY` by `offset`. Near
    /// a shoulder tip `boundaryY` approaches 0, so a naive `boundaryY - offset` can go negative
    /// (above the shape's own top edge, not "more inside") — clamp the inside probe to never go
    /// above half the boundary's own height, keeping it a genuine interior point at every x.
    public static func probePoints(cx: CGFloat, q: FluidParams, count: Int, offset: CGFloat) -> [(inside: CGPoint, outside: CGPoint)] {
        guard count > 0 else { return [] }
        let lo = cx - q.half + 1
        let hi = cx + q.half - 1
        var results: [(inside: CGPoint, outside: CGPoint)] = []
        results.reserveCapacity(count)
        for i in 0..<count {
            let t: CGFloat = count == 1 ? 0.5 : CGFloat(i) / CGFloat(count - 1)
            let x = lo + (hi - lo) * t
            let boundary = boundaryY(atX: x, cx: cx, q: q)
            let insideY = max(boundary - offset, boundary / 2)
            let outsideY = boundary + offset
            results.append((inside: CGPoint(x: x, y: insideY), outside: CGPoint(x: x, y: outsideY)))
        }
        return results
    }
}
