import Testing
@testable import MyIslandCore

/// Test names trace back to RESEARCH.md §2.2 (Safari) / §2.3 (Vivaldi) measured state tables, so a
/// future reader can find the exact transcript a given case models.

private func facts(
    isAppFullscreen: Bool,
    isBrowser: Bool,
    axFullscreen: Bool? = nil,
    subrole: String? = nil,
    titleIsEmpty: Bool? = nil
) -> FullscreenFacts {
    FullscreenFacts(
        isAppFullscreen: isAppFullscreen,
        isBrowser: isBrowser,
        axFocusedWindowIsFullscreen: axFullscreen,
        axFocusedWindowSubrole: subrole,
        axFocusedWindowTitleIsEmpty: titleIsEmpty
    )
}

// MARK: - Safari (RESEARCH §2.2)

/// States A and H: windowed, video playing in a regular tab — not app-fullscreen at all.
@Test func safariStatesAAndHWindowedShowsRow() {
    let windowed = facts(isAppFullscreen: false, isBrowser: true)
    #expect(FullscreenClassifier.decide(windowed) == .show)
}

/// State B: Spaces fullscreen, video in a regular tab, NOT element-fullscreen — the locked
/// YouTube-in-a-tab case. AXStandardWindow, non-empty title.
@Test func safariStateBSpacesFullscreenWithVideoInTabShowsRow() {
    let state = facts(isAppFullscreen: true, isBrowser: true, axFullscreen: true, subrole: "AXStandardWindow", titleIsEmpty: false)
    #expect(FullscreenClassifier.decide(state) == .show)
}

/// State C: Spaces fullscreen + <video> element fullscreen — AXDialog, empty title.
@Test func safariStateCSpacesFullscreenPlusElementFullscreenSuppressesRow() {
    let state = facts(isAppFullscreen: true, isBrowser: true, axFullscreen: true, subrole: "AXDialog", titleIsEmpty: true)
    #expect(FullscreenClassifier.decide(state) == .suppress)
}

/// State D: exit element fullscreen, still Spaces fullscreen — back to AXStandardWindow.
@Test func safariStateDExitElementFullscreenStillSpacesFullscreenShowsRow() {
    let state = facts(isAppFullscreen: true, isBrowser: true, axFullscreen: true, subrole: "AXStandardWindow", titleIsEmpty: false)
    #expect(FullscreenClassifier.decide(state) == .show)
}

/// State E: windowed again — not app-fullscreen.
@Test func safariStateEWindowedAgainShowsRow() {
    let state = facts(isAppFullscreen: false, isBrowser: true)
    #expect(FullscreenClassifier.decide(state) == .show)
}

/// State F: windowed browser + <video> element fullscreen — AXDialog, empty title, same as C.
@Test func safariStateFWindowedPlusElementFullscreenSuppressesRow() {
    let state = facts(isAppFullscreen: true, isBrowser: true, axFullscreen: true, subrole: "AXDialog", titleIsEmpty: true)
    #expect(FullscreenClassifier.decide(state) == .suppress)
}

/// State G: windowed browser + container <div> fullscreen (the YouTube/Crunchyroll pattern) —
/// identical AX signature to F, proving the rule is not bare-<video>-specific.
@Test func safariStateGContainerDivFullscreenSuppressesRow() {
    let state = facts(isAppFullscreen: true, isBrowser: true, axFullscreen: true, subrole: "AXDialog", titleIsEmpty: true)
    #expect(FullscreenClassifier.decide(state) == .suppress)
}

// MARK: - Vivaldi / Chromium (RESEARCH §2.3 — measured negative result, states are indistinguishable)

@Test func vivaldiStateAWindowedShowsRow() {
    let state = facts(isAppFullscreen: false, isBrowser: true)
    #expect(FullscreenClassifier.decide(state) == .show)
}

@Test func vivaldiStateBSpacesFullscreenNotElementFullscreenShowsRow() {
    let state = facts(isAppFullscreen: true, isBrowser: true, axFullscreen: true, subrole: "AXStandardWindow", titleIsEmpty: false)
    #expect(FullscreenClassifier.decide(state) == .show)
}

/// State C: Chromium reuses the SAME window for tab-fullscreen video — byte-identical AX
/// signature to B, so this is the measured negative result: never suppress in Vivaldi.
@Test func vivaldiElementFullscreenStillShowsRow() {
    let state = facts(isAppFullscreen: true, isBrowser: true, axFullscreen: true, subrole: "AXStandardWindow", titleIsEmpty: false)
    #expect(FullscreenClassifier.decide(state) == .show)
}

@Test func vivaldiStateDBackToSpacesFullscreenOnlyShowsRow() {
    let state = facts(isAppFullscreen: true, isBrowser: true, axFullscreen: true, subrole: "AXStandardWindow", titleIsEmpty: false)
    #expect(FullscreenClassifier.decide(state) == .show)
}

@Test func vivaldiStateEWindowedShowsRow() {
    let state = facts(isAppFullscreen: false, isBrowser: true)
    #expect(FullscreenClassifier.decide(state) == .show)
}

@Test func vivaldiStateFWindowedPlusVideoFullscreenShowsRow() {
    let state = facts(isAppFullscreen: true, isBrowser: true, axFullscreen: true, subrole: "AXStandardWindow", titleIsEmpty: false)
    #expect(FullscreenClassifier.decide(state) == .show)
}

@Test func vivaldiStateGWindowedPlusContainerDivFullscreenShowsRow() {
    let state = facts(isAppFullscreen: true, isBrowser: true, axFullscreen: true, subrole: "AXStandardWindow", titleIsEmpty: false)
    #expect(FullscreenClassifier.decide(state) == .show)
}

// MARK: - Native (non-browser) players — RESEARCH §2.5 / CONTEXT post-research decision

/// A chromeless/non-browser app in fullscreen suppresses on plain app-fullscreen alone — no AX
/// facts are consulted (isBrowser: false short-circuits before any AX field is examined).
@Test func nativePlayerFullscreenSuppressesRow() {
    let state = facts(isAppFullscreen: true, isBrowser: false)
    #expect(FullscreenClassifier.decide(state) == .suppress)
}

@Test func nativePlayerNotFullscreenShowsRow() {
    let state = facts(isAppFullscreen: false, isBrowser: false)
    #expect(FullscreenClassifier.decide(state) == .show)
}

// MARK: - AX unavailable / incomplete — fails toward showing (matches the Chromium policy)

@Test func browserFullscreenWithNoAXFactsAtAllShowsRow() {
    let state = facts(isAppFullscreen: true, isBrowser: true, axFullscreen: nil, subrole: nil, titleIsEmpty: nil)
    #expect(FullscreenClassifier.decide(state) == .show)
}

@Test func browserFullscreenWithAXFullscreenTrueButNilSubroleShowsRow() {
    let state = facts(isAppFullscreen: true, isBrowser: true, axFullscreen: true, subrole: nil, titleIsEmpty: true)
    #expect(FullscreenClassifier.decide(state) == .show)
}

@Test func browserFullscreenWhereFocusedWindowIsNotItselfFullscreenShowsRow() {
    let state = facts(isAppFullscreen: true, isBrowser: true, axFullscreen: false, subrole: "AXDialog", titleIsEmpty: true)
    #expect(FullscreenClassifier.decide(state) == .show)
}
