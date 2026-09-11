import Testing
@testable import MyIslandCore

@Test func diffFromEmptyAddsEverything() {
    let diff = DisplaySetDiff(previous: [], current: ["B", "A"])
    #expect(diff.added == ["A", "B"])
    #expect(diff.removed == [])
    #expect(diff.kept == [])
}

@Test func diffToEmptyRemovesEverything() {
    let diff = DisplaySetDiff(previous: ["A", "B"], current: [])
    #expect(diff.added == [])
    #expect(diff.removed == ["A", "B"])
    #expect(diff.kept == [])
}

@Test func diffOfTwoEmptySetsIsEmpty() {
    let diff = DisplaySetDiff(previous: [], current: [])
    #expect(diff.added == [])
    #expect(diff.removed == [])
    #expect(diff.kept == [])
}

/// Idempotency: a repeated reconcile over an unchanged screen set names nothing to create or
/// close (SHELL-10).
@Test func diffOfIdenticalSetsKeepsAll() {
    let diff = DisplaySetDiff(previous: ["A"], current: ["A"])
    #expect(diff.added == [])
    #expect(diff.removed == [])
    #expect(diff.kept == ["A"])
}

@Test func diffMixed() {
    let diff = DisplaySetDiff(previous: ["A", "B"], current: ["B", "C"])
    #expect(diff.added == ["C"])
    #expect(diff.removed == ["A"])
    #expect(diff.kept == ["B"])
}

/// Output is sorted lexicographically by key string regardless of `NSScreen.screens` order or
/// `Set` iteration order.
@Test func outputIsSortedRegardlessOfInsertionOrder() {
    let diff = DisplaySetDiff(previous: ["Z", "M", "A"], current: ["M", "A", "Z", "0"])
    #expect(diff.added == ["0"])
    #expect(diff.removed == [])
    #expect(diff.kept == ["A", "M", "Z"])
}

@Test func equatable() {
    let a = DisplaySetDiff(previous: ["A", "B"], current: ["B", "C"])
    let b = DisplaySetDiff(previous: ["A", "B"], current: ["B", "C"])
    #expect(a == b)
}
