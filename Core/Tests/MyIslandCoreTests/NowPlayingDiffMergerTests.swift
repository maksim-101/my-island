import Testing
import Foundation
@testable import MyIslandCore

// MARK: - decode: empty-state forms (D-16)

@Test func decodeBareEmptyTokenYieldsEmptyFrame() {
    let raw = Data("NIL".utf8)
    #expect(NowPlayingDiffMerger.decode(rawLine: raw) == .empty)
}

/// The persistent-mode ("loop") empty state recorded by 05-01's evidence (spike 002, Design
/// consequence 5) is byte-identical to the one-shot `get`-mode token, just with the trailing
/// newline the line-delimited stream appends to every emitted line — decode must trim that before
/// comparing.
@Test func decodePersistentModeEmptyTokenWithTrailingNewlineYieldsEmptyFrame() {
    let raw = Data("NIL\n".utf8)
    #expect(NowPlayingDiffMerger.decode(rawLine: raw) == .empty)
}

@Test func decodeUnparsableTruncatedLineYieldsUnparsableFrameWithoutTrapping() {
    let raw = Data("{\"type\":\"data\",\"diff\":false,\"payl".utf8)
    #expect(NowPlayingDiffMerger.decode(rawLine: raw) == .unparsable)
}

@Test func decodeValidSessionEventYieldsSessionFrame() {
    let json = """
    {"type":"data","diff":false,"payload":{"title":"Ogum Me Rodeia","artist":"Anitta","album":"EQUILIBRIVM II","isPlaying":true}}
    """
    let raw = Data(json.utf8)
    guard case .session(let payload, let isDiff) = NowPlayingDiffMerger.decode(rawLine: raw) else {
        Issue.record("Expected .session frame")
        return
    }
    #expect(payload.title == "Ogum Me Rodeia")
    #expect(payload.artist == "Anitta")
    #expect(payload.isPlaying == true)
    #expect(isDiff == false)
}

// MARK: - merge (MEDIA-03)

@Test func mergeDiffEventWithOnlyElapsedKeepsPreviousTitleArtistAndArtwork() {
    let previous = NowPlayingPayload(
        title: "Ogum Me Rodeia",
        artist: "Anitta",
        artworkData: Data([0x01, 0x02, 0x03])
    )
    let incoming = NowPlayingPayload(elapsedTimeMicros: 500_000)

    let merged = NowPlayingDiffMerger.merge(previous: previous, incoming: incoming, isDiff: true)

    #expect(merged.title == "Ogum Me Rodeia")
    #expect(merged.artist == "Anitta")
    #expect(merged.artworkData == Data([0x01, 0x02, 0x03]))
    #expect(merged.elapsedTimeMicros == 500_000)
}

@Test func mergeDiffEventWithNewTitleClearsNothingElseButReplacesTitle() {
    let previous = NowPlayingPayload(
        title: "Old Title",
        artist: "Anitta",
        album: "EQUILIBRIVM II",
        artworkData: Data([0xAA])
    )
    let incoming = NowPlayingPayload(title: "New Title")

    let merged = NowPlayingDiffMerger.merge(previous: previous, incoming: incoming, isDiff: true)

    #expect(merged.title == "New Title")
    #expect(merged.artist == "Anitta")
    #expect(merged.album == "EQUILIBRIVM II")
    #expect(merged.artworkData == Data([0xAA]))
}

@Test func mergeFullEventReplacesWholeSessionStateDroppingOmittedArtwork() {
    let previous = NowPlayingPayload(
        title: "Old Title",
        artist: "Old Artist",
        artworkData: Data([0xAA, 0xBB])
    )
    let incoming = NowPlayingPayload(title: "New Title", artist: "New Artist")

    let merged = NowPlayingDiffMerger.merge(previous: previous, incoming: incoming, isDiff: false)

    #expect(merged.title == "New Title")
    #expect(merged.artist == "New Artist")
    #expect(merged.artworkData == nil)
}

@Test func mergeWithNoPreviousStateAlwaysUsesIncomingEvenWhenMarkedDiff() {
    let incoming = NowPlayingPayload(title: "First Track")
    let merged = NowPlayingDiffMerger.merge(previous: nil, incoming: incoming, isDiff: true)
    #expect(merged.title == "First Track")
}
