import Foundation

/// Which CoreAudio property `VolumeProvider` should read the current output device's volume from.
/// STUB — TDD RED phase. See VolumeSourceTests.swift for the behavior this must satisfy.
public enum VolumeSource: Sendable, Equatable {
    case virtualMain
    case scalarMain
    case perChannel([UInt32])
    case unsupported

    public static func select(
        hasVirtualMain: Bool,
        hasScalarMain: Bool,
        supportedChannels: [UInt32]
    ) -> VolumeSource {
        .unsupported // stub: always wrong, so the RED tests fail
    }
}
