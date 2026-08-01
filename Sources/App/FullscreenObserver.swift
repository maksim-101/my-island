import AppKit
@preconcurrency import ApplicationServices
import CoreGraphics
import Foundation
import OSLog
import MyIslandCore

/// A permission-free signal for "is the frontmost application currently
/// fullscreen" (D-10/D-11), extended (T-7h2) with a second, AX-augmented signal for "should the
/// ambient row suppress" — a finer "content takeover" test than plain app-fullscreen. Modelled on
/// `BrightnessProvider`'s fragile-signal convention: every failure path resolves to `false` (not
/// fullscreen, ear shown) rather than crashing or hiding the ear forever.
///
/// Detection reads the frontmost app's process identifier, then looks for a
/// window it owns at the normal window layer whose bounds cover a whole
/// screen (RESEARCH.md Common Pitfalls, Pitfall 4 — the
/// `CGWindowListCopyWindowInfo` bounds/PID heuristic, preferred over
/// `NSMenu.menuBarVisible()` because the latter conflates fullscreen with
/// the user's general auto-hide-menu-bar preference, RESEARCH Assumption
/// A5). Only the owner process identifier, window layer and bounds are
/// read — no window title is ever requested via `CGWindowListCopyWindowInfo`, which is both a
/// privacy requirement (T-05-14) and what keeps THIS QUERY permission-free (only titles are gated
/// behind Screen Recording, RESEARCH Assumption A3). `kCGWindowName` is never requested here.
///
/// `isAmbientSuppressed` (T-7h2 Task 2) additionally reads AX facts — but ONLY when the frontmost
/// app is fullscreen AND is a browser AND Accessibility is granted (`AXIsProcessTrusted()`); a
/// non-browser fullscreen app needs no AX read at all (`FullscreenClassifier.decide` suppresses it
/// on app-fullscreen alone). The AX title is read only to test emptiness (`FullscreenFacts` carries
/// a `Bool`, never the string) and is never logged. `kAXWindowsAttribute` is never enumerated
/// (RESEARCH Pitfall 2 — Vivaldi returns an empty `AXWindows` array with `.success` while
/// `AXFocusedWindow` works fine); only `kAXFocusedWindowAttribute` is read.
///
/// Adds no entitlement, usage-description key or permission request for the base fullscreen
/// signal — if the heuristic proves unusable on hardware, `isAvailable` reports false and the
/// finding is escalated to the developer (see 05-05-PLAN.md Task 2), never silently patched over
/// with a new TCC prompt. The AX read DOES introduce a new Accessibility TCC grant (T-7h2-04); an
/// untrusted state degrades to `isAmbientSuppressed == isFrontmostFullscreen`'s old behavior for
/// non-browsers and to never-suppress for browsers — i.e. today's behavior, never a crash or a
/// permanent hide.
@MainActor
final class FullscreenObserver {
    private(set) var isFrontmostFullscreen: Bool = false
    /// T-7h2 Task 2: the finer "content takeover" signal `NotchBarView`'s ambient row (and its
    /// wing-hover region) should gate on, per `FullscreenClassifier.decide`. Independent of
    /// `isFrontmostFullscreen`, which Task 3's notch-locator glow still consumes directly.
    private(set) var isAmbientSuppressed: Bool = false
    var onChange: (() -> Void)?
    /// `false` only when the very first query returned no usable window
    /// information at all — lets callers distinguish "definitely not
    /// fullscreen" from "this signal never worked" (RESEARCH Assumption A3).
    private(set) var isAvailable: Bool = false

    // Accessed from `deinit`, which runs nonisolated — safe because
    // `Timer.invalidate()` is thread-agnostic and no other isolated state is
    // touched there (mirrors `BrightnessProvider.pollTimer`).
    nonisolated(unsafe) private var pollTimer: Timer?

    private let logger = AppLog.make("FullscreenObserver")

    /// Points of slack on each edge for the bounds-match comparison — a real
    /// fullscreen window's reported bounds can be off by a point or two from
    /// the screen/display frame, so exact equality is too strict (RESEARCH
    /// Pitfall 4).
    private static let boundsTolerance: CGFloat = 4

    /// Normal window layer (`kCGNormalWindowLevel`/`NSWindow.Level.normal`)
    /// — the layer an ordinary fullscreen app window sits at.
    private static let normalWindowLayer = 0

    /// Cached once, lazily — which app bundle URLs Launch Services reports as able to open
    /// `https:` links (RESEARCH's dynamic, non-hardcoded browser detection: no bundle-ID table).
    private static var cachedBrowserBundleURLs: Set<URL>?

