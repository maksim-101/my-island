import SwiftUI

/// FEEL-01 (07-DESIGN-AGREEMENT.md §10): press feedback within one frame — `configuration.isPressed`
/// flips synchronously with `Button`'s own mouse-down/up tracking, unlike `.onTapGesture`'s
/// gesture-recognizer callback, which is not guaranteed to land in the same frame as the mouse-down
/// (RESEARCH.md Pattern 5). Dims and scales to 0.86 on press; a faint highlight shows on hover.
/// Every one-click control in later plans uses this style — Join (07-05 Task 3) is its first user.
///
/// `.onHover` is used here rather than a hand-rolled pointer comparison; verify on hardware that it
/// fires reliably for a button hosted inside a non-activating `NSPanel` (the same caveat
/// RESEARCH.md's own Pattern 5 flags). If it does not, a later plan should feed hover from the
/// controller's own live pointer position through an environment value instead of widening this
/// style's own contract.
struct GlyphButtonStyle: ButtonStyle {
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlay {
                if isHovering, !configuration.isPressed {
                    Capsule().fill(Color.white.opacity(0.15))
                }
            }
            .scaleEffect(configuration.isPressed ? 0.86 : 1)
            .opacity(configuration.isPressed ? 0.86 : 1)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
            .onHover { isHovering = $0 }
    }
}
