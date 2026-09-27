import Testing
@testable import MyIslandCore

/// 07-09-PLAN's `<behavior>` list, one test per literal example — RED phase, written against the
/// plan's own spec before `ClipboardKind.swift` exists. Wrapped in a `@Suite` so
/// `swift test --filter ClipboardKindTests` (the plan's own `<verify>` command) can find them by
/// suite name — a free `@Test func` has no "ClipboardKindTests" in its test ID.
@Suite struct ClipboardKindTests {
    @Test func linkDetectedFullURL() {
        #expect(ClipboardKind.classify("https://figma.com/file/9K2a") == .link)
    }

    @Test func linkDetectedBareDomain() {
        #expect(ClipboardKind.classify("figma.com/file/9K2a") == .link)
    }

    @Test func linkDetectedWWWForm() {
        #expect(ClipboardKind.classify("www.apple.com") == .link)
    }

    @Test func colorDetectedSixDigitHex() {
        #expect(ClipboardKind.classify("#7C6BFF") == .color)
    }

    @Test func colorDetectedThreeDigitHex() {
        #expect(ClipboardKind.classify("#fff") == .color)
    }

    @Test func colorDetectedRGBA() {
        #expect(ClipboardKind.classify("rgba(124,107,255,.35)") == .color)
    }

    @Test func colorDetectedHSL() {
        #expect(ClipboardKind.classify("hsl(250 100% 70%)") == .color)
    }

    @Test func commandDetectedGit() {
        #expect(ClipboardKind.classify("git rebase -i HEAD~3") == .command)
    }

    @Test func commandDetectedNpm() {
        #expect(ClipboardKind.classify("npm test -- --watch=false") == .command)
    }

    @Test func commandDetectedPipe() {
        #expect(ClipboardKind.classify("ls -la | grep x") == .command)
    }

    @Test func commandDetectedDotSlash() {
        #expect(ClipboardKind.classify("./scripts/install.sh") == .command)
    }

    @Test func textFallbackSentence() {
        #expect(ClipboardKind.classify("Let's move the review to Thursday") == .text)
    }

    @Test func textFallbackEmpty() {
        #expect(ClipboardKind.classify("") == .text)
    }

    @Test func textFallbackMultiline() {
        #expect(ClipboardKind.classify("Line one\nLine two\nLine three") == .text)
    }
}