    init() {
        // Prompts only when untrusted; a grant made while the app is running takes effect on the
        // next poll's `AXIsProcessTrusted()` re-read, no relaunch needed. No entitlement or
        // Info.plist key is involved.
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
        refresh(isFirstQuery: true)
        startPolling()
    }

    deinit {
        pollTimer?.invalidate()
    }

    private func startPolling() {
        // ~1s coarse poll (Claude's Discretion, mirrors BrightnessProvider's
        // poll convention) — no public notification reports another
        // application's fullscreen transition.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh(isFirstQuery: false)
            }
        }
    }

    private func refresh(isFirstQuery: Bool) {
        let result = Self.classify()

        if isFirstQuery {
            isAvailable = result.hasUsableWindowInfo
        }

        let axTrusted = AXIsProcessTrusted()
        let isBrowser = Self.isBrowserApp(bundleURL: result.bundleURL)

        var axFullscreen: Bool?
        var axSubrole: String?
        var axTitleIsEmpty: Bool?

        if result.isFullscreen, isBrowser, axTrusted, let pid = result.pid {
            let axApp = AXUIElementCreateApplication(pid)
            if let window = Self.axWindowElement(axApp) {
                axSubrole = Self.axString(window, kAXSubroleAttribute as String)
                let title = Self.axString(window, kAXTitleAttribute as String)
                axTitleIsEmpty = title.map(\.isEmpty)
                axFullscreen = Self.axBool(window, "AXFullScreen")
            }
        }

        let facts = FullscreenFacts(
            isAppFullscreen: result.isFullscreen,
            isBrowser: isBrowser,
            axFocusedWindowIsFullscreen: axFullscreen,
            axFocusedWindowSubrole: axSubrole,
            axFocusedWindowTitleIsEmpty: axTitleIsEmpty
        )
        let decision = FullscreenClassifier.decide(facts)

        let previousFullscreen = isFrontmostFullscreen
        let previousSuppressed = isAmbientSuppressed
        isFrontmostFullscreen = result.isFullscreen
        isAmbientSuppressed = decision == .suppress

        guard isFrontmostFullscreen != previousFullscreen || isAmbientSuppressed != previousSuppressed else {
            return
        }

        // Diagnostic evidence for the on-hardware human-check (05-05-PLAN.md Task 2 / T-7h2 Task
        // 2) — the resolved values plus every reason field, and the corroborating (never
        // decisive, RESEARCH Assumption A5) menu-bar visibility signal. This is the regression
        // tripwire RESEARCH Assumption A2 asks for (the Safari signal is a
        // `WKFullScreenWindowController` implementation detail, not a contract). No window title
        // or now-playing metadata is ever logged here.
        logger.debug("""
            fullscreen=\(self.isFrontmostFullscreen, privacy: .public) \
            suppressed=\(self.isAmbientSuppressed, privacy: .public) \
            bundleID=\(result.bundleID ?? "none", privacy: .public) \
            isBrowser=\(isBrowser, privacy: .public) \
            axTrusted=\(axTrusted, privacy: .public) \
            subrole=\(axSubrole ?? "none", privacy: .public) \
            titleEmpty=\(axTitleIsEmpty.map(String.init) ?? "none", privacy: .public) \
            foundOwnedWindow=\(result.foundOwnedWindow, privacy: .public) \
            boundsMatchedScreen=\(result.boundsMatched, privacy: .public) \
            menuBarVisible=\(NSMenu.menuBarVisible(), privacy: .public)
            """)
        onChange?()
    }

    private struct ClassificationResult {
        var isFullscreen = false
        var bundleID: String?
        var pid: pid_t?
        var bundleURL: URL?
        var foundOwnedWindow = false
        var boundsMatched = false
        var hasUsableWindowInfo = false
    }

    private static func classify() -> ClassificationResult {
        var result = ClassificationResult()

        guard let frontmost = NSWorkspace.shared.frontmostApplication else {
            return result
        }
        result.bundleID = frontmost.bundleIdentifier
        result.pid = frontmost.processIdentifier
        result.bundleURL = frontmost.bundleURL
        let frontmostPID = frontmost.processIdentifier

        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: AnyObject]] else {
            return result
        }
        result.hasUsableWindowInfo = !windowList.isEmpty

        for windowInfo in windowList {
            guard let ownerPID = windowInfo[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPID == frontmostPID else { continue }
            guard let layer = windowInfo[kCGWindowLayer as String] as? Int,
                  layer == normalWindowLayer else { continue }
            guard let boundsDict = windowInfo[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else { continue }

            result.foundOwnedWindow = true

            switch screenMatch(bounds: bounds) {
            case .exact:
                // Window covers the ENTIRE display, menu-bar strip included — only real
                // fullscreen (or a borderless overlay) does that; a zoomed window never does.
                result.boundsMatched = true
                result.isFullscreen = true
                return result
            case .notchExcluded:
                // Bounds == display minus the menu-bar/notch strip. A REAL fullscreen app on a
                // notched display reports exactly this — but so does a merely MAXIMIZED (green-
                // zoom) window, which sits below the still-visible menu bar. The menu bar is the
                // discriminator: fullscreen auto-hides it, a maximized window keeps it. Without
                // this guard, Apple Music (or any app) maximized was misread as fullscreen and the
                // Now Playing ear was wrongly suppressed (UAT 2026-07-31).
                if !NSMenu.menuBarVisible() {
                    result.boundsMatched = true
                    result.isFullscreen = true
                    return result
                }
            case .none:
                break
            }
        }

        return result
    }

    private enum ScreenMatchKind { case none, exact, notchExcluded }

    /// Whether `bounds` covers an entire screen — either exactly (an
    /// ordinary fullscreen window) or the screen frame extended over its
    /// safe-area/notch inset (RESEARCH Pitfall 4's documented false
    /// negative: a notched built-in display can report fullscreen bounds
    /// that exclude the safe area). Compared in Quartz's top-left-origin
    /// display coordinate space via `CGDisplayBounds`, the SAME space
    /// `CGWindowListCopyWindowInfo` reports bounds in — never
    /// `NSScreen.frame`, which is Cocoa's bottom-left-origin space and would
    /// silently misalign this comparison.
    private static func screenMatch(bounds: CGRect) -> ScreenMatchKind {
        for screen in NSScreen.screens {
            guard let screenNumber = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber else { continue }
            let displayID = CGDirectDisplayID(screenNumber.uint32Value)
            let displayBounds = CGDisplayBounds(displayID)

            if approximatelyEqual(bounds, displayBounds) {
                return .exact
            }

            let safeAreaTop = screen.safeAreaInsets.top
            guard safeAreaTop > 0 else { continue }
            let notchExcludedBounds = CGRect(
                x: displayBounds.minX,
                y: displayBounds.minY + safeAreaTop,
                width: displayBounds.width,
                height: displayBounds.height - safeAreaTop
            )
            if approximatelyEqual(bounds, notchExcludedBounds) {
                return .notchExcluded
            }
        }
        return .none
    }

    private static func approximatelyEqual(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= boundsTolerance &&
        abs(a.minY - b.minY) <= boundsTolerance &&
        abs(a.width - b.width) <= boundsTolerance &&
        abs(a.height - b.height) <= boundsTolerance
    }

    /// Dynamic browser detection — no bundle-ID table (locked constraint: "dynamic, not
    /// hardcoded for certain apps"). If the Launch Services query itself returns an empty list,
    /// every app is treated as a browser so the failure mode is showing the row, never wrongly
    /// hiding it.
    private static func isBrowserApp(bundleURL: URL?) -> Bool {
        let browsers = browserBundleURLs()
        guard !browsers.isEmpty else { return true }
        guard let bundleURL else { return false }
        return browsers.contains(bundleURL.standardizedFileURL)
    }

    private static func browserBundleURLs() -> Set<URL> {
        if let cachedBrowserBundleURLs { return cachedBrowserBundleURLs }
        guard let probeURL = URL(string: "https://example.com") else {
            cachedBrowserBundleURLs = []
            return []
        }
        let apps = NSWorkspace.shared.urlsForApplications(toOpen: probeURL)
        let standardized = Set(apps.map(\.standardizedFileURL))
        cachedBrowserBundleURLs = standardized
        return standardized
    }

    // MARK: - AX reads (frontmost app's focused window only, read-only, never `kAXWindowsAttribute`)

    private static func axWindowElement(_ app: AXUIElement) -> AXUIElement? {
        var value: AnyObject?
        let status = AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value)
        guard status == .success, let value else { return nil }
        return (value as! AXUIElement)
    }

    private static func axString(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: AnyObject?
        let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard status == .success else { return nil }
        return value as? String
    }

    private static func axBool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var value: AnyObject?
        let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard status == .success else { return nil }
        return value as? Bool
    }
}
