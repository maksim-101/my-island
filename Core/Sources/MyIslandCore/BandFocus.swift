/// D-06 Wave 2 (PANEL-09): the ⌥Space keyboard model as a pure state machine — ported per D-02
/// from `.planning/sketches/006-design-round/index.html`'s `openBand(kbd)`/keydown handler
/// (lines 334-344, 470-499) and 07-DESIGN-AGREEMENT.md §7. No AppKit/SwiftUI import; the AppKit
/// side (plan 12) turns each `Effect` into an action.
public struct BandFocus: Equatable {
    public enum Zone: Equatable {
        case band(Int)
        case droplet(Int)
    }

    public enum Effect: Equatable {
        case none
        case showDroplet(Int)
        case closeDroplet
        case closeBand
        case performGlyph(Int)
        case pressControl(Int)
    }

    public private(set) var zone: Zone?
    public private(set) var pinned: Int?
    public private(set) var showing: Int?
    public var moduleCount: Int

    public init(moduleCount: Int) {
        self.moduleCount = moduleCount
    }

    private var moduleUpperBound: Int { max(1, moduleCount) - 1 }

    /// index.html:334-344 `openBand(true)` — ⌥Space focuses the first module and shows its droplet.
    public mutating func hotkeyOpened() -> Effect {
        zone = .band(0)
        pinned = 0
        showing = 0
        return .showDroplet(0)
    }

    public mutating func arrowLeft() -> Effect { move(by: -1) }
    public mutating func arrowRight() -> Effect { move(by: 1) }

    /// index.html:484-486 `f.i = clamp(f.i + delta); st.pinned = f.i; setHot(f.i);` — always
    /// re-shows the droplet at the clamped index, even when the clamp keeps it unchanged.
    private mutating func move(by delta: Int) -> Effect {
        guard case .band(let i) = zone else { return .none }
        let next = max(0, min(moduleUpperBound, i + delta))
        zone = .band(next)
        pinned = next
        showing = next
        return .showDroplet(next)
    }

    /// index.html:487 (band) / 488-492 (drop, `arrowDown` shares Tab's forward step).
    public mutating func arrowDown(controlCount: Int) -> Effect {
        switch zone {
        case .band(let i):
            pinned = i
            showing = i
            if controlCount > 0 { zone = .droplet(0) }
            return .showDroplet(i)
        case .droplet:
            return tab(backward: false, controlCount: controlCount)
        case .none:
            return .none
        }
    }

    /// index.html:490 — ↑ at the first control returns to the band; elsewhere it steps back.
    public mutating func arrowUp(controlCount: Int) -> Effect {
        guard case .droplet(let i) = zone else { return .none }
        if i == 0 {
            zone = .band(pinned ?? 0)
        } else {
            zone = .droplet(i - 1)
        }
        return .none
    }

    /// index.html:488-492 `Tab`/`Shift+Tab` — wraps modulo the control count.
    public mutating func tab(backward: Bool, controlCount: Int) -> Effect {
        guard case .droplet(let i) = zone, controlCount > 0 else { return .none }
        let next = (i + (backward ? -1 : 1) + controlCount) % controlCount
        zone = .droplet(next)
        return .none
    }

    /// index.html:493-496 `Return`/`Enter`.
    public mutating func returnKey() -> Effect {
        switch zone {
        case .band(let i): return .performGlyph(i)
        case .droplet(let i): return .pressControl(i)
        case .none: return .none
        }
    }

    /// index.html:483 `Escape` — droplet focus returns to the band; a shown droplet closes first;
    /// only then does the band itself close (07-DESIGN-AGREEMENT.md §7).
    public mutating func escape() -> Effect {
        switch zone {
        case .droplet:
            zone = .band(pinned ?? 0)
            return .none
        case .band:
            if showing != nil {
                pinned = nil
                showing = nil
                return .closeDroplet
            }
            zone = nil
            pinned = nil
            return .closeBand
        case .none:
            return .none
        }
    }

    /// index.html:431 — real pointer movement ends keyboard mode.
    public mutating func pointerMoved() -> Effect {
        zone = nil
        return .none
    }

    /// MOD-01: a module switch can shrink the band while focus is active.
    public mutating func moduleCountChanged(_ newCount: Int) -> Effect {
        moduleCount = newCount
        let upper = max(1, newCount) - 1
        if let p = pinned, p > upper { pinned = upper }
        if let s = showing, s > upper { showing = upper }
        if case .band(let i) = zone, i > upper { zone = .band(upper) }
        return .none
    }
}
