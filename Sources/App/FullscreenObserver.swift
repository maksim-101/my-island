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
/// `CGWindowListCopyWindowInfo` bounds/PID heuristic). Only the owner process identifier, window
/// layer and bounds are read — no window title is ever requested via
/// `CGWindowListCopyWindowInfo`, which is both a privacy requirement (T-05-14) and what keeps
/// THIS QUERY permission-free (only titles are gated behind Screen Recording, RESEARCH Assumption
/// A3). `kCGWindowName` is never requested here.
///
/// On a notched display, a real fullscreen window's bounds exclude the safe-area/menu-bar strip
/// (the `.notchExcluded` case) — indistinguishable by bounds alone from a merely MAXIMIZED window
/// with the Dock auto-hidden: 260801-7h2-regressions round 2 measured this directly (not just
/// analytically) — a merely-maximized Safari window's content bounds land within 1pt of a
/// genuinely-fullscreen window's content bounds on this hardware, well inside the 4pt tolerance
/// `approximatelyEqual` needs to absorb rounding noise. Disambiguating this used to read
/// `NSMenu.menuBarVisible()` (WRONG — reflects the CALLING process's own menu-bar state, and
/// my-island is `LSUIElement`), then (round 1) the AX `AXFullScreen` attribute, falling back to
/// accepting the bounds match unconditionally when Accessibility is untrusted. That fallback is
/// where round 1's fix quietly failed in practice: Accessibility was never actually granted in
/// EITHER debug round, across three different app builds/signing identities including a
/// zero-rebuild stable-signed Release build — so the "permission-free by default" fallback was in
/// effect the ENTIRE time, reintroducing the exact maximized-window false positive it was meant to
/// only reintroduce in a rare degraded state.
///
/// The round-2 fix (`isGenuineFullscreen`) makes the PRIMARY disambiguator SkyLight's
/// `CGSCopyManagedDisplaySpaces` — a private but permission-free API (no TCC prompt, ever) that
/// reports, per display, the currently-active managed Space's `type` and (for fullscreen spaces)
/// the owning process's `pid`. Measured directly across 4 states on this hardware: a merely-
/// maximized window leaves the Space `type` at `0` (ordinary desktop) exactly like a small
/// windowed tab does, while BOTH plain Safari-native fullscreen AND nested element/video
/// fullscreen (`WKFullScreenWindowController`, e.g. fullscreening a YouTube video inside an
/// already-fullscreen Safari window) put the display's current Space at `type == 4` with `pid`
/// equal to the owning app — a clean, unconditional, permission-free signal. AX `AXFullScreen` is
/// kept as a SECONDARY fallback only for the case SkyLight's private symbols fail to resolve (a
/// future OS could remove them, unlikely but not guaranteed); accepting the bounds match
/// unconditionally remains the final, last-resort fallback if BOTH are unavailable.
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
// 260801-7h2-regressions round 3 (SUPPRESSION-STALENESS): this class was never marked
// `@Observable`, unlike every sibling provider `NotchBarView` reads (`NowPlayingProvider`,
// `TimerViewModel`, `NotchViewModel` are all `@MainActor @Observable`) — and `onChange` (below) is
// declared but never wired up by `NotchPanelController`. `refresh()` DOES recompute
// `isFrontmostFullscreen`/`isAmbientSuppressed` correctly on every ~1s poll, unconditionally, but
// with no observation mechanism SwiftUI has no way to know a re-render is needed: `NotchBarView`
// only picks up the fresh values opportunistically, when some OTHER `@Observable` dependency it
// also reads (`nowPlaying`, `timer`, `model.isOpen`) happens to force a body re-evaluation around
// the same moment. When nothing else changes — e.g. switching directly between two already-
// fullscreen apps, where nothing about Now Playing/timer/popup state changes — the rendered UI
// keeps showing the stale pre-switch snapshot until the user manually opens+closes the popup
// (which flips `NotchViewModel.isOpen`, forcing the re-render). Verified directly (not just by
// reading the doc) via `withObservationTracking`, the exact primitive SwiftUI's own diffing uses:
// a probe replicating this class's shape WITHOUT `@Observable` never invokes `onChange` after a
// property mutation; the identical shape WITH `@Observable` always does
// (scratchpad/probe_observation.swift). `@Observable` is the fix — it matches the established
// provider pattern in this codebase and requires no other call-site changes.
@MainActor
@Observable
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
        let axTrusted = AXIsProcessTrusted()
        let result = Self.classify(axTrusted: axTrusted)

        if isFirstQuery {
            isAvailable = result.hasUsableWindowInfo
        }

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
        // 2) — the resolved values plus every reason field. This is the regression tripwire
        // RESEARCH Assumption A2 asks for (the Safari signal is a `WKFullScreenWindowController`
        // implementation detail, not a contract). No window title or now-playing metadata is ever
        // logged here. `menuBarVisible` was dropped from this line (260801-7h2-regressions): it
        // reflected my-island's OWN (nonexistent, `LSUIElement`) menu bar presentation state, never
        // Safari's, so it was always `true` and never diagnostic.
        logger.debug("""
            fullscreen=\(self.isFrontmostFullscreen, privacy: .public) \
            suppressed=\(self.isAmbientSuppressed, privacy: .public) \
            bundleID=\(result.bundleID ?? "none", privacy: .public) \
            isBrowser=\(isBrowser, privacy: .public) \
            axTrusted=\(axTrusted, privacy: .public) \
            subrole=\(axSubrole ?? "none", privacy: .public) \
            titleEmpty=\(axTitleIsEmpty.map(String.init) ?? "none", privacy: .public) \
            foundOwnedWindow=\(result.foundOwnedWindow, privacy: .public) \
            boundsMatchedScreen=\(result.boundsMatched, privacy: .public)
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

    private static func classify(axTrusted: Bool) -> ClassificationResult {
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
                // zoom) window with the Dock auto-hidden (UAT 2026-07-31: Apple Music maximized was
                // misread as fullscreen and the Now Playing ear was wrongly suppressed).
                //
                // 260801-7h2-regressions round 1 disambiguated this with the AX `AXFullScreen`
                // attribute, falling back to accepting the bounds match unconditionally when
                // Accessibility was untrusted. Round 2 found that fallback was live 100% of the
                // time in practice (Accessibility was never actually granted, across three
                // different app builds/signing identities) — so the maximized-window false
                // positive was back, confirmed live via the app's own log
                // (`fullscreen=true ... boundsMatchedScreen=true` for a merely-maximized window).
                //
                // Fix: `isGenuineFullscreen` now checks SkyLight's `CGSCopyManagedDisplaySpaces`
                // FIRST — permission-free (no TCC prompt, ever) and measured to discriminate
                // cleanly: a merely-maximized window leaves the display's current Space at
                // `type == 0` (ordinary desktop), while both plain Safari-native fullscreen AND
                // nested element/video fullscreen put it at `type == 4` with `pid` equal to the
                // owning app. AX `AXFullScreen` remains a secondary fallback (SkyLight symbols
                // failing to resolve on some future OS), and accepting the bounds match
                // unconditionally remains the final, last-resort fallback if both are unavailable.
                if Self.isGenuineFullscreen(pid: frontmostPID, axTrusted: axTrusted) {
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

    /// Disambiguates a `.notchExcluded` bounds match (real fullscreen vs. a merely maximized
    /// window with the Dock auto-hidden). PRIMARY signal (260801-7h2-regressions round 2):
    /// SkyLight's `CGSCopyManagedDisplaySpaces` — permission-free, measured to discriminate
    /// cleanly (see `isOnFullscreenSpace`). SECONDARY fallback, only when the SkyLight symbols
    /// fail to resolve: the AX `AXFullScreen` attribute (round 1's fix) — untrusted, or any AX
    /// read failure, resolves to `true` (accept the bounds match), the final last-resort fallback
    /// that keeps the base signal permission-free even if BOTH SkyLight and AX are unavailable.
    private static func isGenuineFullscreen(pid: pid_t, axTrusted: Bool) -> Bool {
        if let onFullscreenSpace = isOnFullscreenSpace(pid: pid) {
            return onFullscreenSpace
        }
        guard axTrusted else { return true }
        let axApp = AXUIElementCreateApplication(pid)
        guard let window = axWindowElement(axApp) else { return true }
        guard let isFullscreen = axBool(window, "AXFullScreen") else { return true }
        return isFullscreen
    }

    // MARK: - SkyLight Spaces (permission-free fullscreen-Space confirmation)

    private typealias CGSMainConnectionIDFunction = @convention(c) () -> Int32
    private typealias CGSCopyManagedDisplaySpacesFunction = @convention(c) (Int32) -> Unmanaged<CFArray>?

    private static let skyLightHandle: UnsafeMutableRawPointer? =
        dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)

    private static let cgsMainConnectionID: CGSMainConnectionIDFunction? = {
        guard let skyLightHandle, let symbol = dlsym(skyLightHandle, "CGSMainConnectionID") else { return nil }
        return unsafeBitCast(symbol, to: CGSMainConnectionIDFunction.self)
    }()

    private static let cgsCopyManagedDisplaySpaces: CGSCopyManagedDisplaySpacesFunction? = {
        guard let skyLightHandle, let symbol = dlsym(skyLightHandle, "CGSCopyManagedDisplaySpaces") else { return nil }
        return unsafeBitCast(symbol, to: CGSCopyManagedDisplaySpacesFunction.self)
    }()

    /// Whether `pid` currently owns a genuine fullscreen Space, per SkyLight's own per-display
    /// Spaces bookkeeping (260801-7h2-regressions round 2, measured directly across 4 states on
    /// notched hardware): a merely-maximized/zoomed window never creates a new Space — the
    /// display's "Current Space" stays `type == 0` (ordinary desktop), identical to a small
    /// windowed tab. A real `NSWindow.toggleFullScreen()` transition AND a nested
    /// `WKFullScreenWindowController` element/video fullscreen (e.g. fullscreening a video inside
    /// an already-fullscreen browser) BOTH move the display onto a dedicated Space reported here
    /// as `type == 4`, whose dict carries a `pid` field equal to the owning process — checked
    /// across every connected display so this degrades gracefully on multi-display setups.
    /// Returns `nil` (undetermined — callers should fall back to another signal, never treat as
    /// "not fullscreen") only if the private symbols fail to resolve or the query itself fails.
    private static func isOnFullscreenSpace(pid: pid_t) -> Bool? {
        guard let cgsMainConnectionID, let cgsCopyManagedDisplaySpaces else { return nil }
        let connection = cgsMainConnectionID()
        guard let displays = cgsCopyManagedDisplaySpaces(connection)?.takeRetainedValue() as? [[String: Any]] else {
            return nil
        }
        for display in displays {
            guard let currentSpace = display["Current Space"] as? [String: Any],
                  let type = currentSpace["type"] as? Int, type == 4,
                  let spacePID = currentSpace["pid"] as? Int, pid_t(spacePID) == pid else { continue }
            return true
        }
        return false
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
