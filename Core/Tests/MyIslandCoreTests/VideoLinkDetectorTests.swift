import Testing
@testable import MyIslandCore

@Test func detectFindsZoomLinkInURL() {
    let result = VideoLinkDetector.detect(url: "https://zoom.us/j/1234567890", location: nil, notes: nil)
    #expect(result?.absoluteString == "https://zoom.us/j/1234567890")
}

@Test func detectFindsMeetLinkInLocation() {
    let result = VideoLinkDetector.detect(url: nil, location: "https://meet.google.com/abc-defg-hij", notes: nil)
    #expect(result?.absoluteString == "https://meet.google.com/abc-defg-hij")
}

@Test func detectFindsTeamsLinkInNotes() {
    let result = VideoLinkDetector.detect(url: nil, location: nil, notes: "Join here: https://teams.microsoft.com/l/meetup-join/abcdef")
    #expect(result?.absoluteString == "https://teams.microsoft.com/l/meetup-join/abcdef")
}

@Test func detectPrefersURLOverLocationWhenBothPresent() {
    let result = VideoLinkDetector.detect(
        url: "https://zoom.us/j/1111111111",
        location: "https://meet.google.com/abc-defg-hij",
        notes: nil
    )
    #expect(result?.absoluteString == "https://zoom.us/j/1111111111")
}

@Test func detectRejectsBlacklistedZoomRecordingLink() {
    let result = VideoLinkDetector.detect(url: "https://zoom.us/rec/share/abc123", location: nil, notes: nil)
    #expect(result == nil)
}

@Test func detectRejectsFileURLScheme() {
    let result = VideoLinkDetector.detect(url: "file:///Users/someone/meet.google.com/abc-defg-hij", location: nil, notes: nil)
    #expect(result == nil)
}

@Test func detectReturnsNilForPlainTextWithNoVideoPattern() {
    let result = VideoLinkDetector.detect(url: nil, location: "Conference Room 3B", notes: "Bring your laptop.")
    #expect(result == nil)
}

@Test func detectStripsHTMLTagsBeforeMatchingNotes() {
    let result = VideoLinkDetector.detect(url: nil, location: nil, notes: "<p>Join: <a href=\"https://meet.google.com/abc-defg-hij\">link</a></p>")
    #expect(result?.absoluteString == "https://meet.google.com/abc-defg-hij")
}
