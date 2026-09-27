import Foundation
import Testing
@testable import MyIslandCore

/// 07-05 Task 2 (PANEL-07): `AlertDropLayout.hud`/`.meeting` port `extraSize`/`bumpHalf`
/// (index.html:376-389) verbatim — RED phase, written against the plan's own `<behavior>` spec
/// before `AlertDropLayout.swift` exists.
private let tolerance: CGFloat = 1e-9

@Test func hudSizes() {
    let physical = AlertDropLayout.hud(isPhysical: true)
    #expect(physical.halfWidth == 80)
    #expect(physical.height == 22)

    let synthetic = AlertDropLayout.hud(isPhysical: false)
    #expect(synthetic.halfWidth == 70)
    #expect(synthetic.height == 22)
}

@Test func shortTitleUsesMinimum() {
    let physical = AlertDropLayout.meeting(leadWidth: 30, titleWidth: 40, hasJoin: true, isPhysical: true)
    #expect(physical.halfWidth == 100)
    #expect(physical.height == 30)
    #expect(physical.twoLines == false)

    let synthetic = AlertDropLayout.meeting(leadWidth: 30, titleWidth: 40, hasJoin: true, isPhysical: false)
    #expect(synthetic.halfWidth == 90)
}

@Test func midTitleFollowsInner() {
    let result = AlertDropLayout.meeting(leadWidth: 30, titleWidth: 200, hasJoin: true, isPhysical: true)
    #expect(abs(result.halfWidth - 159.5) < tolerance)
    #expect(result.twoLines == false)
}

@Test func capAt210() {
    let result = AlertDropLayout.meeting(leadWidth: 30, titleWidth: 380, hasJoin: true, isPhysical: true)
    #expect(result.halfWidth == 210)
    #expect(result.twoLines == true)
    #expect(result.height == 44)
}

@Test func twoLinesBoundary() {
    // Both drive half to exactly 210 (an oversized leadWidth pushes inner past the cap
    // regardless of titleWidth) so only the titleWidth > 310 test decides `twoLines`.
    let atBoundary = AlertDropLayout.meeting(leadWidth: 300, titleWidth: 310, hasJoin: true, isPhysical: true)
    #expect(atBoundary.halfWidth == 210)
    #expect(atBoundary.twoLines == false)

    let pastBoundary = AlertDropLayout.meeting(leadWidth: 300, titleWidth: 310.5, hasJoin: true, isPhysical: true)
    #expect(pastBoundary.halfWidth == 210)
    #expect(pastBoundary.twoLines == true)
}

@Test func noJoinShrinks() {
    let withJoin = AlertDropLayout.meeting(leadWidth: 30, titleWidth: 200, hasJoin: true, isPhysical: true)
    let withoutJoin = AlertDropLayout.meeting(leadWidth: 30, titleWidth: 200, hasJoin: false, isPhysical: true)
    #expect(abs((withJoin.halfWidth - withoutJoin.halfWidth) - 24.5) < tolerance)
}
