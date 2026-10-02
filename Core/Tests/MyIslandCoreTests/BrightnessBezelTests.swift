import Testing
import Foundation
@testable import MyIslandCore

private func data1(code: Int, state: Int, repeatBit: Int = 0) -> Int {
    (code << 16) | (state << 8) | repeatBit
}

private let shift: UInt64 = 0x20000
private let control: UInt64 = 0x40000
private let option: UInt64 = 0x80000
private let command: UInt64 = 0x100000

/// HUD-04: brightness-up key-down, no modifier.
@Test func brightnessKeyDecodeUpKeyDown() {
    let event = BrightnessKey.decode(subtype: 8, data1: data1(code: 2, state: 0x0A), flags: 0)
    #expect(event == BrightnessKey.Event(up: true, isDown: true, isRepeat: false, fine: false))
}

@Test func brightnessKeyDecodeDownKeyDown() {
    let event = BrightnessKey.decode(subtype: 8, data1: data1(code: 3, state: 0x0A), flags: 0)
    #expect(event?.up == false)
}

@Test func brightnessKeyDecodeKeyUpIsDecodedNotNil() {
    let event = BrightnessKey.decode(subtype: 8, data1: data1(code: 2, state: 0x0B), flags: 0)
    #expect(event?.isDown == false)
}

@Test func brightnessKeyDecodeRepeatBit() {
    let event = BrightnessKey.decode(subtype: 8, data1: data1(code: 3, state: 0x0A, repeatBit: 1), flags: 0)
    #expect(event?.isRepeat == true)
}

@Test func brightnessKeyDecodeRejectsOtherSubtype() {
    #expect(BrightnessKey.decode(subtype: 7, data1: data1(code: 2, state: 0x0A), flags: 0) == nil)
}

@Test func brightnessKeyDecodeRejectsOtherMediaKeys() {
    for code in [0, 1, 7, 16] {
        #expect(BrightnessKey.decode(subtype: 8, data1: data1(code: code, state: 0x0A), flags: 0) == nil)
    }
}

@Test func brightnessKeyDecodeRejectsUnknownState() {
    #expect(BrightnessKey.decode(subtype: 8, data1: data1(code: 2, state: 0x0C), flags: 0) == nil)
}

@Test func brightnessKeyDecodeAcceptsShiftAsStandardStep() {
    let event = BrightnessKey.decode(subtype: 8, data1: data1(code: 2, state: 0x0A), flags: shift)
    #expect(event?.fine == false)
}

@Test func brightnessKeyDecodeOptionShiftIsFine() {
    let event = BrightnessKey.decode(subtype: 8, data1: data1(code: 2, state: 0x0A), flags: option | shift)
    #expect(event?.fine == true)
}

@Test func brightnessKeyDecodeRejectsCommandControlOptionAlone() {
    for flags in [command, control, option, command | shift] {
        #expect(BrightnessKey.decode(subtype: 8, data1: data1(code: 2, state: 0x0A), flags: flags) == nil)
    }
}

@Test func brightnessKeyDecodeIgnoresNonModifierFlags() {
    let event = BrightnessKey.decode(subtype: 8, data1: data1(code: 3, state: 0x0A), flags: 0x800000 | 0x10000 | 0x100)
    #expect(event != nil)
}

/// RESEARCH Open Question 1: 16 presses from the bottom rail reach the top rail.
@Test func brightnessKeyNextLevelSixteenUpsFromZeroReachOne() {
    var level: Float = 0
    for _ in 0..<16 { level = BrightnessKey.nextLevel(current: level, up: true, fine: false) }
    #expect(level == 1)
}

@Test func brightnessKeyNextLevelClampsAtOne() {
    #expect(BrightnessKey.nextLevel(current: 1, up: true, fine: false) == 1)
}

@Test func brightnessKeyNextLevelClampsAtZero() {
    #expect(BrightnessKey.nextLevel(current: 0, up: false, fine: false) == 0)
}

@Test func brightnessKeyNextLevelSnapsOffGrid() {
    #expect(BrightnessKey.nextLevel(current: 0.53, up: true, fine: false) == 0.5625)
    #expect(BrightnessKey.nextLevel(current: 0.53, up: false, fine: false) == 0.4375)
}

@Test func brightnessKeyNextLevelFineStep() {
    #expect(BrightnessKey.nextLevel(current: 0.5, up: true, fine: true) == 0.515625)
}

/// HUD-03/04: the Settings and launch state function.
@Test func brightnessBezelStateResolve() {
    #expect(BrightnessBezelState.resolve(enabled: false, trusted: true, tapActive: true) == .off)
    #expect(BrightnessBezelState.resolve(enabled: false, trusted: false, tapActive: false) == .off)
    #expect(BrightnessBezelState.resolve(enabled: true, trusted: false, tapActive: false) == .needsAccessibility)
    #expect(BrightnessBezelState.resolve(enabled: true, trusted: true, tapActive: true) == .active)
    #expect(BrightnessBezelState.resolve(enabled: true, trusted: true, tapActive: false) == .failed)
}
