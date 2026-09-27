import SwiftUI
import MyIslandCore

/// The click-through overlay's content (07-02 Task 1): rim + glow drawn in a window that is
/// ALWAYS `ignoresMouseEvents = true` (`NotchPanelController.makeOverlayPanel`), so no halo pixel
/// can ever catch a click regardless of which click-through mechanism the interactive panel below
/// uses. Ordered in front of the interactive panel — later plans draw the drop's neck and the
/// pulse from here too. Hidden while the panel is open (no outline concept for the expanded band
/// until plan 08).
struct FluidOverlayView: View {
    let motion: FluidMotion
    let model: NotchViewModel

    var body: some View {
        if !model.isOpen {
            let glow = max(0, motion.channels[.glow] ?? 0.2)
            ZStack {
                // The glow: the closed outline filled and blurred, with the outline's own
                // (unblurred) interior punched out so only the halo bleeding past the fill's edge
                // is visible — the fill itself already reads as solid black from the interactive
                // panel underneath.
                FluidOutlineShape(params: motion.params, closed: true)
                    .fill(Tokens.Color.accent)
                    .blur(radius: 5)
                    .opacity(glow)
                    .overlay {
                        FluidOutlineShape(params: motion.params, closed: true)
                            .fill(.black)
                            .blendMode(.destinationOut)
                    }
                    .compositingGroup()

                // The rim: a thin open-path stroke along the same outline.
                FluidOutlineShape(params: motion.params, closed: false)
                    .stroke(Tokens.Color.accent, lineWidth: 0.9)
                    .opacity(0.32 + max(0, glow - 0.2))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .allowsHitTesting(false)
        }
    }
}
