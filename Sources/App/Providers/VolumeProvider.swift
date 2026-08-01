import CoreAudio
import AudioToolbox
import MyIslandCore

/// Observes the default output device's volume/mute via the public,
/// documented CoreAudio `AudioObjectAddPropertyListenerBlock` API (HUD-02).
/// Registers once in `init` and re-registers volume/mute listeners against the new device
/// whenever the default output device changes (e.g. headphones plugged in) — always removing the
/// previous device's listeners first (RESEARCH Pitfall 5: registration is additive, so every
/// device change used to leave the old listener pair live, re-arming the HUD fade N times).
///
/// Which property actually carries the volume is resolved per device via `VolumeSource`
/// (RESEARCH §1.3): `VirtualMainVolume` when supported, else `VolumeScalar` on the main element,
/// else the mean of whatever per-channel scalars are supported, else `nil` — a device with none of
/// these hides the row instead of showing the previous device's stale value (T-7h2, "a stale
/// reading is exactly what drift looks like").
@MainActor
final class VolumeProvider {
    /// `nil` == this device exposes no readable volume property — the caller must hide the row.
    private(set) var level: Float?
    private(set) var isMuted: Bool = false
    var onChange: (() -> Void)?

    private var deviceID: AudioDeviceID = kAudioObjectUnknown
    private var volumeSource: VolumeSource = .unsupported

    private var virtualMainAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
        mScope: kAudioObjectPropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )
    private var scalarMainAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyVolumeScalar,
        mScope: kAudioObjectPropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )
    private var muteAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: kAudioObjectPropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )
    private var defaultDeviceAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    /// The device the currently-registered volume/mute listener blocks are attached to — tracked
    /// separately from `deviceID` so a default-device change can remove the OLD registrations
    /// before pointing new ones at the new device (Pitfall 5).
    private var listenersDeviceID: AudioDeviceID = kAudioObjectUnknown
    private var registeredVolumeListeners: [(address: AudioObjectPropertyAddress, block: AudioObjectPropertyListenerBlock)] = []
    private var registeredMuteListener: (address: AudioObjectPropertyAddress, block: AudioObjectPropertyListenerBlock)?

    init() {
        refreshDefaultDevice()
        registerListeners()
    }

    private func refreshDefaultDevice() {
        var newDeviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = defaultDeviceAddress
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &newDeviceID
        )
        guard status == noErr else { return }
        deviceID = newDeviceID
        resolveVolumeSource()
        refreshVolume()
        refreshMute()
    }

    private func resolveVolumeSource() {
        let hasVirtualMain = hasProperty(virtualMainAddress)
        let hasScalarMain = hasProperty(scalarMainAddress)
        let supportedChannels: [UInt32] = [1, 2].filter { channel in
            hasProperty(perChannelAddress(channel))
        }
        volumeSource = VolumeSource.select(
            hasVirtualMain: hasVirtualMain,
            hasScalarMain: hasScalarMain,
            supportedChannels: supportedChannels
        )
    }

    private func perChannelAddress(_ channel: UInt32) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: channel
        )
    }

    private func hasProperty(_ address: AudioObjectPropertyAddress) -> Bool {
        var address = address
        return AudioObjectHasProperty(deviceID, &address)
    }

    private func readScalar(_ address: AudioObjectPropertyAddress) -> Float? {
        var value: Float = 0
        var size = UInt32(MemoryLayout<Float>.size)
        var address = address
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private func refreshVolume() {
        switch volumeSource {
        case .virtualMain:
            level = readScalar(virtualMainAddress)
        case .scalarMain:
            level = readScalar(scalarMainAddress)
        case .perChannel(let channels):
            let values = channels.compactMap { readScalar(perChannelAddress($0)) }
            level = values.isEmpty ? nil : values.reduce(0, +) / Float(values.count)
        case .unsupported:
            level = nil
        }
    }

    private func refreshMute() {
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = muteAddress
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr else { return }
        isMuted = value != 0
    }

    private func registerListeners() {
        // Registering on kAudioObjectSystemObject catches default-device
        // changes; volume/mute listeners are re-registered against the NEW
        // deviceID whenever the default output device changes.
        var systemAddress = defaultDeviceAddress
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &systemAddress, DispatchQueue.main
        ) { [weak self] _, _ in
            Task { @MainActor in
                self?.refreshDefaultDevice()
                self?.registerDeviceListeners()
                self?.onChange?()
            }
        }

        registerDeviceListeners()
    }

    /// Removes the OLD device's volume/mute listeners (if any), then registers fresh listeners
    /// against the current `deviceID`/`volumeSource`. Safe to call from `init` (nothing to remove
    /// yet, `listenersDeviceID == kAudioObjectUnknown`) and from the default-device-change handler.
    private func registerDeviceListeners() {
        removeDeviceListeners()
        listenersDeviceID = deviceID

        for address in volumeListenerAddresses() {
            var mutableAddress = address
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                Task { @MainActor in
                    self?.refreshVolume()
                    self?.onChange?()
                }
            }
            AudioObjectAddPropertyListenerBlock(deviceID, &mutableAddress, DispatchQueue.main, block)
            registeredVolumeListeners.append((address: address, block: block))
        }

        var mAddress = muteAddress
        let muteBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in
                self?.refreshMute()
                self?.onChange?()
            }
        }
        AudioObjectAddPropertyListenerBlock(deviceID, &mAddress, DispatchQueue.main, muteBlock)
        registeredMuteListener = (address: muteAddress, block: muteBlock)
    }

    private func removeDeviceListeners() {
        guard listenersDeviceID != kAudioObjectUnknown else { return }
        for (address, block) in registeredVolumeListeners {
            var mutableAddress = address
            AudioObjectRemovePropertyListenerBlock(listenersDeviceID, &mutableAddress, DispatchQueue.main, block)
        }
        registeredVolumeListeners.removeAll()
        if let (address, block) = registeredMuteListener {
            var mutableAddress = address
            AudioObjectRemovePropertyListenerBlock(listenersDeviceID, &mutableAddress, DispatchQueue.main, block)
            registeredMuteListener = nil
        }
    }

    /// The address(es) that must carry a live listener for `volumeSource` to notice a change —
    /// empty for `.unsupported`, so no listener is registered when there's nothing to read.
    private func volumeListenerAddresses() -> [AudioObjectPropertyAddress] {
        switch volumeSource {
        case .virtualMain: return [virtualMainAddress]
        case .scalarMain: return [scalarMainAddress]
        case .perChannel(let channels): return channels.map(perChannelAddress)
        case .unsupported: return []
        }
    }
}
