/// D-06 Wave 2 (PANEL-09): the ⌥Space keyboard model as a pure state machine — ported per D-02
/// from `.planning/sketches/006-design-round/index.html`'s `openBand(kbd)`/keydown handler
/// (lines 334-344, 470-499) and 07-DESIGN-AGREEMENT.md §7. No AppKit/SwiftUI import; the AppKit
/// side (plan 12) turns each `Effect` into an action.
///
/// RED-phase stub: signatures are final, bodies are placeholders that intentionally fail the
/// behavior tests (`BandFocusTests.swift`).
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

    /// index.html:334-344 `openBand(true)` — ⌥Space focuses the first module and shows its droplet.
    public mutating func hotkeyOpened() -> Effect { .none }

    public mutating func arrowLeft() -> Effect { .none }
    public mutating func arrowRight() -> Effect { .none }

    /// index.html:487 (band) / 488-492 (drop, `arrowDown` shares Tab's forward step).
    public mutating func arrowDown(controlCount: Int) -> Effect { .none }

    /// index.html:490 — ↑ at the first control returns to the band; elsewhere it steps back.
    public mutating func arrowUp(controlCount: Int) -> Effect { .none }

    /// index.html:488-492 `Tab`/`Shift+Tab` — wraps modulo the control count.
    public mutating func tab(backward: Bool, controlCount: Int) -> Effect { .none }

    /// index.html:493-496 `Return`/`Enter`.
    public mutating func returnKey() -> Effect { .none }

    /// index.html:483 `Escape` — droplet focus returns to the band; a shown droplet closes first;
    /// only then does the band itself close (07-DESIGN-AGREEMENT.md §7).
    public mutating func escape() -> Effect { .none }

    /// index.html:431 — real pointer movement ends keyboard mode.
    public mutating func pointerMoved() -> Effect { .none }

    /// MOD-01: a module switch can shrink the band while focus is active.
    public mutating func moduleCountChanged(_ newCount: Int) -> Effect { .none }
}
