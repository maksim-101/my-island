import Foundation

/// Pure, single-purpose clipboard type classifier (PANEL-02): guesses whether a copied string is
/// a shell command, a CSS/hex color, a URL/domain, or plain text — used by the Clipboard droplet's
/// per-row type icon (sketch `DETAIL.clip`). No AppKit/SwiftUI — Core stays platform-agnostic; the
/// App layer only ever calls `classify(_:)` with the entry's already-decoded `String`.
public enum ClipboardKind: Sendable, Equatable {
    case command
    case color
    case link
    case text

    /// Common shell words a copied command line is likely to start with (07-09-PLAN's own list).
    private static let shellWords: Set<String> = [
        "git", "npm", "npx", "yarn", "swift", "xcodebuild", "xcodegen", "brew", "cd", "ls",
        "cat", "grep", "rg", "sudo", "make", "uv", "python", "node", "ssh", "open", "defaults",
        "osascript",
    ]

    /// `#RGB`, `#RRGGBB`, `#RRGGBBAA` hex, or a `rgb(`/`rgba(`/`hsl(`/`hsla(` functional form.
    private static let colorRegex = try! NSRegularExpression(
        pattern: #"^(#([0-9a-fA-F]{3}|[0-9a-fA-F]{4}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})|(rgba?|hsla?)\(.*\))$"#
    )

    /// A full `http(s)://` URL, a bare `www.` host, or a `domain.tld[/path]` form — no internal
    /// whitespace, anchored full-string so a sentence that merely mentions a domain never matches.
    private static let linkRegex = try! NSRegularExpression(
        pattern: #"^(https?://\S+|www\.\S+|[a-zA-Z0-9-]+(\.[a-zA-Z0-9-]+)+(/\S*)?)$"#,
        options: [.caseInsensitive]
    )

    /// Single-line trimmed input only — a multi-line paste (or an empty string) is always `.text`,
    /// checked before any pattern so a command/color/link regex is never even asked to look at it.
    /// Ordered command → color → link so `./scripts/install.sh` (a `./`-prefixed command whose tail
    /// happens to look like a `name.tld` fragment) resolves as a command, not a link.
    public static func classify(_ text: String) -> ClipboardKind {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: { $0.isNewline }) else { return .text }

        if isCommand(trimmed) { return .command }
        if matches(colorRegex, trimmed) { return .color }
        if matches(linkRegex, trimmed) { return .link }
        return .text
    }

    private static func isCommand(_ text: String) -> Bool {
        if text.hasPrefix("./") || text.hasPrefix("$ ") { return true }
        if text.contains(" | ") || text.contains(" && ") { return true }
        let firstWord = text.split(separator: " ", maxSplits: 1).first.map(String.init) ?? text
        return shellWords.contains(firstWord)
    }

    private static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        return regex.firstMatch(in: text, range: range) != nil
    }
}
