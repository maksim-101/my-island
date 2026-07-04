import SwiftUI

/// Single source of truth for expanded-panel sizing and the open/close morph
/// animation, shared by the AppKit window sizing in `NotchPanelController`
/// and the SwiftUI content sizing in `NotchContentView` so they cannot drift.
enum NotchLayout {
    static let expandedWidthMultiplier: CGFloat = 3.5
    static let expandedHeight: CGFloat = 200
    static let morphAnimation: Animation = .interactiveSpring(response: 0.38, dampingFraction: 0.8)
}
