import Testing
@testable import MyIslandCore

@Test func earTextJoinsTitleAndArtistWithEmDash() {
    let result = NowPlayingFormatting.earText(title: "Ogum Me Rodeia", artist: "Anitta")
    #expect(result == "Ogum Me Rodeia — Anitta")
}

@Test func earTextWithEmptyArtistYieldsJustTitleWithNoDanglingEmDash() {
    let result = NowPlayingFormatting.earText(title: "Ogum Me Rodeia", artist: "")
    #expect(result == "Ogum Me Rodeia")
}

@Test func earTextWithEmptyTitleYieldsJustArtist() {
    let result = NowPlayingFormatting.earText(title: "", artist: "Anitta")
    #expect(result == "Anitta")
}

/// Spike 002 (05-01 evidence) observed `artist: null` — not an empty string — for both Infuse and
/// the Apple TV app. The formatter must fall back to title-only for a `nil` artist, never render a
/// bare separator or the literal string `"null"`.
@Test func earTextWithNilArtistYieldsJustTitle() {
    let result = NowPlayingFormatting.earText(title: "How to Make a Killing", artist: nil)
    #expect(result == "How to Make a Killing")
}

@Test func earTextWithNilTitleYieldsJustArtist() {
    let result = NowPlayingFormatting.earText(title: nil, artist: "Anitta")
    #expect(result == "Anitta")
}

@Test func earTextWithBothNilYieldsEmptyString() {
    let result = NowPlayingFormatting.earText(title: nil, artist: nil)
    #expect(result.isEmpty)
}
