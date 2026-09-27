import SwiftUI
import MyIslandCore

/// The one `Shape` every fluid surface draws through — pill, Dell pill, fullscreen bulge, band,
/// and (via `FluidShapeGeometry.pebble`/`.neck` directly, not through this type) the detail
/// droplet and alert/HUD drop. No `animatableData`: per RESEARCH.md Pitfall 2, motion is driven
/// externally on one `FluidMotion` clock (Task 2), never interpolated by SwiftUI's own animation
/// system — this type only ever renders the CURRENT, already-stepped `FluidParams`.
struct FluidOutlineShape: Shape {
    var params: FluidParams
    var closed: Bool = true

    func path(in rect: CGRect) -> Path {
        Path(FluidShapeGeometry.outline(cx: rect.midX, q: params, closed: closed))
    }
}
