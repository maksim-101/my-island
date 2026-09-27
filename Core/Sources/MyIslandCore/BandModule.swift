import CoreGraphics

/// D-06 Wave 2 (MOD-01, PANEL-04): the band's five modules in fixed order, and the enabled-set
/// rules Settings drives. Ported per D-02 from `.planning/sketches/006-design-round/index.html:242-248`
/// (`MODS`) and `:355` (`DROP_W`) — no AppKit/SwiftUI import.
///
/// RED-phase stub: signatures are final, bodies are placeholders that intentionally fail the
/// behavior tests (`BandModuleTests.swift`).
public enum BandModule: String, CaseIterable, Sendable {
    case nowPlaying, timer, nextMeeting, claude, clipboard

    /// index.html:355 `DROP_W` — the detail droplet's own resting width for this module.
    public var dropletWidth: CGFloat { 0 }

    /// index.html:242-248 `MODS[].name`.
    public var displayName: String { "" }
}

/// 07-DESIGN-AGREEMENT.md §8 (MOD-01): the persisted enabled subset, fixed order, last-module-stays.
public enum BandModules {
    /// Unknown stored names are dropped; a `nil` or empty result reads as every module enabled —
    /// the band can never be built with zero modules (T-07-05).
    public static func enabled(from stored: [String]?) -> [BandModule] {
        []
    }

    /// `false` only when `module` is the last remaining enabled module.
    public static func canDisable(_ module: BandModule, in enabled: [BandModule]) -> Bool {
        true
    }

    /// index.html:764-771 module-switch handler — toggling off removes it (refused for the last
    /// module); toggling on re-adds it at its fixed `BandModule.allCases` position.
    public static func toggling(_ module: BandModule, in enabled: [BandModule]) -> [BandModule] {
        enabled
    }
}
