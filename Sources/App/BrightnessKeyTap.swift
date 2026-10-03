import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import Observation
import MyIslandCore

/// Active session tap that lets my-island own the brightness keys (HUD-03, HUD-04).
///
/// Shape adapted from the MIT-licensed BrightBoi `RealKeyTap.swift` / `KeyTapMatching.swift`
/// (joaodavidsilva/brightboi) and MonitorControl's `MediaKeyTap`, both read as references only.
///
/// The production mask selects system-defined events (type 14) only, so no keystroke reaches the
/// callback. "Limited to the two brightness keys" is the callback's decode filter: every other
/// media key and every non-matching event is returned unread. A press is swallowed only after
/// `apply` reported that my-island changed the brightness itself, so the key never goes dead.
///
/// The trust state is read silently with `AXIsProcessTrusted()`; this class never calls the
/// prompting API (the prompt belongs to the Settings toggle, plan 08-02).
@MainActor
@Observable
final class BrightnessKeyTap {
    static let systemDefinedType = 14
    static let keyDownType = 10
    static let productionMask = CGEventMask(1 << 14)
    static let probeMask = productionMask | CGEventMask(1 << 10)
    static let probeKey = "MyIslandKeyProbe"
    static let timeoutSelfTestKey = "MyIslandTapTimeoutSelfTest"

    private(set) var state: BrightnessBezelState = .off

    @ObservationIgnored var apply: ((BrightnessKey.Event) -> Bool)?
    @ObservationIgnored private var tap: CFMachPort?
    @ObservationIgnored private var source: CFRunLoopSource?
    @ObservationIgnored private var probeEnabled = false
    @ObservationIgnored private var installFailedLogged = false
    @ObservationIgnored private var lastLoggedState: BrightnessBezelState?
    @ObservationIgnored private var lastEnabled = false
    @ObservationIgnored private var lastApplied: TimeInterval?
    /// Directions (`up`) whose latest key-down this tap swallowed; their key-up is swallowed too.
    @ObservationIgnored private var swallowedDirections: Set<Bool> = []
    @ObservationIgnored private var selfTestArmed = false
    @ObservationIgnored private var selfTestConsumed = false
    private let logger = AppLog.make("BrightnessKeyTap")

    func reconcile(enabled: Bool) {
        lastEnabled = enabled
        let trusted = AXIsProcessTrusted()
        if enabled && trusted && tap == nil { install() }
        if (!enabled || !trusted) && tap != nil { remove() }

        let tapActive = tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false
        state = BrightnessBezelState.resolve(enabled: enabled, trusted: trusted, tapActive: tapActive)
        if state != lastLoggedState {
            lastLoggedState = state
            logger.notice("brightnessBezel state=\(self.state.rawValue, privacy: .public) enabled=\(enabled, privacy: .public) trusted=\(trusted, privacy: .public)")
        }
    }

    private func install() {
        probeEnabled = UserDefaults.standard.bool(forKey: Self.probeKey)
        selfTestArmed = !selfTestConsumed && UserDefaults.standard.bool(forKey: Self.timeoutSelfTestKey)
        lastApplied = nil
        swallowedDirections = []
        let mask = probeEnabled ? Self.probeMask : Self.productionMask
        guard let created = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, cgEvent, refcon in
                guard let refcon else { return Unmanaged.passUnretained(cgEvent) }
                let owner = Unmanaged<BrightnessKeyTap>.fromOpaque(refcon).takeUnretainedValue()
                var result: Unmanaged<CGEvent>?
                MainActor.assumeIsolated { result = owner.handle(type: type, event: cgEvent) }
                return result
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            if !installFailedLogged {
                installFailedLogged = true
                logger.notice("brightnessTap installFailed")
            }
            return
        }
        tap = created
        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0)
        source = runLoopSource
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: created, enable: true)
        logger.notice("brightnessTap installed enabled=\(CGEvent.tapIsEnabled(tap: created), privacy: .public)")
        if probeEnabled { logTapOwners() }
    }

    private func remove() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let passThrough = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            reArm(reason: type == .tapDisabledByTimeout ? "timeout" : "userInput")
            return passThrough
        }
        guard type.rawValue == UInt32(Self.systemDefinedType) else {
            if probeEnabled, type == .keyDown {
                let code = event.getIntegerValueField(.keyboardEventKeycode)
                if code == 144 || code == 145 { logger.notice("keyProbe type=keyDown code=\(code, privacy: .public)") }
            }
            return passThrough
        }
        guard let nsEvent = NSEvent(cgEvent: event) else { return passThrough }
        let subtype = nsEvent.subtype.rawValue
        let data1 = nsEvent.data1

        if probeEnabled, subtype == BrightnessKey.auxControlButtonsSubtype {
            let code = (data1 & 0xFFFF0000) >> 16
            if code == BrightnessKey.brightnessUpCode || code == BrightnessKey.brightnessDownCode {
                let keyState = (data1 & 0xFF00) >> 8
                logger.notice("keyProbe type=14 subtype=8 code=\(code, privacy: .public) state=\(String(keyState, radix: 16), privacy: .public) repeat=\(data1 & 1 != 0, privacy: .public)")
            }
        }

        guard let raw = BrightnessKey.decodeIgnoringModifiers(subtype: subtype, data1: data1) else { return passThrough }
        guard raw.isDown else {
            return swallowedDirections.remove(raw.up) != nil ? nil : passThrough
        }
        guard let press = BrightnessKey.decode(subtype: subtype, data1: data1, flags: event.flags.rawValue) else {
            return raw.isRepeat && swallowedDirections.contains(raw.up) ? nil : passThrough
        }

        let now = ProcessInfo.processInfo.systemUptime
        if swallowedDirections.contains(press.up),
           BrightnessKey.isThrottled(isRepeat: press.isRepeat, now: now, lastApplied: lastApplied) {
            return nil
        }
        if selfTestArmed {
            selfTestArmed = false
            selfTestConsumed = true
            Thread.sleep(forTimeInterval: 2.0)
            logger.notice("brightnessTap selfTest stalled=2.0s")
        }
        let applied = apply?(press) == true
        logger.notice("brightnessTap press up=\(press.up, privacy: .public) fine=\(press.fine, privacy: .public) applied=\(applied, privacy: .public)")
        if applied {
            lastApplied = now
            swallowedDirections.insert(press.up)
            return nil
        }
        swallowedDirections.remove(press.up)
        return passThrough
    }

    /// The system disables a tap whose callback stalled or that was displaced by user input; a
    /// disabled-but-registered tap would leave the keys dead (RESEARCH Pitfall 3).
    private func reArm(reason: String) {
        guard AXIsProcessTrusted() else {
            logger.notice("brightnessTap removed reason=untrusted")
            let enabled = lastEnabled
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.reconcile(enabled: enabled) }
            }
            return
        }
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        let enabled = tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false
        logger.notice("brightnessTap reArmed reason=\(reason, privacy: .public) enabled=\(enabled, privacy: .public)")
    }

    private func logTapOwners() {
        var infos = [CGEventTapInformation](repeating: CGEventTapInformation(), count: 64)
        var count: UInt32 = 0
        guard CGGetEventTapList(UInt32(infos.count), &infos, &count) == .success else { return }
        let sysdefinedBit = Self.productionMask
        let pids = infos.prefix(Int(count))
            .filter { $0.eventsOfInterest & sysdefinedBit != 0 }
            .map { String($0.tappingProcess) }
            .joined(separator: ",")
        logger.notice("keyProbe taps total=\(count, privacy: .public) sysdefinedPids=\(pids, privacy: .public)")
    }
}
