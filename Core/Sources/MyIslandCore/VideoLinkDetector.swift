/// Pure video-call link detection for calendar events (CAL-02). No AppKit/EventKit
/// import — the caller adapts a live `EKEvent`'s `url`/`location`/`notes` strings at
/// the actor boundary before calling `detect(url:location:notes:)`.
///
/// Field precedence is `url` (highest confidence, server-populated) → `location`
/// (medium, short strings) → `notes` (lowest confidence, highest false-positive rate).
///
/// Regex patterns are community-observed against known Zoom/Meet/Teams/Webex URL
/// structures, not vendor-documented (per Assumption A2 — Apple does not publish
/// these third-party formats).
///
/// Source: .planning/phases/04-calendar/04-RESEARCH.md Pattern 5.
import Foundation

public enum VideoLinkDetector {
    // Order matters: url before location before notes.
    public static func detect(url: String?, location: String?, notes: String?) -> URL? {
        if let url, let match = firstMatch(in: url) { return match }
        if let location, let match = firstMatch(in: location) { return match }
        if let notes {
            let stripped = stripHTMLTags(notes)
            if let match = firstMatch(in: stripped) { return match }
        }
        return nil
    }

    private static let servicePatterns: [String] = [
        #"https?://(?:[a-zA-Z0-9-]+\.)?zoom\.us/(?:j|wc/join)/\d+[^\s"']*"#,
        #"https?://meet\.google\.com/[a-z]{3}-[a-z]{4}-[a-z]{3}[^\s"']*"#,
        #"https?://(?:[a-zA-Z0-9-]+\.)?teams\.microsoft\.com/l/meetup-join/[^\s"']+"#,
        #"https?://[a-zA-Z0-9-]+\.webex\.com/[a-zA-Z0-9-]+/j\.php\?[^\s"']*MTID=[a-f0-9]+"#,
        // The fragment carries the call key (#v=1&p=…&k=…), so the pattern must
        // run past `#` — a fragment-terminated match yields an unjoinable URL.
        #"https?://facetime\.apple\.com/join[^\s"']*"#,
    ]
    private static let blacklistFragments = ["/rec/share/", "/rec/play/", "/u/", "/profile", "/settings", "/download", "/about"]

    private static func firstMatch(in text: String) -> URL? {
        // Bound input length before regex scanning — untrusted external calendar
        // invites can carry arbitrarily large notes fields (Security Domain V5).
        let bounded = String(text.prefix(4000))
        for pattern in servicePatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(bounded.startIndex..., in: bounded)
            guard let match = regex.firstMatch(in: bounded, range: range),
                  let swiftRange = Range(match.range, in: bounded) else { continue }
            let candidate = String(bounded[swiftRange])
            if blacklistFragments.contains(where: candidate.contains) { continue }
            if let url = URL(string: candidate), let scheme = url.scheme, ["http", "https"].contains(scheme) {
                return url
            }
        }
        return nil
    }

    private static func stripHTMLTags(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "<[^>]+>") else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
    }
}
