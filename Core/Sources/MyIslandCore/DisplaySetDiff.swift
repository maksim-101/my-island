/// A pure added/removed/kept diff over two sets of display-identity keys (Phase 6 SHELL-09).
/// `NotchPanelController.rebuildPanels()` builds one of these from `Set(panelSets.keys)` (previous)
/// and the freshly resolved `Set(desired.keys)` (current) on every screen-parameter notification, so a
/// reconcile touches only what changed instead of tearing down and rebuilding every panel set.
///
/// Output is sorted lexicographically so callers get a deterministic iteration order regardless of
/// `NSScreen.screens` order or `Set` iteration order — no AppKit, no UUID type: keys are plain
/// `NSScreen.displayKey` strings, kept here as `String` so this type stays a pure Core value with no
/// platform dependency.
public struct DisplaySetDiff: Equatable, Sendable {
    public let added: [String]
    public let removed: [String]
    public let kept: [String]

    public init(previous: Set<String>, current: Set<String>) {
        added = current.subtracting(previous).sorted()
        removed = previous.subtracting(current).sorted()
        kept = current.intersection(previous).sorted()
    }
}
