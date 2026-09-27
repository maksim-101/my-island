import SwiftUI

/// PANEL-09 (07-12): the droplet's own registry of focusable controls — one instance per panel
/// (`NotchPanel.dropletFocus`), mirroring `BandFocus`'s per-panel ownership. `DropletView` injects
/// it into the environment and calls `reset()` whenever the shown module changes; every control
/// inside a droplet content view registers itself via `.dropletFocusable(index:ring:action:)`.
/// `BandFocus`'s own `controlCount` parameter (`arrowDown`/`arrowUp`/`tab`) reads `count` here, and
/// the `.pressControl(i)` effect calls `perform(i)` — this class owns no key-routing logic itself,
/// only the live registry the AppKit side reads/drives.
@MainActor
@Observable
final class DropletFocus {
    private(set) var focusedIndex: Int?
    private var order: [Int] = []
    private var actions: [Int: () -> Void] = [:]

    /// The current droplet's control count — `BandFocus.arrowDown/arrowUp/tab`'s own
    /// `controlCount:` parameter reads this live value on every key press.
    var count: Int { order.count }

    init() {}

    /// Registers (or updates) the action for a control at `index` — called from
    /// `.dropletFocusable`'s `onAppear`. Safe to call more than once for the same index (a
    /// re-render with a fresh action closure simply overwrites the stored one).
    func register(index: Int, action: @escaping () -> Void) {
        if !order.contains(index) {
            order.append(index)
            order.sort()
        }
        actions[index] = action
    }

    /// Un-registers a control — called from `.dropletFocusable`'s `onDisappear` (a state branch
    /// swap, e.g. the timer's idle→running content swap, removes and re-adds a different control
    /// set without `DropletView` itself ever calling `reset()`). Clears `focusedIndex` if it
    /// pointed at the control being removed, rather than leaving a ghost focus on a control that no
    /// longer exists (PANEL-09's own index-bounds truth).
    func unregister(index: Int) {
        order.removeAll { $0 == index }
        actions.removeValue(forKey: index)
        if focusedIndex == index {
            focusedIndex = nil
        }
    }

    /// `.pressControl(i)` — a no-op if nothing is registered at `index` (defensive: matches every
    /// other App-layer guard in this phase against a stale/out-of-range index).
    func perform(_ index: Int) {
        actions[index]?()
    }

    func setFocusedIndex(_ index: Int?) {
        focusedIndex = index
    }

    /// Called by `DropletView` whenever the shown module changes — clears both the registry and
    /// the focused index so a fresh droplet never inherits a stale ring/registration from whatever
    /// was showing before.
    func reset() {
        focusedIndex = nil
        order.removeAll()
        actions.removeAll()
    }
}

/// The shape of the standard 2pt accent focus ring a `dropletFocusable` control draws around
/// itself — matches whatever clip shape the control's own background already uses (capsule,
/// rounded rect, or circle) so the ring never looks mismatched against the control it outlines.
enum DropletFocusRingShape {
    case roundedRect(CGFloat)
    case circle
    case capsule
}

extension View {
    /// Registers this control at `index` in the droplet's `DropletFocus` (read from the
    /// environment `DropletView` injects) and draws the standard 2pt accent focus ring, inset 2pt
    /// beyond the control's own bounds, whenever it is the currently keyboard-focused control.
    /// `action` is the control's OWN existing action — the same closure a click already runs, so
    /// `BandFocus`'s `.pressControl(i)` effect (routed to `DropletFocus.perform(_:)`) executes the
    /// identical code path a click does.
    func dropletFocusable(index: Int, ring: DropletFocusRingShape = .roundedRect(8), action: @escaping () -> Void) -> some View {
        modifier(DropletFocusableModifier(index: index, ring: ring, action: action))
    }
}

private struct DropletFocusableModifier: ViewModifier {
    let index: Int
    let ring: DropletFocusRingShape
    let action: () -> Void
    @Environment(DropletFocus.self) private var focus

    func body(content: Content) -> some View {
        content
            .overlay {
                if focus.focusedIndex == index {
                    ringShape.stroke(Tokens.Color.accent, lineWidth: 2)
                }
            }
            .onAppear { focus.register(index: index, action: action) }
            .onDisappear { focus.unregister(index: index) }
    }

    private var ringShape: AnyShape {
        switch ring {
        case .roundedRect(let radius):
            return AnyShape(RoundedRectangle(cornerRadius: radius).inset(by: -2))
        case .circle:
            return AnyShape(Circle().inset(by: -2))
        case .capsule:
            return AnyShape(Capsule().inset(by: -2))
        }
    }
}
