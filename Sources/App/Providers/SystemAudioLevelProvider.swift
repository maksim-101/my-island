import CoreAudio
import AudioToolbox
import Foundation
import OSLog
import MyIslandCore

// Gain applied to raw RMS (music RMS sits well below 1.0) and per-frame peak decay. File-scope so the
// audio-thread and timer closures reference them without crossing `@MainActor` isolation.
private let audioLevelGain: Float = 6
private let audioLevelDecay: Float = 0.82

/// Shared meter written by the real-time IOProc, read by the main-thread sampler. `callbacks` counts
/// IOProc invocations since the last sample so the diagnostic can tell "clock never ran" (0) apart
/// from "running but silent" (>0, rms≈0).
private struct AudioMeter {
    var rms: Float = 0
    var callbacks: Int = 0
}

/// Live system-audio output level for the collapsed-notch sound-wave. macOS 14.4+ Core Audio
/// process-tap API: a private global mixdown tap plus the default OUTPUT device (as the aggregate's
/// main sub-device / clock — without it the IOProc gets empty buffers) wrapped in a throwaway
/// aggregate device whose IOProc computes output RMS. RMS is written on the audio thread via an
/// `OSAllocatedUnfairLock` (never touching this `@MainActor` instance) and sampled by a main-thread
/// timer into the observed `level` (0…1, gain-scaled + peak-decay-smoothed). Silence → `level` decays
/// to 0 → flat, still bars (so it never animates while paused). Started only while the wave is on
/// screen; every CA call is checked and any failure leaves `level` at 0 rather than crashing.
@MainActor
@Observable
final class SystemAudioLevelProvider {
    /// Smoothed 0…1 output level the sound-wave reads. 0 when silent, stopped, or the tap failed.
    private(set) var level: Float = 0

    private let meter = OSAllocatedUnfairLock<AudioMeter>(initialState: AudioMeter())

    // Core Audio resource handles + the sampler timer. `nonisolated(unsafe)` so the nonisolated
    // `deinit` can tear them down (mirrors the codebase's timer convention); only ever mutated on the
    // main actor in start()/stop().
    nonisolated(unsafe) private var tapID: AudioObjectID = kAudioObjectUnknown
    nonisolated(unsafe) private var aggregateID: AudioObjectID = kAudioObjectUnknown
    nonisolated(unsafe) private var ioProcID: AudioDeviceIOProcID?
    nonisolated(unsafe) private var sampleTimer: Timer?
    private var diagTick = 0

    private let logger = Logger(subsystem: AppIdentity.bundleID, category: "SystemAudioLevel")

