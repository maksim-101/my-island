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
    /// 07-02 Task 3 (D-07): whether this window's own display can ever render glass — always
    /// `false` on the MacBook, mirroring `NotchContentView.fillView`'s `!isPhysical` gate exactly
    /// so the two views can never disagree about which material is showing.
    let isPhysical: Bool

    /// Read live (like `NotchContentView`'s own copy) so switching in Settings drops/restores the
    /// glow with no panel rebuild.
    @AppStorage(NotchPanelController.surfaceMaterialKey) private var surfaceMaterial = NotchPanelController.surfaceMaterialDefault

    /// The overlay keeps the rim but drops the glow for glass (07-02 Task 3, D-07) — the glass
    /// material already carries its own specular highlight; stacking the accent glow on top read
    /// as muddy.
    private var isGlass: Bool { !isPhysical && surfaceMaterial == "glass" }

    var body: some View {
        if !model.isOpen {
            let glow = max(0, motion.channels[.glow] ?? 0.2)
            ZStack {
                // The glow: the closed outline filled and blurred, with the outline's own
                // (unblurred) interior punched out so only the halo bleeding past the fill's edge
                // is visible — the fill itself already reads as solid black from the interactive
                // panel underneath. Dropped entirely for glass (D-07, Task 3).
                if !isGlass {
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
                }

                // The rim: a thin open-path stroke along the same outline — kept for every material.
                FluidOutlineShape(params: motion.params, closed: false)
                    .stroke(Tokens.Color.accent, lineWidth: 0.9)
                    .opacity(0.32 + max(0, glow - 0.2))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .allowsHitTesting(false)
        }
    }
}
