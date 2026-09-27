import Testing
@testable import MyIslandCore

// Ported per D-02 from .planning/sketches/006-design-round/index.html's openBand(kbd)/keydown
// handler (lines 334-344, 470-499) and 07-DESIGN-AGREEMENT.md §7.

@Test func hotkeyFocusesFirst() {
    var focus = BandFocus(moduleCount: 4)
    let effect = focus.hotkeyOpened()
    #expect(effect == .showDroplet(0))
    #expect(focus.zone == .band(0))
}

@Test func arrowsClampNoWrap() {
    var atStart = BandFocus(moduleCount: 4)
    _ = atStart.hotkeyOpened()
    let atStartEffect = atStart.arrowLeft()
    #expect(atStart.zone == .band(0))
    #expect(atStartEffect == .showDroplet(0))

    var atEnd = BandFocus(moduleCount: 4)
    _ = atEnd.hotkeyOpened()
    _ = atEnd.arrowRight()
    _ = atEnd.arrowRight()
    _ = atEnd.arrowRight()
    #expect(atEnd.zone == .band(3))
    let atEndEffect = atEnd.arrowRight()
    #expect(atEnd.zone == .band(3))
    #expect(atEndEffect == .showDroplet(3))

    var middle = BandFocus(moduleCount: 4)
    _ = middle.hotkeyOpened()
    _ = middle.arrowRight()
    let middleEffect = middle.arrowRight()
    #expect(middle.zone == .band(2))
    #expect(middle.pinned == 2)
    #expect(middleEffect == .showDroplet(2))
}

@Test func downEntersDroplet() {
    var withControls = BandFocus(moduleCount: 4)
    _ = withControls.hotkeyOpened()
    _ = withControls.arrowRight()
    _ = withControls.arrowRight()
    #expect(withControls.zone == .band(2))
    let effect = withControls.arrowDown(controlCount: 3)
    #expect(withControls.zone == .droplet(0))
    #expect(withControls.pinned == 2)
    #expect(effect == .showDroplet(2))

    var noControls = BandFocus(moduleCount: 4)
    _ = noControls.hotkeyOpened()
    _ = noControls.arrowRight()
    _ = noControls.arrowRight()
    let effect2 = noControls.arrowDown(controlCount: 0)
    #expect(noControls.zone == .band(2))
    #expect(effect2 == .showDroplet(2))
}

@Test func tabWrapsInDroplet() {
    var focus = BandFocus(moduleCount: 4)
    _ = focus.hotkeyOpened()
    _ = focus.arrowDown(controlCount: 3)
    #expect(focus.zone == .droplet(0))
    _ = focus.tab(backward: false, controlCount: 3)
    #expect(focus.zone == .droplet(1))
    _ = focus.tab(backward: false, controlCount: 3)
    #expect(focus.zone == .droplet(2))
    _ = focus.tab(backward: false, controlCount: 3)
    #expect(focus.zone == .droplet(0))

    var atStart = BandFocus(moduleCount: 4)
    _ = atStart.hotkeyOpened()
    _ = atStart.arrowDown(controlCount: 3)
    _ = atStart.tab(backward: true, controlCount: 3)
    #expect(atStart.zone == .droplet(2))

    var viaArrowDown = BandFocus(moduleCount: 4)
    _ = viaArrowDown.hotkeyOpened()
    _ = viaArrowDown.arrowDown(controlCount: 3)
    _ = viaArrowDown.arrowDown(controlCount: 3)
    #expect(viaArrowDown.zone == .droplet(1))
}

@Test func upFromFirstReturns() {
    var atFirst = BandFocus(moduleCount: 4)
    _ = atFirst.hotkeyOpened()
    _ = atFirst.arrowRight()
    _ = atFirst.arrowRight()
    _ = atFirst.arrowDown(controlCount: 3)
    #expect(atFirst.zone == .droplet(0))
    _ = atFirst.arrowUp(controlCount: 3)
    #expect(atFirst.zone == .band(2))

    var middle = BandFocus(moduleCount: 4)
    _ = middle.hotkeyOpened()
    _ = middle.arrowDown(controlCount: 3)
    _ = middle.tab(backward: false, controlCount: 3)
    _ = middle.tab(backward: false, controlCount: 3)
    #expect(middle.zone == .droplet(2))
    _ = middle.arrowUp(controlCount: 3)
    #expect(middle.zone == .droplet(1))
}

@Test func returnActs() {
    var band = BandFocus(moduleCount: 4)
    _ = band.hotkeyOpened()
    _ = band.arrowRight()
    #expect(band.zone == .band(1))
    #expect(band.returnKey() == .performGlyph(1))

    var droplet = BandFocus(moduleCount: 4)
    _ = droplet.hotkeyOpened()
    _ = droplet.arrowRight()
    _ = droplet.arrowRight()
    _ = droplet.arrowDown(controlCount: 3)
    _ = droplet.tab(backward: false, controlCount: 3)
    _ = droplet.tab(backward: false, controlCount: 3)
    #expect(droplet.zone == .droplet(2))
    #expect(droplet.returnKey() == .pressControl(2))
}

@Test func escapeChain() {
    var fromDroplet = BandFocus(moduleCount: 4)
    _ = fromDroplet.hotkeyOpened()
    _ = fromDroplet.arrowDown(controlCount: 3)
    #expect(fromDroplet.zone == .droplet(0))
    let e1 = fromDroplet.escape()
    #expect(e1 == .none)
    #expect(fromDroplet.zone == .band(0))

    var noDropletShowing = BandFocus(moduleCount: 4)
    _ = noDropletShowing.hotkeyOpened()
    let firstEscape = noDropletShowing.escape()
    #expect(firstEscape == .closeDroplet)
    #expect(noDropletShowing.pinned == nil)
    #expect(noDropletShowing.showing == nil)
    let secondEscape = noDropletShowing.escape()
    #expect(secondEscape == .closeBand)
    #expect(noDropletShowing.zone == nil)
}

@Test func pointerEndsKeyboard() {
    var focus = BandFocus(moduleCount: 4)
    _ = focus.hotkeyOpened()
    let effect = focus.pointerMoved()
    #expect(effect == .none)
    #expect(focus.zone == nil)
}

@Test func moduleCountShrinkClamps() {
    var focus = BandFocus(moduleCount: 4)
    _ = focus.hotkeyOpened()
    _ = focus.arrowRight()
    _ = focus.arrowRight()
    _ = focus.arrowRight()
    #expect(focus.zone == .band(3))
    #expect(focus.pinned == 3)
    _ = focus.moduleCountChanged(2)
    #expect(focus.zone == .band(1))
    #expect(focus.pinned == 1)
}

// F1 (07-DESIGN-AGREEMENT.md §4): one key, one visible result — a control never also collapses
// anything. Structurally guaranteed by Effect being a single-case return value; this asserts the
// specific case a naive port could get wrong (an at-limit arrow closing instead of re-showing).
@Test func oneEffectPerKey() {
    var focus = BandFocus(moduleCount: 1)
    let opened = focus.hotkeyOpened()
    #expect(opened == .showDroplet(0))

    let clampedLeft = focus.arrowLeft()
    #expect(clampedLeft == .showDroplet(0))
    #expect(clampedLeft != .closeBand)

    let clampedRight = focus.arrowRight()
    #expect(clampedRight == .showDroplet(0))
    #expect(clampedRight != .closeBand)
}
