import CoreAudio
import AudioToolbox
import Foundation
import OSLog
import MyIslandCore

// Gain applied to raw RMS (music RMS sits well below 1.0) and per-frame peak decay. File-scope so the
// audio-thread and timer closures reference them without crossing `@MainActor` isolation.
private let audioLevelGain: Float = 6
private let audioLevelDecay: Float = 0.82

/// Live system-audio output level for the collapsed-notch sound-wave (replaces the earlier decorative
/// sinusoid). Uses the macOS 14.4+ Core Audio process-tap API: a private global mixdown tap wrapped
/// in a throwaway aggregate device whose IOProc computes RMS off the real output samples. The RMS is
/// written on the audio thread into an `OSAllocatedUnfairLock` (never touching this `@MainActor`
/// instance from the real-time callback) and sampled by a main-thread timer into the observed
/// `level` (0…1, gain-scaled + peak-decay-smoothed). When nothing is playing the samples are silent,
/// so `level` decays to 0 and the bars go flat — which is exactly the "don't animate while paused"
/// behavior. Started only while the wave is on screen (music playing, no timer) and stopped when it
/// leaves, so the tap never runs at idle. Every Core Audio call is defensively checked; any failure
/// leaves `level` at 0 (flat bars) rather than crashing — this is a private, undocumented-adjacent
/// API and treated as best-effort, same risk class as MediaRemote.
@MainActor
@Observable
final class SystemAudioLevelProvider {
    /// Smoothed 0…1 output level the sound-wave reads. 0 when silent, stopped, or the tap failed.
    private(set) var level: Float = 0

    /// RMS written by the real-time IOProc, read by the main-thread sampler. `OSAllocatedUnfairLock`
    /// is `Sendable`, so the audio-thread block captures ONLY this — never `self`.
    private let sharedRMS = OSAllocatedUnfairLock<Float>(initialState: 0)

    // Core Audio resource handles + the sampler timer. `nonisolated(unsafe)` so the nonisolated
    // `deinit` can tear them down (mirrors `CalendarProvider`/`NowPlayingProvider`'s timer convention);
    // they are only ever mutated on the main actor in start()/stop().
    nonisolated(unsafe) private var tapID: AudioObjectID = kAudioObjectUnknown
    nonisolated(unsafe) private var aggregateID: AudioObjectID = kAudioObjectUnknown
    nonisolated(unsafe) private var ioProcID: AudioDeviceIOProcID?
    nonisolated(unsafe) private var sampleTimer: Timer?

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

        // 2. Private aggregate device wrapping just that tap; auto-starts the tap.
        let aggUID = "com.maksim101.myisland.audiotap.\(tapDescription.uuid.uuidString)"
        let aggDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "my-island Level Tap",
            kAudioAggregateDeviceUIDKey: aggUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: tapDescription.uuid.uuidString,
                ]
            ],
        ]

        var agg = kAudioObjectUnknown
        let aggErr = AudioHardwareCreateAggregateDevice(aggDescription as CFDictionary, &agg)
        guard aggErr == noErr, agg != kAudioObjectUnknown else {
            logger.error("Aggregate device create failed (status=\(aggErr, privacy: .public))")
            teardown()
            return
        }
        aggregateID = agg

        // 3. IOProc: compute RMS off the tapped samples on the audio thread; store via the lock only.
        // The block MUST be built in a nonisolated context (see `makeRMSBlock`) — a closure written
        // inline in this @MainActor method inherits MainActor isolation, and CoreAudio invoking it on
        // the real-time audio IOThread then trips `swift_task_checkIsolated` → SIGTRAP (UAT crash).
        let queue = DispatchQueue(label: "com.maksim101.myisland.audiolevel", qos: .userInitiated)
        var proc: AudioDeviceIOProcID?
        let ioErr = AudioDeviceCreateIOProcIDWithBlock(&proc, agg, queue, Self.makeRMSBlock(lock: sharedRMS))
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

        // 4. Main-thread sampler → observed `level` with gain + peak-decay smoothing. The block only
        // reads the Sendable lock and hops to the main actor to touch `level` (codebase Timer idiom).
        sampleTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let rms = self.sharedRMS.withLock { $0 }
                let scaled = min(1, rms * audioLevelGain)
                self.level = max(scaled, self.level * audioLevelDecay)
            }
        }
        logger.notice("System audio level tap started")
    }

    func stop() {
        sampleTimer?.invalidate()
        sampleTimer = nil
        teardown()
        level = 0
        sharedRMS.withLock { $0 = 0 }
    }

    private func teardown() {
        Self.destroy(tapID: tapID, aggregateID: aggregateID, ioProcID: ioProcID)
        ioProcID = nil
        aggregateID = kAudioObjectUnknown
        tapID = kAudioObjectUnknown
    }

    /// Builds the real-time IOProc block in a NONISOLATED context so it carries no MainActor
    /// isolation — captures only the `Sendable` lock, so CoreAudio can safely call it on the audio
    /// thread without tripping the Swift executor-isolation assertion (SIGTRAP).
    nonisolated private static func makeRMSBlock(lock: OSAllocatedUnfairLock<Float>) -> AudioDeviceIOBlock {
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
            lock.withLock { $0 = rms }
        }
    }

    /// Pure C-API teardown, callable from the nonisolated `deinit` as well as `teardown()` — so a
    /// dropped provider never leaks its aggregate device / tap.
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
