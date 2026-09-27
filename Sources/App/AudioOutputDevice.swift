import CoreAudio
import Foundation

/// Reads the current default output device's display name (07-09-PLAN, Now Playing droplet) via
/// the same CoreAudio HAL idiom `SystemAudioLevelProvider.defaultOutputDeviceUID()` already uses
/// for the level tap's clock device — two property reads off the system object: the default
/// output device ID, then that device's own display name. `nil` on any HAL failure, never a crash;
/// read once when the droplet appears (`.task` in `NowPlayingPanelView`), not observed live.
enum AudioOutputDevice {
    static func currentName() -> String? {
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var deviceIDSize = UInt32(MemoryLayout<AudioObjectID>.size)
        var deviceAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &deviceAddress, 0, nil, &deviceIDSize, &deviceID
        ) == noErr, deviceID != kAudioObjectUnknown else { return nil }

        var name: CFString?
        var nameSize = UInt32(MemoryLayout<CFString?>.size)
        var nameAddress = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let err = withUnsafeMutablePointer(to: &name) {
            AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &nameSize, $0)
        }
        guard err == noErr else { return nil }
        return name as String?
    }
}
