import CoreAudio
import AudioToolbox

/// Observes the default output device's volume/mute via the public,
/// documented CoreAudio `AudioObjectAddPropertyListenerBlock` API (HUD-02).
/// Registers once in `init` and keeps listeners alive for the app's lifetime;
/// re-registers volume/mute listeners against the new device whenever the
/// default output device changes (e.g. headphones plugged in).
@MainActor
final class VolumeProvider {
    private(set) var level: Float = 0
    private(set) var isMuted: Bool = false
    var onChange: (() -> Void)?

    private var deviceID: AudioDeviceID = kAudioObjectUnknown

    private var volumeAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
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
        refreshVolume()
        refreshMute()
    }

    private func refreshVolume() {
        var value: Float = 0
        var size = UInt32(MemoryLayout<Float>.size)
        var address = volumeAddress
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr else { return }
        level = value
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

    private func registerDeviceListeners() {
        var vAddress = volumeAddress
        AudioObjectAddPropertyListenerBlock(deviceID, &vAddress, DispatchQueue.main) { [weak self] _, _ in
            Task { @MainActor in
                self?.refreshVolume()
                self?.onChange?()
            }
        }

        var mAddress = muteAddress
        AudioObjectAddPropertyListenerBlock(deviceID, &mAddress, DispatchQueue.main) { [weak self] _, _ in
            Task { @MainActor in
                self?.refreshMute()
                self?.onChange?()
            }
        }
    }
}
