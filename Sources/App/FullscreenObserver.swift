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
/// The round-2 fix used SkyLight's `CGSCopyManagedDisplaySpaces` — a private but permission-free
/// API (no TCC prompt, ever) that reports, per display, the currently-active managed Space's
/// `type` and (for fullscreen spaces) the owning process's `pid` — as the disambiguator for a
/// bounds match that excluded the notch/menu-bar strip: a merely-maximized window leaves the
/// Space `type` at `0` (ordinary desktop) exactly like a small windowed tab does, while BOTH plain
/// Safari-native fullscreen AND nested element/video fullscreen (`WKFullScreenWindowController`,
/// e.g. fullscreening a YouTube video inside an already-fullscreen Safari window) put the
/// display's current Space at `type == 4` with `pid` equal to the owning app. **260912
/// superseded:** that disambiguation (`isGenuineFullscreen`, AX `AXFullScreen` as its secondary
/// fallback) is removed — see the widening note below. The SkyLight Space check itself
/// (`fullscreenSpaceCheck`) remains, now as the unconditional PRIMARY signal rather than a
/// disambiguator nested inside the bounds loop.
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
/// with a new TCC prompt. The AX read still USES an Accessibility grant if the user has
/// independently made one in System Settings, but this class never REQUESTS that grant itself
/// (T-05-16: restores 05-05's original declared disposition of "never adding a prompt
/// autonomously"). An untrusted state degrades to `isAmbientSuppressed ==
/// isFrontmostFullscreen`'s old behavior for non-browsers and to never-suppress for browsers —
/// i.e. today's behavior, never a crash or a permanent hide.
///
/// **260912 iterm2-fullscreen-detection widening (SUPERSEDED — see menubar-coverage-rule below):**
/// the round-2 "genuine fullscreen" disambiguator (`isGenuineFullscreen`, now removed) rejected
/// iTerm2's Cmd+Return fullscreen because it never creates a real macOS Space
/// (`isOnFullscreenSpace` measured `false` for it, 6/6 occurrences) — structurally identical, by
/// that check, to a merely maximized window. User's then-decision: widen fullscreen detection to
/// accept ANY frontmost window whose bounds fill a display's frame minus some top strip (the
/// literal full bounds, the notch/safe-area height, or the plain menu-bar height), deliberately
/// including merely-maximized windows. `classify()` now runs the SkyLight Space check
/// (`isOnFullscreenSpace`) FIRST, unconditionally — previously nested inside the bounds loop's
/// notch-excluded arm, which was dead code on any notchless display (required `safeAreaTop > 0`).
/// A confirmed genuine Space resolves fullscreen bounds-independently; everything else falls
/// through to the bounds-fill check below — that check's own candidate set is what
/// menubar-coverage-rule narrows next.
///
/// **260912 menubar-coverage-rule (supersedes the widening above, does not touch the Space-check
/// ordering it established):** live user testing of the widened rule surfaced the actual intent —
/// "I am not actually in fullscreen-mode and thus still see the menu bar and available space." The
/// widened rule matched any of three candidate top-strip insets (0 / safe-area / menu-bar height),
/// which is why a merely-maximized or non-native-fullscreen window whose bounds stop at the menu
/// bar (leaving it fully visible) still counted. The rule is now: engage only when the menu bar is
/// actually obscured, i.e. only the literal full-display-frame candidate (`topInset: 0`) counts —
/// `screenMatch(bounds:)` no longer tries the safe-area or menu-bar-height insets at all. Direct
/// consequence, accepted deliberately: iTerm2's Cmd+Return fullscreen (bounds `0,33,1728x1084` on
/// this hardware — starts 33pt below the screen top, i.e. below the menu bar) no longer matches and
/// shows the normal pill again, reversing the widening's user-visible outcome for that one app. The
/// remedy for a user who wants the sliver under iTerm2 is iTerm2's own native full-screen setting,
/// which creates a real Space and is caught by the unaffected `via=space` path above. A real
/// non-native fullscreen window that DOES cover the menu bar (VLC, mpv, some games/media players)
/// still matches — that is the class this narrower rule is meant to keep.
///
/// **Menu-bar auto-hide.** The rule is really "does this window's content reach the display's own
/// top edge," and a visible, non-auto-hidden menu bar is simply the normal way a window fails to
/// reach it (macOS reserves that strip and ordinary windows can't be placed under it). With
/// "Automatically hide and show the menu bar" enabled, the menu bar reserves no permanent screen
/// height, so a maximized window's own reported bounds already read as filling the literal full
/// screen frame — the same `topInset: 0` match fires correctly with zero new code. This is the rule
/// behaving as intended under auto-hide, not an exception that needs a setting or a special case.
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
    /// Phase 6 Plan 03 (D-06): which display currently hosts the fullscreen window, or `nil` when
    /// nothing is fullscreen or the hosting display couldn't be resolved. Feeds the per-display
    /// queries below; the stored global booleans above are unchanged and still what `@Observable`
    /// tracks for existing (pre-D-06) callers.
    private(set) var fullscreenDisplayID: CGDirectDisplayID?
    var onChange: (() -> Void)?
    /// `false` only when the very first query returned no usable window
    /// information at all — lets callers distinguish "definitely not
    /// fullscreen" from "this signal never worked" (RESEARCH Assumption A3).
    private(set) var isAvailable: Bool = false

    /// 20260912 (sliver-stuck-and-popover-glow): tracked so `refresh()`'s change-guard can also
    /// fire when the DETECTION PATH or the responsible app changes without either tracked boolean
    /// changing — e.g. one already-fullscreen app handing off to another on the same display
    /// (`displayID` unchanged, `isFrontmostFullscreen` unchanged). Without this, that handoff
    /// produces zero log output, which reads indistinguishable from a stuck state to anyone
    /// reading `log show` after the fact. Not `@Observable`-relevant (no UI reads these) — plain
    /// `private var`, not `private(set)`.
    private var previousVia: String = "none"
    private var previousBundleID: String?

    // Accessed from `deinit`, which runs nonisolated — safe because
    // `Timer.invalidate()` is thread-agnostic and no other isolated state is
    // touched there (mirrors `BrightnessProvider.pollTimer`).
    nonisolated(unsafe) private var pollTimer: Timer?

    // 20260912 (sliver-stuck-and-popover-glow, Task 3): same nonisolated-from-deinit shape as
    // `pollTimer` above — `NotificationCenter.removeObserver` is thread-agnostic.
    nonisolated(unsafe) private var spaceChangeObserver: NSObjectProtocol?

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
        // T-05-16: this observer never triggers the Accessibility dialog. `refresh()` re-reads
        // trust silently via `AXIsProcessTrusted()` on every ~1s poll, so a grant the user makes
        // in System Settings takes effect on the next poll with no relaunch. An untrusted state
        // is not a degraded mode in practice, because SkyLight's `CGSCopyManagedDisplaySpaces` is
        // the permission-free PRIMARY fullscreen signal and AX is only the secondary fallback.
        refresh(isFirstQuery: true)
        startPolling()

        // 20260912 (sliver-stuck-and-popover-glow, Task 3): the coordinator's own repro —
        // switching Spaces on the Dell briefly showed the full pill before collapsing to the
        // sliver. The 1s poll (above) means a Space switch's new fullscreen state isn't observed
        // until the next tick, so the stale pre-switch frame renders for up to a second. This
        // fires the SAME `refresh()` the poll calls, immediately on the notification, so the two
        // paths can never disagree — the poll stays as-is as the backstop for transitions with no
        // Space event at all (`via=bounds`, e.g. iTerm2's Cmd+Return pseudo-fullscreen never
        // creates a real Space). Per RESEARCH Pitfall 4 (measured on this codebase:
        // `CGWindowListCopyWindowInfo` can report Mission-Control miniature bounds mid-transition),
        // this notification-triggered read can itself still catch the ~0.5s transition window —
        // the following poll tick is what corrects it, same as it always has for any other
        // transient misread.
        spaceChangeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // `queue: .main` only guarantees runtime dispatch to the main queue, not compile-time
            // actor isolation — mirrors `NotchPanelController`'s identical
            // `didChangeScreenParametersNotification` observer's `Task { @MainActor in ... }` hop.
            Task { @MainActor in
                self?.refresh(isFirstQuery: false)
            }
        }
    }

    deinit {
        pollTimer?.invalidate()
        if let spaceChangeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(spaceChangeObserver)
        }
    }

    /// Phase 6 Plan 03 (D-06): `true` on the display currently hosting a fullscreen window.
    /// Degrades to the global `isFrontmostFullscreen` answer whenever `fullscreenDisplayID` or
    /// `displayID` is unresolved (`matches(_:)`'s no-regression rule, T-06-06) — never a crash,
    /// never a hidden-forever ear.
    func isFrontmostFullscreen(on displayID: CGDirectDisplayID?) -> Bool {
        isFrontmostFullscreen && matches(displayID)
    }

    /// Phase 6 Plan 03 (D-06): per-display ambient-suppression query — mirrors
    /// `isFrontmostFullscreen(on:)`'s degrade rule exactly.
    func isAmbientSuppressed(on displayID: CGDirectDisplayID?) -> Bool {
        isAmbientSuppressed && matches(displayID)
    }

    /// `true` when either side is unresolved (`fullscreenDisplayID == nil` — nothing fullscreen or
    /// its display couldn't be determined — or `displayID == nil` — the caller's own display is
    /// unresolved) so callers get v1.0's global answer rather than a false negative; `false` only
    /// when both are known and differ.
    private func matches(_ displayID: CGDirectDisplayID?) -> Bool {
        guard let fullscreenDisplayID, let displayID else { return true }
        return fullscreenDisplayID == displayID
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
        let previousDisplayID = fullscreenDisplayID
        isFrontmostFullscreen = result.isFullscreen
        isAmbientSuppressed = decision == .suppress
        // D-06: a fullscreen window moving from one display to another (e.g. dragging a
        // fullscreen Space between built-in and Dell) must re-render even when the two booleans
        // above don't change.
        fullscreenDisplayID = result.isFullscreen ? result.displayID : nil

        // 20260912 (sliver-stuck-and-popover-glow): a fullscreen-app HANDOFF on the same display
        // (e.g. Safari's fullscreen Space handing off to Vivaldi's) changes neither
        // `isFrontmostFullscreen`, `isAmbientSuppressed` nor `fullscreenDisplayID` — measured live
        // during this task's investigation — so without also comparing `via`/`bundleID` here, that
        // transition produces zero log output and reads indistinguishable from a stuck state to
        // anyone reading `log show` after the fact.
        guard isFrontmostFullscreen != previousFullscreen
            || isAmbientSuppressed != previousSuppressed
            || fullscreenDisplayID != previousDisplayID
            || result.via != previousVia
            || result.bundleID != previousBundleID else {
            return
        }
        previousVia = result.via
        previousBundleID = result.bundleID

        // 20260912 (sliver-stuck-and-popover-glow): `matches(_:)`'s documented (T-06-06)
        // never-false-negative degrade rule treats an unresolved `fullscreenDisplayID` as "true on
        // every display" — the one path that can light up the WRONG display's sliver. Every
        // sample taken during this task's live investigation resolved correctly, so this was not
        // the reproduced bug, but it previously failed silently; flagging it here makes a future
        // occurrence diagnosable from `log show` alone.
        if isFrontmostFullscreen, fullscreenDisplayID == nil {
            logger.notice("""
                fullscreenDisplayUnresolved bundleID=\(result.bundleID ?? "none", privacy: .public) \
                via=\(result.via, privacy: .public)
                """)
        }

        // Diagnostic evidence for the on-hardware human-check (05-05-PLAN.md Task 2 / T-7h2 Task
        // 2) — the resolved values plus every reason field. This is the regression tripwire
        // RESEARCH Assumption A2 asks for (the Safari signal is a `WKFullScreenWindowController`
        // implementation detail, not a contract). No window title or now-playing metadata is ever
        // logged here. `menuBarVisible` was dropped from this line (260801-7h2-regressions): it
        // reflected my-island's OWN (nonexistent, `LSUIElement`) menu bar presentation state, never
        // Safari's, so it was always `true` and never diagnostic.
        //
        // Level is `.notice` (the default, persisted level), not `.debug`: debug-level messages
        // live only in a memory ring buffer and never reach the log store, so a later `log show`
        // could never return them — only a live stream started before the transition would catch
        // them. `.notice` lets a developer toggle fullscreen first and read the evidence with
        // `log show` afterwards. This line is only reachable at all when AppLog's verbose opt-in
        // is on (see AppLog.swift), which is what keeps a persisted level from meaning a noisy
        // shipped app. It carries a bundle identifier and boolean reason fields only — still no
        // window name and no now-playing metadata, load-bearing here because this is the one line
        // most likely to be read by a human.
        logger.notice("""
            fullscreen=\(self.isFrontmostFullscreen, privacy: .public) \
            suppressed=\(self.isAmbientSuppressed, privacy: .public) \
            displayID=\(self.fullscreenDisplayID.map(String.init) ?? "none", privacy: .public) \
            via=\(result.via, privacy: .public) \
            bundleID=\(result.bundleID ?? "none", privacy: .public) \
            isBrowser=\(isBrowser, privacy: .public) \
            axTrusted=\(axTrusted, privacy: .public) \
            subrole=\(axSubrole ?? "none", privacy: .public) \
            titleEmpty=\(axTitleIsEmpty.map(String.init) ?? "none", privacy: .public) \
            foundOwnedWindow=\(result.foundOwnedWindow, privacy: .public) \
            boundsMatchedScreen=\(result.boundsMatched, privacy: .public) \
            onFullscreenSpace=\(result.onFullscreenSpaceRaw.map(String.init) ?? "nil", privacy: .public)
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
        /// Phase 6 Plan 03 (D-06): the display `screenMatch`/the Space check matched the
        /// fullscreen window against.
        var displayID: CGDirectDisplayID?
        /// Raw `isOnFullscreenSpace(pid:)` result for the frontmost PID — logged unconditionally
        /// (260912) so a human can tell a genuine geometry/layer miss apart from a Lion-style
        /// (non-Space) fullscreen window without needing a separate debug build.
        var onFullscreenSpaceRaw: Bool?
        /// 260912: which detection path resolved `isFullscreen` — `"space"` (SkyLight genuine
        /// fullscreen Space, bounds-independent), `"bounds"` (the widened fill check), or
        /// `"none"` when nothing matched.
        var via: String = "none"
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

        // PRIMARY, bounds-independent signal (260912 fix): SkyLight's `CGSCopyManagedDisplaySpaces`
        // reports whether this pid genuinely owns a fullscreen Space, regardless of what any
        // window's on-screen bounds happen to read this poll. Previously this was only ever
        // consulted from inside the bounds loop's notch-excluded arm below — dead code on any
        // notchless display (required `safeAreaTop > 0`) and never reached at all when no
        // window's bounds matched. Checking it here first fixes both.
        let spaceCheck = Self.fullscreenSpaceCheck(pid: frontmostPID)
        result.onFullscreenSpaceRaw = spaceCheck.isOnFullscreenSpace
        if spaceCheck.isOnFullscreenSpace == true {
            result.isFullscreen = true
            result.displayID = spaceCheck.displayID
            result.via = "space"
            result.hasUsableWindowInfo = true
            return result
        }

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
            // 260912: a fully transparent window must never count as fullscreen content — the
            // Vivaldi trace showed a 1728x32 alpha=0 window alongside its real content window.
            let alpha = windowInfo[kCGWindowAlpha as String] as? Double ?? 1
            guard alpha != 0 else { continue }
            guard let boundsDict = windowInfo[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else { continue }

            result.foundOwnedWindow = true

            // SECONDARY signal, narrowed 260912-menubar-coverage-rule: a window whose bounds fill
            // a display's LITERAL FULL FRAME (menu bar included, topInset: 0 only) counts as
            // fullscreen — no "genuine Space" gate, but no longer any menu-bar/safe-area-excluded
            // candidate either. Engages only when the menu bar is actually obscured; a window that
            // stops at the menu bar (still visible) does not match here, even if maximized. See the
            // class doc's menubar-coverage-rule note for the iTerm2 consequence and the reasoning.
            if let match = screenMatch(bounds: bounds) {
                result.boundsMatched = true
                result.isFullscreen = true
                result.displayID = match
                result.via = "bounds"
                return result
            }
        }

        return result
    }

    /// Whether `bounds` fills a screen's LITERAL FULL FRAME — `topInset: 0` only, narrowed from
    /// the previous three-candidate set (260912-menubar-coverage-rule: matching the visible frame
    /// or the safe-area/menu-bar-height inset let a window that leaves the menu bar showing still
    /// count as fullscreen, which is exactly the case the user does not consider fullscreen).
    /// Compared in Quartz's top-left-origin display coordinate space via `CGDisplayBounds`, the
    /// SAME space `CGWindowListCopyWindowInfo` reports bounds in — never `NSScreen.frame`, which is
    /// Cocoa's bottom-left-origin space and would silently misalign this comparison. Returns the
    /// matched screen's `CGDirectDisplayID`, or `nil` if no screen's frame matches.
    private static func screenMatch(bounds: CGRect) -> CGDirectDisplayID? {
        for screen in NSScreen.screens {
            guard let screenNumber = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber else { continue }
            let displayID = CGDirectDisplayID(screenNumber.uint32Value)
            let displayBounds = CGDisplayBounds(displayID)

            if NotchGeometry.fillsDisplay(
                bounds: bounds, displayBounds: displayBounds, topInset: 0, tolerance: boundsTolerance
            ) {
                return displayID
            }
        }
        return nil
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

    private struct SpaceCheckResult {
        /// `nil` (undetermined — callers should fall back to another signal, never treat as "not
        /// fullscreen") only if the private symbols fail to resolve or the query itself fails.
        var isOnFullscreenSpace: Bool?
        /// The display hosting the matched fullscreen Space, resolved via the per-display dict's
        /// own `"Display Identifier"` UUID string — confirmed live on this hardware (260912
        /// probe) to match `CGDisplayCreateUUIDFromDisplayID`'s string form exactly, so this needs
        /// no bounds lookup at all. `nil` when `isOnFullscreenSpace != true`, or when true but the
        /// UUID couldn't be matched to a currently-connected `NSScreen`.
        var displayID: CGDirectDisplayID?
    }

    /// Whether `pid` currently owns a genuine fullscreen Space, per SkyLight's own per-display
    /// Spaces bookkeeping (260801-7h2-regressions round 2, measured directly across 4 states on
    /// notched hardware): a merely-maximized/zoomed window never creates a new Space — the
    /// display's "Current Space" stays `type == 0` (ordinary desktop), identical to a small
    /// windowed tab. A real `NSWindow.toggleFullScreen()` transition AND a nested
    /// `WKFullScreenWindowController` element/video fullscreen (e.g. fullscreening a video inside
    /// an already-fullscreen browser) BOTH move the display onto a dedicated Space reported here
    /// as `type == 4`, whose dict carries a `pid` field equal to the owning process — checked
    /// across every connected display so this degrades gracefully on multi-display setups.
    private static func fullscreenSpaceCheck(pid: pid_t) -> SpaceCheckResult {
        guard let cgsMainConnectionID, let cgsCopyManagedDisplaySpaces else {
            return SpaceCheckResult(isOnFullscreenSpace: nil, displayID: nil)
        }
        let connection = cgsMainConnectionID()
        guard let displays = cgsCopyManagedDisplaySpaces(connection)?.takeRetainedValue() as? [[String: Any]] else {
            return SpaceCheckResult(isOnFullscreenSpace: nil, displayID: nil)
        }
        for display in displays {
            guard let currentSpace = display["Current Space"] as? [String: Any],
                  let type = currentSpace["type"] as? Int, type == 4,
                  let spacePID = currentSpace["pid"] as? Int, pid_t(spacePID) == pid else { continue }
            let uuid = display["Display Identifier"] as? String
            return SpaceCheckResult(isOnFullscreenSpace: true, displayID: uuid.flatMap(Self.displayID(forUUIDString:)))
        }
        return SpaceCheckResult(isOnFullscreenSpace: false, displayID: nil)
    }

    /// Resolves a SkyLight `"Display Identifier"` UUID string back to the `CGDirectDisplayID` of
    /// a currently-connected `NSScreen`, via the same `displayUUID` `CGDisplayCreateUUIDFromDisplayID`
    /// string form `NSScreen+Notch.swift` already exposes.
    private static func displayID(forUUIDString uuid: String) -> CGDirectDisplayID? {
        NSScreen.screens.first { $0.displayUUID == uuid }?.displayID
    }

    // MARK: - AX reads (frontmost app's focused window only, read-only, never `kAXWindowsAttribute`)

    private static func axWindowElement(_ app: AXUIElement) -> AXUIElement? {
        var value: AnyObject?
        let status = AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value)
        guard status == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
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
