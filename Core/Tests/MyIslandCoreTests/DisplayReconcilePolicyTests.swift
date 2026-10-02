import CoreGraphics
import Testing
@testable import MyIslandCore

private func geometry(
    screen: CGRect = CGRect(x: 0, y: 0, width: 2560, height: 1080),
    anchor: CGRect = CGRect(x: 1181.5, y: 1054, width: 197, height: 26),
    isPhysical: Bool = false,
    menuBar: CGFloat = 24
) -> DisplayGeometry {
    DisplayGeometry(screenFrame: screen, anchorRect: anchor, isPhysical: isPhysical, menuBarHeight: menuBar)
}

@Test func reconcileIdenticalKeeps() {
    #expect(DisplayReconcilePolicy.decide(previous: geometry(), current: geometry()) == .keep)
}

@Test func reconcilePureTranslationKeeps() {
    let previous = geometry()
    let current = geometry(
        screen: CGRect(x: 640, y: -323, width: 2560, height: 1080),
        anchor: CGRect(x: 1821.5, y: 731, width: 197, height: 26)
    )
    #expect(DisplayReconcilePolicy.decide(previous: previous, current: current) == .keep)
}

@Test func reconcileBuiltInShiftedByDellResizeKeeps() {
    let previous = geometry(
        screen: CGRect(x: 416, y: -1117, width: 1728, height: 1117),
        anchor: CGRect(x: 1176, y: -1117 + 1117 - 32, width: 192, height: 32),
        isPhysical: true, menuBar: 33
    )
    let current = geometry(
        screen: CGRect(x: 1056, y: -1117, width: 1728, height: 1117),
        anchor: CGRect(x: 1816, y: -1117 + 1117 - 32, width: 192, height: 32),
        isPhysical: true, menuBar: 33
    )
    #expect(DisplayReconcilePolicy.decide(previous: previous, current: current) == .keep)
}

@Test func reconcileSizeChangeRebuilds() {
    let current = geometry(screen: CGRect(x: 0, y: 0, width: 3840, height: 1620))
    #expect(DisplayReconcilePolicy.decide(previous: geometry(), current: current) == .rebuild(.size))
}

@Test func reconcileAnchorMovedRelativeRebuilds() {
    let current = geometry(anchor: CGRect(x: 1160, y: 1054, width: 240, height: 26))
    #expect(DisplayReconcilePolicy.decide(previous: geometry(), current: current) == .rebuild(.anchor))
}

@Test func reconcileModeFlipRebuilds() {
    let previous = geometry(isPhysical: true)
    let current = geometry(isPhysical: false)
    #expect(DisplayReconcilePolicy.decide(previous: previous, current: current) == .rebuild(.mode))
}

@Test func reconcileMenuBarChangeRebuilds() {
    let previous = geometry(menuBar: 33)
    let current = geometry(menuBar: 24)
    #expect(DisplayReconcilePolicy.decide(previous: previous, current: current) == .rebuild(.menuBar))
}

@Test func reconcileFirstRealMenuBarAfterZeroRebuilds() {
    let previous = geometry(menuBar: 0)
    let current = geometry(menuBar: 33)
    #expect(DisplayReconcilePolicy.decide(previous: previous, current: current) == .rebuild(.menuBar))
}

@Test func reconcileTransientZeroMenuBarKeeps() {
    let previous = geometry(menuBar: 33)
    let current = geometry(menuBar: 0)
    #expect(DisplayReconcilePolicy.decide(previous: previous, current: current) == .keep)
}