    func start() {
        guard tapID == kAudioObjectUnknown else { return }

        // 1. Private global mixdown tap of all process audio, unmuted so playback is unaffected.
        let tapDescription = CATapDescription(monoGlobalTapButExcludeProcesses: [])
        tapDescription.isPrivate = true
        tapDescription.muteBehavior = .unmuted

        var tap = kAudioObjectUnknown
        let tapErr = AudioHardwareCreateProcessTap(tapDescription, &tap)
        guard tapErr == noErr, tap != kAudioObjectUnknown else {
            logger.error("Audio tap create failed (status=\(tapErr, privacy: .public)) — sound-wave stays flat")
            return
        }
        tapID = tap

        // 2. Aggregate device: the default OUTPUT device as the main/clock sub-device PLUS the tap.
        // The output sub-device is what gives the aggregate a running clock so the IOProc actually
        // fires with the tapped mixdown — a tap-only aggregate stays silent.
        var subDeviceList: [[String: Any]] = []
        var mainKV: [String: Any] = [:]
        if let outUID = Self.defaultOutputDeviceUID() {
            subDeviceList = [[kAudioSubDeviceUIDKey: outUID]]
            mainKV[kAudioAggregateDeviceMainSubDeviceKey] = outUID
        } else {
            logger.error("No default output device UID — aggregate may not clock")
        }
        let aggUID = "com.maksim101.myisland.audiotap.\(tapDescription.uuid.uuidString)"
        var aggDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "my-island Level Tap",
            kAudioAggregateDeviceUIDKey: aggUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: subDeviceList,
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: tapDescription.uuid.uuidString,
                ]
            ],
        ]
        aggDescription.merge(mainKV) { _, new in new }

        var agg = kAudioObjectUnknown
        let aggErr = AudioHardwareCreateAggregateDevice(aggDescription as CFDictionary, &agg)
        guard aggErr == noErr, agg != kAudioObjectUnknown else {
            logger.error("Aggregate device create failed (status=\(aggErr, privacy: .public))")
            teardown()
            return
        }
        aggregateID = agg

        // 3. IOProc built in a NONISOLATED context (a MainActor-isolated closure trips
        // swift_task_checkIsolated → SIGTRAP when CoreAudio calls it on the audio thread).
        let queue = DispatchQueue(label: "com.maksim101.myisland.audiolevel", qos: .userInitiated)
        var proc: AudioDeviceIOProcID?
        let ioErr = AudioDeviceCreateIOProcIDWithBlock(&proc, agg, queue, Self.makeRMSBlock(meter: meter))
        guard ioErr == noErr, let proc else {
            logger.error("IOProc create failed (status=\(ioErr, privacy: .public))")
            teardown()
            return
        }
        ioProcID = proc

        let startErr = AudioDeviceStart(agg, proc)
        guard startErr == noErr else {
            logger.error("AudioDeviceStart failed (status=\(startErr, privacy: .public))")
            teardown()
            return
        }

        // 4. Main-thread sampler → observed `level` with gain + peak-decay smoothing.
        diagTick = 0
        sampleTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
        logger.notice("System audio level tap started")
    }

    private func sample() {
        let m = meter.withLock { current -> AudioMeter in
            let snapshot = current
            current.callbacks = 0
            return snapshot
        }
        let scaled = min(1, m.rms * audioLevelGain)
        level = max(scaled, level * audioLevelDecay)

        // ~1s diagnostic: is the IOProc firing at all, and is it silence vs. signal?
        diagTick += 1
        if diagTick >= 30 {
            diagTick = 0
            logger.notice("audio meter — callbacks/s=\(m.callbacks, privacy: .public) rms=\(m.rms, privacy: .public) level=\(self.level, privacy: .public)")
        }
    }

    func stop() {
        sampleTimer?.invalidate()
        sampleTimer = nil
        teardown()
        level = 0
        meter.withLock { $0 = AudioMeter() }
    }

    private func teardown() {
        Self.destroy(tapID: tapID, aggregateID: aggregateID, ioProcID: ioProcID)
        ioProcID = nil
        aggregateID = kAudioObjectUnknown
        tapID = kAudioObjectUnknown
    }

    /// Builds the real-time IOProc block in a NONISOLATED context so it carries no MainActor
    /// isolation — captures only the `Sendable` lock.
    nonisolated private static func makeRMSBlock(meter: OSAllocatedUnfairLock<AudioMeter>) -> AudioDeviceIOBlock {
        { _, inInputData, _, _, _ in
            let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
            var sumSquares: Float = 0
            var count = 0
            for buffer in abl {
                guard let base = buffer.mData else { continue }
                let n = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                let samples = base.assumingMemoryBound(to: Float.self)
                var i = 0
                while i < n { let s = samples[i]; sumSquares += s * s; i += 1 }
                count += n
            }
            let rms = count > 0 ? (sumSquares / Float(count)).squareRoot() : 0
            meter.withLock { $0.rms = rms; $0.callbacks += 1 }
        }
    }

    /// Reads the default output device's UID (used as the aggregate's clock sub-device). Nonisolated —
    /// pure Core Audio HAL reads, no actor state.
    nonisolated private static func defaultOutputDeviceUID() -> String? {
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID) == noErr,
              deviceID != kAudioObjectUnknown else { return nil }

        var uid: CFString?
        var uidSize = UInt32(MemoryLayout<CFString?>.size)
        var uidAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let err = withUnsafeMutablePointer(to: &uid) {
            AudioObjectGetPropertyData(deviceID, &uidAddr, 0, nil, &uidSize, $0)
        }
        guard err == noErr else { return nil }
        return uid as String?
    }

    /// Pure C-API teardown, callable from the nonisolated `deinit` as well as `teardown()`.
    nonisolated private static func destroy(tapID: AudioObjectID, aggregateID: AudioObjectID, ioProcID: AudioDeviceIOProcID?) {
        if let ioProcID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
    }

    deinit {
        sampleTimer?.invalidate()
        Self.destroy(tapID: tapID, aggregateID: aggregateID, ioProcID: ioProcID)
    }
}
