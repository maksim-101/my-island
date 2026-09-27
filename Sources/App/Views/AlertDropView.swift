import SwiftUI
import MyIslandCore

/// One drop type for the volume/brightness HUD and, from Task 3, the meeting alert
/// (07-DESIGN-AGREEMENT.md §6, FLUID-02/PANEL-07): a pebble that swells out of whatever the
/// collapsed surface currently shows (MacBook pill, Dell pill or fullscreen bulge), hangs by a
/// neck that narrows to an hourglass, pinches off at 7pt and settles 8pt below. `motion` supplies
/// every geometry channel (`params`, `channels[.dropOffset/.dropHeight/.dropHalfWidth/.dropAlpha]`)
/// plus the attachment hysteresis (`dropDetached`) kept ON `FluidMotion` itself — not this
/// transient struct — so it survives being torn down and recreated on every SwiftUI re-render.
/// `kind` only ever decides the CONTENT drawn inside the drop, never the shape math both kinds
/// share.
struct AlertDropView: View {
    enum Kind {
        case level(glyph: HUDGlyph, level: Double)
    }

    let motion: FluidMotion
    let kind: Kind
    let isPhysical: Bool

    var body: some View {
        GeometryReader { proxy in
            let cx = proxy.size.width / 2
            let q = motion.params
            // Ported from index.html:547 `floorY(cx, Q, cx)` — the floor's own height at the
            // shape's center, in this view's local top-down coordinate space.
            let baseY = FluidShapeGeometry.floorY(x: cx, q: q, cx: cx)
            let dropOffset = motion.channels[.dropOffset] ?? 0
            let dropHeight = max(0, motion.channels[.dropHeight] ?? 0)
            let dropHalfWidth = max(0, motion.channels[.dropHalfWidth] ?? 0)
            let dropAlpha = max(0, min(1, motion.channels[.dropAlpha] ?? 0))
            let yT = baseY + dropOffset
            // `g = yT - baseY` in the sketch — `baseY` cancels, so `g` is just `dropOffset`.
            let g = dropOffset
            let dropVisible = yT + dropHeight > baseY + 0.5 && dropHalfWidth > 1

            if dropVisible {
                let pebblePath = Path(FluidShapeGeometry.pebble(w: dropHalfWidth, y: yT, h: dropHeight, ox: cx))
                ZStack {
                    pebblePath
                        .fill(Tokens.Color.accent)
                        .opacity(0.22)
                        .blur(radius: 4)
                    pebblePath
                        .fill(Color.black)
                    pebblePath
                        .stroke(Tokens.Color.accent.opacity(0.34), lineWidth: 0.9)

                    // The neck hides the seam between the floor and the falling drop — shown
                    // only while still attached (index.html:554-555): `na`/`waist` port verbatim.
                    if !motion.dropDetached, g > -1.5 {
                        let na = min(dropHalfWidth * 0.6, 60)
                        let t = max(0, min(1, g / 7))
                        let waist = na * pow(1 - t, 1.4)
                        if waist > 0.8 {
                            Path(FluidShapeGeometry.neck(a: na, y0: baseY, y1: yT, waist: waist))
                                .offsetBy(dx: cx, dy: 0)
                                .fill(Color.black)
                        }
                    }

                    // Content fades in only after separation (index.html:587's
                    // `clamp((g-4)/4)`), never before — resting eyes see the drop swell and pinch
                    // off before anything inside it becomes legible.
                    content
                        .frame(width: max(1, dropHalfWidth * 2 - Tokens.Spacing.sm), height: max(1, dropHeight))
                        .position(x: cx, y: yT + dropHeight / 2)
                        .opacity(dropAlpha * max(0, min(1, (g - 4) / 4)))
                }
            }
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var content: some View {
        switch kind {
        case .level(let glyph, let level):
            levelContent(glyph: glyph, level: level)
        }
    }

    /// The volume/brightness glyph + a neutral (never amber, D-06) level bar whose fill animates
    /// on level change (FEEL-02) — ported in spirit from the retired `HUDPillView.pill`.
    private func levelContent(glyph: HUDGlyph, level: Double) -> some View {
        HStack(spacing: Tokens.Spacing.sm) {
            Image(systemName: glyph.systemName)
                .font(Tokens.Font.data)
                .foregroundStyle(Tokens.Color.text)
            Capsule()
                .fill(Tokens.Color.hairline)
                .frame(width: 44, height: 4)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(Tokens.Color.text)
                        .frame(width: 44 * max(0, min(1, level)))
                        .animation(.easeOut(duration: 0.18), value: level)
                }
        }
    }
}
