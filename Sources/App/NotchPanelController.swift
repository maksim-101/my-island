import AppKit
import SwiftUI
import OSLog
import MyIslandCore

@MainActor
final class NotchPanelController: NSObject {
    // One entry per connected screen, keyed by `NSScreen.displayKey` (Phase 6
    // SHELL-07): the interactive notch panel (fill only), the click-through
    // overlay (rim/glow/pulse/HUD-and-alert-drop drawing — replaces the old
    // non-interactive extended-pill bar, D-06 Wave 1, and 07-05's retired
    // detached HUD pill window), the per-display `NotchViewModel`, and the
    // one `FluidMotion` clock driving both the panel's and overlay's
    // geometry.
    private struct PanelSet {
        let panel: NotchPanel
        let overlay: NSPanel
        let model: NotchViewModel
        let motion: FluidMotion
    }
    private var panelSets: [String: PanelSet] = [:]
    /// 20260912 (hide-through-space-switch, bumped 20260912-hide-during-space-slide): armed on
    /// every `hideThroughSpaceSwitch`, cancelled on every `restoreAfterSpaceSwitch` — the
    /// fail-toward-visible backstop. Was 1.0s when the only hide trigger was the ~300-370ms-late
    /// tail signal (CGS identity flip / notification). Now that `FullscreenObserver`'s new
    /// bounds-based slide detector can hide as early as slide-start+~100ms, a hide from THAT
    /// trigger plus the OLD 1.0s deadline would fire at slide-start+~1100ms — squarely inside the
    /// ~1010-1110ms window where the CGS per-display identity poll (measured in
    /// `20260912-hide-through-space-switch`: flips ~29ms after the ~950-1000ms slide ends)
    /// independently re-arms the SAME hide via another `hideThroughSpaceSwitch` call. Left at 1.0s,
    /// a real switch would restore alpha to 1 (showing the stale, now-settled content) right before
    /// the CGS-triggered re-hide snapped it back to 0 — a NEW, worse flash than the one this file
    /// exists to close. 1.5s clears that window with margin. Trade-off, stated plainly: a
    /// slide-detector false positive with no real Space switch following it now blanks the pill for
    /// up to 1.5s (was 1.0s) before this backstop restores it.
    private var spaceSwitchHideTimeout: DispatchWorkItem?
    // Kept so `toggle()`/`handleMouseMoved()`/`applyHover` — which only ever
    // need "every panel", not the key — compile unchanged against the new
    // dictionary-backed storage.
    private var panels: [NotchPanel] { panelSets.values.map(\.panel) }
    private let logger = AppLog.make("NotchPanelController")
    nonisolated(unsafe) private var screenObserver: NSObjectProtocol?
    // Observe-only mouse monitors (never intercept clicks) that let a hover over
    // the timer wings drive the same dwell-to-expand as a hover over the notch.
    // The wing pill window itself is click-through (ignoresMouseEvents), so it
    // can't host tracking areas — position monitoring is how we detect the hover.
    nonisolated(unsafe) private var localMouseMonitor: Any?
    nonisolated(unsafe) private var globalMouseMonitor: Any?

    // Owned ONCE here (not inside `rebuildPanels`) so a running timer
    // survives a screen-parameter change — every rebuilt panel is injected
    // with this SAME instance, never a fresh one.
    private let timer = TimerViewModel()

    // Also owned ONCE here — the HUD providers/arbiter must not be recreated
    // per-screen or their listeners would leak/duplicate every time
    // `rebuildPanels` runs (clamshell open/close, display attach/detach).
    private let volumeProvider = VolumeProvider()
    private let brightnessProvider = BrightnessProvider()
    private let hud = HUDViewModel()

    // Owned ONCE here too, alongside the other providers above — the
    // Calendar auth state (and the fetched next event) must persist across a
    // screen-parameter rebuild and later feed the HUD. No HUD/threshold
    // callback wiring yet (that lands in plan 04-04). Exposed (not private)
    // so `AppDelegate.showSettings()` can thread this SAME instance into
    // `SettingsView`'s per-calendar picker (Task 3) rather than creating a
    // second, unsynchronized `CalendarProvider`.
    let calendarProvider = CalendarProvider()

    // Owned ONCE here too (Phase 5, D-05/D-13): the adapter subprocess must
    // survive a screen-parameter rebuild exactly like the other providers
    // above, and must be a SINGLE instance so its subprocess is never
    // launched twice. Exposed (not private) so `AppDelegate` can stop the
    // adapter subprocess at quit (D-13's "stopped at quit").
    let nowPlayingProvider = NowPlayingProvider()

    // Owned ONCE here too (Phase 5, D-10/D-11): the fullscreen signal must
    // survive a screen-parameter rebuild exactly like the other providers
    // above — creating it inside `rebuildPanels` would tear down and restart
    // its poll timer on every clamshell open/close or display change.
    private let fullscreenObserver = FullscreenObserver()

    /// Persisted key for the Settings "Show on displays without a notch" toggle (SHELL-10).
    /// Reverse-DNS style, mirroring `CalendarProvider.selectedCalendarIDsKey` — the convention
    /// for a UI-driven persisted setting, not the flat `MyIslandVerboseLogging` debug-override
    /// style. Renaming this later silently resets every existing install to the default with no
    /// migration path (this key also seeds Phase 7's "Show volume HUD" toggle).
    static let showOnNotchlessDisplaysKey = "com.myisland.showOnNotchlessDisplays"

    /// WR-04 (06-REVIEW.md): the single source of truth for the toggle's default-on behavior —
    /// both this controller's own fallback below AND `SettingsView`'s `@AppStorage` default read
    /// from this constant, so the two can no longer silently desync.
    static let showOnNotchlessDisplaysDefault = true

    /// Debug-only UserDefaults flag (never a Settings toggle — mirrors `MyIslandVerboseLogging`'s
    /// convention): when set, `makePanelSet` and every completed collapse log a `clickProbe` line
    /// so `scripts/clickthrough-probe.sh` can confirm D-04 holds on production surfaces. Under the
    /// `toggle` click-through mechanism (07-01's decision) there is nothing to alpha-probe — the
    /// probe line records `skipped mode=toggle`, and the real D-04 evidence is the `outsideClick`
    /// detector on `NotchPanel.sendEvent(_:)` logging zero swallowed outside clicks.
    static let clickProbeKey = "MyIslandClickProbe"

    /// 07-02 Task 3 (WR-04 paired-constant convention): which content the left wing shows when a
    /// timer runs WITH music (the only slot the assumption-delta decision promoted to a setting —
    /// music alone always shows artwork, a timer alone shows no left content at all). Read live via
    /// `@AppStorage` by both `SettingsView`'s picker and `WingItemsView`'s left-slot renderer, so
    /// switching needs no panel rebuild. An unknown stored value degrades to the default (T-06-08).
    static let wingLeftContentKey = "com.myisland.wingLeftContent"
    static let wingLeftContentDefault = "artwork"

    /// 07-02 Task 3 (D-07, 07-01's decision `material_decision: option`): black and Liquid Glass
    /// both ship as a Settings option, black default. The MacBook's collapsed pill stays black in
    /// every option (it merges with the camera housing) — this key only ever affects the Dell's
    /// collapsed pill and, later, other synthetic-display surfaces.
    static let surfaceMaterialKey = "com.myisland.surfaceMaterial"
    static let surfaceMaterialDefault = "black"

    /// A non-Bool value written by hand (or by a future migration bug) degrades to
    /// the default rather than crashing or reading as off (T-06-08).
    private var showOnNotchlessDisplays: Bool {
        UserDefaults.standard.object(forKey: Self.showOnNotchlessDisplaysKey) as? Bool ?? Self.showOnNotchlessDisplaysDefault
    }

    override init() {
        super.init()

        // `level` is now `Float?` (T-7h2 §1.3): a device with no readable volume property hides
        // the row rather than showing the previous device's stale value, mirroring how
        // `brightnessProvider.onChange` already guards below.
        volumeProvider.onChange = { [weak self] in
            guard let self, let level = self.volumeProvider.level else { return }
            self.hud.showVolume(level: Double(level), muted: self.volumeProvider.isMuted)
        }
        // Only wired when the private brightness bridge actually resolved —
        // an unavailable BrightnessProvider must never surface a HUD row
        // (T-03-B2). `BrightnessScale.barFraction` is applied at this single wiring point only —
        // the volume path above keeps passing its raw level through unchanged (T-7h2 Task 1 step D).
        if brightnessProvider.isAvailable {
            brightnessProvider.onChange = { [weak self] in
                guard let self, let level = self.brightnessProvider.level else { return }
                self.hud.showBrightness(level: Double(BrightnessScale.barFraction(for: level)))
            }
        }
        // 07-05 (FLUID-02, closes Phase 6 gap G1): the HUD/alert is now a drop of the notch's own
        // fluid family that swells out of, and recedes back into, whatever each display's own
        // collapsed surface currently shows (pill, Dell pill or fullscreen bulge) — drawn by
        // `FluidOverlayView`'s click-through window, never a separate detached pill/window. `hud`
        // stays the single arbiter for content; this wiring only drives the drop's OWN geometry
        // (`FluidMotion`'s `.dropOffset/.dropHeight/.dropHalfWidth/.dropAlpha` channels) on every
        // panel set that is currently collapsed — an open (expanded) panel has no drop concept.
        // The HUD already broadcast to every connected display before this plan (one detached
        // pill per screen, all showing the same `hud` state); this preserves that.
        hud.onVisibilityChange = { [weak self] visible in
            guard let self else { return }
            for set in self.panelSets.values where set.model.isOpen != true {
                if visible {
                    self.startAlertDrop(on: set.panel, motion: set.motion)
                } else {
                    self.endAlertDrop(on: set.panel, motion: set.motion)
                }
            }
        }

        // Meeting bump (CAL-01/D-02): same [weak self] guard-let idiom as
        // volumeProvider.onChange/brightnessProvider.onChange above — the bump reuses the same
        // `hud` arbiter and drop mechanism above, not a dedicated panel window.
        // calendarProvider's own init() already kicks off the initial
        // fetch/scheduling when authorization is already granted.
        calendarProvider.onThresholdCrossed = { [weak self] event, lead in
            guard let self else { return }
            self.hud.showMeeting(title: event.title, lead: lead, joinURL: event.joinURL)
        }

        // `onChange` fires whenever `FullscreenObserver` detects a fullscreen transition on any
        // display. 07-02 (D-06 Wave 1) retired the fullscreen-sliver frame shrink this hook used to
        // drive, along with the extended-pill bar window that rendered it (D-05) — the fluid
        // collapsed pill's own frame no longer varies with fullscreen state at all, so there is
        // nothing left to resize here beyond the ordinary `resolvedFrame` reapply every other
        // geometry change already does. The hook stays wired (a fullscreen transition can still
        // coincide with other pending frame work, and a synthetic panel's `pendingCollapse == nil`
        // guard still applies) and keeps logging the raw per-display detection signal for
        // on-hardware correlation, under a name that no longer implies a visual sliver exists.
        fullscreenObserver.onChange = { [weak self] in
            guard let self else { return }
            for (key, set) in self.panelSets {
                guard !set.panel.isPhysical else { continue }
                let active = self.fullscreenObserver.isFrontmostFullscreen(on: set.panel.displayID)
                self.logger.notice("fullscreenState key=\(key, privacy: .public) active=\(active, privacy: .public)")
                guard set.model.isOpen != true, set.panel.pendingCollapse == nil else { continue }
                // 07-04 Task 1 (FLUID-01, agreement §1): the pill becomes the fullscreen bulge (or
                // back) in one snap, never a spring — the 20260912 no-morph decision for Space
                // switches stands. `jump(to:)` resolves the new rest params itself via
                // `collapsedParams(for:)`, which re-reads the fullscreen state this hook just
                // observed, so the two can never disagree about which shape is now current.
                set.motion.jump(to: self.collapsedParams(for: set.panel))
                set.panel.setFrame(self.resolvedFrame(for: set.panel), display: true)
                (set.panel.contentView as? HoverTrackingView)?.hoverRect = nil
            }
        }

        // 20260912 (hide-through-space-switch, extended 20260912-hide-during-space-slide):
        // `.stationary` keeps all three windows fixed on screen through a Space switch's
        // ~950-1000ms visible OS slide, showing stale pre-switch content the whole time unless
        // hidden. `onSpaceChangeDetected` now fires from TWO sources in `FullscreenObserver`: its
        // original CGS per-display identity poll (fires at the slide's tail, ~300-370ms ahead of
        // the old notification-only reaction) and a newer bounds-based slide detector (fires
        // within ~100ms of the slide STARTING). Both call this same closure — a second call while
        // already hidden is a harmless re-arm of the timeout in `hideThroughSpaceSwitch`, see that
        // method's updated 1.5s timeout comment for why the deadline was bumped to absorb it.
        // Restoring on `onSpaceSettled` converts the measured window (now most of the slide, not
        // just its tail) from "visibly wrong content" to "briefly absent," per the user's stated
        // preference.
        fullscreenObserver.onSpaceChangeDetected = { [weak self] displayIDs in
            self?.hideThroughSpaceSwitch(affecting: displayIDs)
        }
        fullscreenObserver.onSpaceSettled = { [weak self] in
            self?.restoreAfterSpaceSwitch(reason: "settled")
        }

        rebuildPanels()

        // T-02-03 (02-SECURITY.md): a non-global replacement was evaluated first and rejected —
        // three checkable facts about this file rule it out. (a) The wing/bar panel window is
        // created click-through by design (its ignoresMouseEvents flag), so it cannot host a
        // tracking area — a tracking area needs a window that actually hit-tests the cursor.
        // (b) The interactive notch panel's HoverTrackingView tracking area is pinned to that
        // window's own content rect, which spans only the notch cutout, not the wider wing
        // strip — the wings sit outside the tracked region. (c) This app is LSUIElement and
        // never activates, and the interactive panel never opts in to mouse-moved events, so a
        // mouse-moved event over the wings while another app is frontmost never enters this
        // app's own event queue for a local monitor to see. The only way to make the wing strip
        // itself hit-testable would be a non-click-through window sitting on the menu-bar strip
        // beside the notch — which would swallow clicks on menu-bar and status items there, a
        // worse outcome than this finding.
        //
        // The monitor below is therefore kept, with the trade-off made explicit: it is
        // observe-only and non-consuming — it reads mouse-movement position only, never a
        // keystroke event mask, and never a low-level event-tap creation/enable call — so it
        // needs no TCC grant of any kind, and neither Info.plist nor MyIsland.entitlements
        // declares an input-monitoring or accessibility usage key. It lets a hover over a timer
        // wing expand the notch like a hover over the notch itself. Global fires while another
        // app is active (the usual case for this accessory app); local fires while our own
        // Settings window is key.
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            self?.handleMouseMoved()
            return event
        }
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            self?.handleMouseMoved()
        }

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.rebuildPanels()
            }
        }
    }

    deinit {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
    }

    /// Reconciles `panelSets` against the current `NSScreen.screens` by display key (Phase 6
    /// SHELL-09), replacing the old full-teardown/rebuild: on every
    /// `NSApplication.didChangeScreenParametersNotification` (clamshell open/close, display
    /// attach/detach, scaled-resolution switch) — and at launch, from an initially empty
    /// `panelSets` — this diffs the desired display-key set against the live one and touches only
    /// what changed. A key that disappeared is torn down; a brand-new key is created; a kept key
    /// whose anchor rect or anchor Y moved (the D-10c scaled-mode case: pill 197→240pt) is torn
    /// down and recreated so it counts as `rebuilt`, not `added`+`removed`; every other surviving
    /// key's windows, `NotchViewModel`, open state and pending hover/dwell work items are left
    /// completely untouched — a running timer on one screen must not blink when a different
    /// screen connects, disconnects, or changes mode. No display-unit-number heuristic of any kind
    /// is ever consulted (the built-in reports unit number 0 on this hardware; filtering
    /// on it would drop the built-in itself) — an unfiltered ghost-display blip from the
    /// notification storm (RESEARCH Pitfall 1) simply resolves to one extra reconcile that the
    /// next notification removes, never a crash or full-app teardown. Not `private` —
    /// `SettingsView`'s "Show on displays without a notch" toggle (SHELL-10) calls this directly
    /// so flipping it reconciles live, without a restart.
    func rebuildPanels() {
        // Every screen resolves to a Mode — physical cutout or synthetic top-center pill (Phase 6
        // SHELL-06/07) — except a synthetic-mode screen while the toggle is off, which is skipped
        // entirely: full dormancy (no pill, no HUD, nothing for the hotkey to open there). The
        // built-in's `.physical` set is never skipped by this or any other condition.
        var desired: [String: (screen: NSScreen, mode: NotchGeometry.Mode)] = [:]
        for screen in NSScreen.screens {
            let mode = screen.notchMode
            if !mode.isPhysical && !showOnNotchlessDisplays { continue }
            desired[screen.displayKey] = (screen, mode)
        }

        let diff = DisplaySetDiff(previous: Set(panelSets.keys), current: Set(desired.keys))

        for key in diff.removed {
            if let set = panelSets.removeValue(forKey: key) {
                tearDown(set)
            }
        }

        var rebuilt = 0
        var kept = 0
        for key in diff.kept {
            guard let set = panelSets[key], let (screen, mode) = desired[key] else { continue }
            if set.panel.notchFrame != mode.anchorRect || set.panel.anchorMaxY != screen.frame.maxY || set.panel.isPhysical != mode.isPhysical || set.panel.menuBarHeight != screen.menuBarHeight {
                // WR-02 (06-REVIEW.md): a fresh `NotchViewModel` always starts collapsed — carry
                // the torn-down set's open state forward through the SAME code path a hover/hotkey
                // open uses (`toggle()`), rather than reaching into the new model's private dwell
                // state directly, so frame/animation bookkeeping stays consistent with every other
                // open trigger.
                let wasOpen = set.model.isOpen
                tearDown(set)
                let newSet = makePanelSet(for: screen, mode: mode, key: key)
                panelSets[key] = newSet
                if wasOpen {
                    withAnimation(NotchLayout.morphAnimation) {
                        newSet.model.toggle()
                    }
                }
                rebuilt += 1
            } else {
                reapplyFrames(to: set, screen: screen, mode: mode, key: key)
                kept += 1
            }
        }

        for key in diff.added {
            guard let (screen, mode) = desired[key] else { continue }
            panelSets[key] = makePanelSet(for: screen, mode: mode, key: key)
        }

        // `.notice` persists to the log store even in Release (`.info` does not — see
        // FullscreenObserver.swift). A no-op notification (same keys, same geometry) logs
        // added=0 removed=0 rebuilt=0 kept=N — the storm case from RESEARCH Pitfall 1 degrades to
        // zero window churn, still observable in the log.
        logger.notice("reconcile added=\(diff.added.count, privacy: .public) removed=\(diff.removed.count, privacy: .public) rebuilt=\(rebuilt, privacy: .public) kept=\(kept, privacy: .public) total=\(self.panelSets.count, privacy: .public)")
    }

    /// 260912 SC4 kept-set-reposition fix: `rebuildPanels()`'s `kept` branch previously did
    /// nothing at all once it decided a set's anchor math hadn't changed — but "the app's own
    /// anchor math agrees with itself" doesn't guarantee the WINDOWS are still where that math
    /// says they should be. Observed on-hardware: a display disconnect left the surviving
    /// display's panel/bar/hud windows displaced (uniformly, by the same offset on all three) even
    /// though the reconcile logged `kept=1` — root mechanism not fully established (plausibly
    /// WindowServer's own display-removal window-rescue behavior, independent of this app's frame
    /// bookkeeping), but the fix is correct regardless of cause: always re-assert the trusted
    /// anchor onto every kept window. Cheap (`setFrame` only, no window create/destroy) and a
    /// genuine no-op — no log line, no `setFrame` call — whenever nothing actually drifted, so
    /// SHELL-09's "zero window churn on a no-op notification" contract is unaffected.
    private func reapplyFrames(to set: PanelSet, screen: NSScreen, mode: NotchGeometry.Mode, key: String) {
        set.panel.notchFrame = mode.anchorRect
        set.panel.anchorMaxY = screen.frame.maxY
        set.panel.screenFrame = screen.frame

        let panelTarget = resolvedFrame(for: set.panel)
        if set.panel.frame != panelTarget {
            logger.notice("kept-reapplied key=\(key, privacy: .public) window=panel before=\(NSStringFromRect(set.panel.frame), privacy: .public) after=\(NSStringFromRect(panelTarget), privacy: .public)")
            set.panel.setFrame(panelTarget, display: true)
        }

        let overlayQ = collapsedParams(for: set.panel)
        let overlayTarget = Self.overlayPanelFrame(notchFrame: set.panel.notchFrame, anchorMaxY: set.panel.anchorMaxY, q: overlayQ)
        if set.overlay.frame != overlayTarget {
            logger.notice("kept-reapplied key=\(key, privacy: .public) window=overlay before=\(NSStringFromRect(set.overlay.frame), privacy: .public) after=\(NSStringFromRect(overlayTarget), privacy: .public)")
            set.overlay.setFrame(overlayTarget, display: true)
        }
    }

    /// 20260912 (hide-through-space-switch): sets `alphaValue = 0` on all three windows of the
    /// affected panel set(s) — never `orderOut`/`close`, which would detach the window from
    /// AppKit's window list and interact with `.canJoinAllSpaces`/`.stationary` for no benefit, and
    /// never touches `panelSets` itself, so `rebuildPanels()`'s `added`/`removed`/`rebuilt`/`kept`
    /// accounting is completely unaffected — a hide is not a teardown. `displayIDs == nil` (the
    /// change was detected but couldn't be attributed to a specific display) falls back to hiding
    /// every eligible panel set, matching this class's own no-false-negative convention elsewhere
    /// (`FullscreenObserver.matches(_:)`'s T-06-06 degrade rule) — briefly hiding an unaffected
    /// display's island is a harmless, momentary no-op compared to showing wrong content on the
    /// affected one. A panel whose own `displayID` is unresolved is included in ANY non-empty
    /// `displayIDs` set for the same reason. **Physical (built-in notch) panel sets are always
    /// excluded** — mirrors `fullscreenObserver.onChange`'s own `!set.panel.isPhysical` guard
    /// above: the reported flash and the user's fix request are specific to the Dell's synthetic
    /// pill switching between full content and the sliver; the physical notch has no matching
    /// defect, and blinking its timer/now-playing readout on every Space switch would be new,
    /// unrequested, user-visible behavior on a display nothing was wrong with.
    private func hideThroughSpaceSwitch(affecting displayIDs: Set<CGDirectDisplayID>?) {
        let targets: [PanelSet]
        if let displayIDs, !displayIDs.isEmpty {
            targets = panelSets.values.filter { set in
                guard !set.panel.isPhysical else { return false }
                guard let id = set.panel.displayID else { return true }
                return displayIDs.contains(id)
            }
        } else {
            targets = panelSets.values.filter { !$0.panel.isPhysical }
        }
        guard !targets.isEmpty else { return }

        spaceSwitchHideTimeout?.cancel()
        for set in targets {
            set.panel.alphaValue = 0
            set.overlay.alphaValue = 0
        }
        logger.notice("islandHide count=\(targets.count, privacy: .public)")

        let timeout = DispatchWorkItem { [weak self] in
            self?.restoreAfterSpaceSwitch(reason: "timeout")
        }
        spaceSwitchHideTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: timeout)
    }

    /// 20260912 (hide-through-space-switch): unconditional restore of every panel set, regardless
    /// of which one(s) `hideThroughSpaceSwitch` actually hid — setting `alphaValue = 1` on an
    /// already-visible window (including every physical set, never hidden by this mechanism at
    /// all) is a harmless no-op, and this keeps the fail-toward-visible guarantee simple (no
    /// bookkeeping of which sets were hidden that could itself go stale). A set created fresh by
    /// `makePanelSet` during the hidden window is unaffected either way — new `NSPanel`s default to
    /// `alphaValue == 1`. A set torn down mid-hide is `close()`d by `tearDown`, which this never
    /// races against (both run on the main actor). `reason` (`"settled"` from
    /// `fullscreenObserver.onSpaceSettled`, `"timeout"` from the fail-safe above) is logged only —
    /// this is the ordering evidence the plan asked for: a live `log show` should show
    /// `islandRestore` timestamped after that display's `sliverState`/`pillState` line for the new
    /// state when `reason=settled` (proving render-before-restore); a `reason=timeout` line with no
    /// preceding `islandRestore reason=settled` for the same hide is the tell that the settle path
    /// was lost and the backstop, not the primary path, is what un-hid the island.
    private func restoreAfterSpaceSwitch(reason: String) {
        spaceSwitchHideTimeout?.cancel()
        spaceSwitchHideTimeout = nil
        for set in panelSets.values {
            set.panel.alphaValue = 1
            set.overlay.alphaValue = 1
        }
        logger.notice("islandRestore reason=\(reason, privacy: .public)")
    }

    /// Cancels pending hover/dwell work items and closes all three windows for a panel set — the
    /// same three steps the old full-teardown loop performed per screen, extracted so both the
    /// reconcile's `removed` and `rebuilt` paths share it. `close()` (not `orderOut(nil)`, which
    /// only hides a window) is what detaches each window from AppKit's own window list — that
    /// detach, combined with the set leaving `panelSets` (the caller's `removeValue(forKey:)`), is
    /// what lets ARC actually free the windows afterward. `isReleasedWhenClosed = false` on all
    /// three window kinds is exactly what makes this caller-driven `close()` safe.
    private func tearDown(_ set: PanelSet) {
        set.panel.pendingCollapse?.cancel()
        set.panel.pendingDwellOpen?.cancel()
        set.panel.pendingHoverClose?.cancel()
        set.motion.stopClock()
        set.panel.close()
        set.overlay.close()
    }

    /// Builds a fresh `PanelSet` for one screen — extracted from the old inline creation loop so
    /// the reconcile's `added` and `rebuilt` paths (Task 2) share identical construction.
    private func makePanelSet(for screen: NSScreen, mode: NotchGeometry.Mode, key: String) -> PanelSet {
        let anchorRect = mode.anchorRect
        let anchorMaxY = screen.frame.maxY

        let model = NotchViewModel()
        // 07-04 Task 1: a synthetic display that ARRIVES already fullscreen (e.g. the Dell
        // reconnects while its one window is already in native fullscreen) starts the clock at
        // the bulge's own rest params, not the desktop pill's — `fullscreenObserver.onChange`
        // only fires on a LATER transition, so this is the one path that hook can never cover.
        let startsAsBulge = !mode.isPhysical && fullscreenObserver.isFrontmostFullscreen(on: screen.displayID)
        let restParams = startsAsBulge ? .fullscreenBulge(width: anchorRect.width) : Self.collapsedParams(isPhysical: mode.isPhysical, notchFrame: anchorRect, menuBarHeight: screen.menuBarHeight)
        let motion = FluidMotion(rest: restParams)
        motion.startClock(on: screen)

        let panel = Self.makePanel(notchFrame: anchorRect, screen: screen, isPhysical: mode.isPhysical, model: model, motion: motion, timer: timer, calendar: calendarProvider, nowPlaying: nowPlayingProvider, fullscreen: fullscreenObserver, displayKey: key, hud: hud)
        panel.displayID = screen.displayID
        // `makePanel`'s own window sizing is the static, non-fullscreen-aware
        // `collapsedSurfaceFrame(isPhysical:notchFrame:anchorMaxY:)` (it has no panel/displayID to
        // query yet) — reapply now that `displayID` is set, so a fresh bulge starts at its own
        // (shallower) window frame rather than the desktop pill's.
        if startsAsBulge {
            panel.setFrame(resolvedFrame(for: panel), display: true)
        }
        model.onOpenChange = { [weak self, weak panel] isOpen in
            guard let self, let panel else { return }
            // 07-05 Task 3 (sketch's own `openBand`): opening the band — by hover-dwell or the
            // global hotkey, either path lands here via `NotchViewModel` — ends any HUD/alert
            // drop immediately rather than letting it linger under the expanding band.
            if isOpen { self.hud.dismissNow() }
            self.applyFrame(to: panel, isOpen: isOpen)
        }
        panel.orderFrontRegardless()

        let overlay = Self.makeOverlayPanel(notchFrame: anchorRect, anchorMaxY: anchorMaxY, isPhysical: mode.isPhysical, menuBarHeight: screen.menuBarHeight, motion: motion, model: model, timer: timer, fullscreen: fullscreenObserver, displayID: screen.displayID, hud: hud)
        overlay.orderFrontRegardless()

        // The printed height distinguishes the launched-app menu-bar value from the 22pt
        // status-bar fallback.
        logger.notice("panel set key=\(key, privacy: .public) mode=\(mode.isPhysical ? "physical" : "synthetic", privacy: .public) anchor=\(NSStringFromRect(anchorRect), privacy: .public) menuBar=\(screen.menuBarHeight, privacy: .public)")
        logClickProbeAfterDelay(key: key)

        return PanelSet(panel: panel, overlay: overlay, model: model, motion: motion)
    }

    /// 07-05 Task 3 (FLUID-02/PANEL-07): the HUD/alert drop's rest size for a given panel —
    /// `AlertDropLayout.hud` while `hud.meeting` is nil, or the meeting's own title-measured size
    /// (`AlertDropView.measuredMeetingSize`, shared with that view's own content layout) when a
    /// meeting is showing. `hasLink` tells the caller whether this panel's own interactive window
    /// needs to grow to cover the drop (only a linked meeting draws there at all).
    private func dropSize(for panel: NotchPanel) -> (halfWidth: CGFloat, height: CGFloat, hasLink: Bool) {
        if let meeting = hud.meeting {
            let sized = AlertDropView.measuredMeetingSize(title: meeting.title, lead: meeting.lead, hasJoin: meeting.joinURL != nil, isPhysical: panel.isPhysical)
            return (sized.halfWidth, sized.height, meeting.joinURL != nil)
        }
        let (halfWidth, height) = AlertDropLayout.hud(isPhysical: panel.isPhysical)
        return (halfWidth, height, false)
    }

    /// Starts the HUD/alert drop's fall on one panel's own `FluidMotion` clock — ported from the
    /// sketch's `startExtra` (index.html:390-403): jumps to a small, narrow, fully-transparent
    /// drop just below the floor, then springs it to full size while it falls, fading its content
    /// in only once it has visibly separated (260ms). `hud.onVisibilityChange`'s wiring above calls
    /// this on every currently-collapsed panel simultaneously.
    private func startAlertDrop(on panel: NotchPanel, motion: FluidMotion) {
        let size = dropSize(for: panel)
        motion.jumpChannel(.dropOffset, to: -size.height * 0.6)
        motion.jumpChannel(.dropHeight, to: size.height * 0.6)
        motion.jumpChannel(.dropHalfWidth, to: min(size.halfWidth, 100) * 0.4)
        motion.jumpChannel(.dropAlpha, to: 0)
        motion.setChannel(.dropHeight, to: size.height, response: FluidMotionPreset.droplet.response * 1.2, damping: FluidMotionPreset.droplet.damping)
        motion.setChannel(.dropHalfWidth, to: size.halfWidth, response: FluidMotionPreset.droplet.response * 1.6, damping: FluidMotionPreset.droplet.damping)
        motion.setChannel(.dropOffset, to: 8, response: FluidMotionPreset.droplet.response * 1.5, damping: FluidMotionPreset.droplet.damping)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.26) { [weak motion] in
            motion?.setChannel(.dropAlpha, to: 1, response: 0.4, damping: 1)
        }

        // 07-05 Task 3 (T-07-01): a linked meeting drop's Join lives in the interactive panel, so
        // that window's own frame must grow — once, here, never per animation frame — to the
        // union of the collapsed bounding box and the drop's own full extent (±halfWidth, down to
        // baseY+8+height+8) before Join can take a click.
        guard size.hasLink, panel.viewModel?.isOpen != true else { return }
        panel.pendingDropFrameRestore?.cancel()
        panel.pendingDropFrameRestore = nil
        let baseY = FluidShapeGeometry.floorY(x: 0, q: motion.params, cx: 0)
        let collapsed = collapsedSurfaceFrame(for: panel)
        let dropBottom = baseY + 8 + size.height + 8
        let grownWidth = max(collapsed.width, size.halfWidth * 2)
        let grownHeight = max(collapsed.height, dropBottom)
        let grown = NSRect(
            x: panel.notchFrame.midX - grownWidth / 2,
            y: panel.anchorMaxY - grownHeight,
            width: grownWidth,
            height: grownHeight
        )
        panel.setFrame(grown, display: true)
    }

    /// Ends the drop — ported from `endExtra` (index.html:404-410): fades its content out fast,
    /// then it rises back into the floor and merges. `dropHeight` is deliberately left untouched
    /// (the sketch's own `endExtra` never resets it either) — once `dropOffset` rises far enough,
    /// `AlertDropView`'s own `dropVisible` gate hides the whole drop regardless of its height. A
    /// grown interactive-panel frame (above) shrinks back once the retract animation has had time
    /// to settle, never per frame.
    private func endAlertDrop(on panel: NotchPanel, motion: FluidMotion) {
        let size = dropSize(for: panel)
        motion.setChannel(.dropAlpha, to: 0, response: 0.14, damping: 1)
        motion.setChannel(.dropOffset, to: -size.height - 4, response: FluidMotionPreset.close.response * 1.25, damping: FluidMotionPreset.close.damping)
        motion.setChannel(.dropHalfWidth, to: size.halfWidth * 0.6, response: FluidMotionPreset.close.response * 1.3, damping: FluidMotionPreset.close.damping)

        guard size.hasLink, panel.viewModel?.isOpen != true else { return }
        let work = DispatchWorkItem { [weak self, weak panel] in
            guard let self, let panel, panel.viewModel?.isOpen != true else { return }
            panel.setFrame(self.resolvedFrame(for: panel), display: true)
        }
        panel.pendingDropFrameRestore = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3, execute: work)
    }

    /// D-04 regression evidence for `scripts/clickthrough-probe.sh` (Task 1/2): only active when
    /// `clickProbeKey` is set. Under the `toggle` click-through mechanism there is no alpha
    /// hit-test to probe — see `clickProbeKey`'s doc comment — so this always logs the `skipped`
    /// form; the real evidence is `NotchPanel.sendEvent(_:)`'s `outsideClick` detector logging zero
    /// swallowed outside clicks over the same run.
    private func logClickProbeAfterDelay(key: String) {
        guard UserDefaults.standard.bool(forKey: Self.clickProbeKey) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.logClickProbeNow(key: key)
        }
    }

    private func logClickProbeNow(key: String) {
        guard UserDefaults.standard.bool(forKey: Self.clickProbeKey) else { return }
        logger.notice("clickProbe skipped mode=toggle display=\(key, privacy: .public)")
    }

    private static func makePanel(notchFrame: NSRect, screen: NSScreen, isPhysical: Bool, model: NotchViewModel, motion: FluidMotion, timer: TimerViewModel, calendar: CalendarProvider, nowPlaying: NowPlayingProvider, fullscreen: FullscreenObserver, displayKey: String, hud: HUDViewModel) -> NotchPanel {
        let anchorMaxY = screen.frame.maxY
        let collapsedFrame = Self.collapsedSurfaceFrame(isPhysical: isPhysical, notchFrame: notchFrame, anchorMaxY: anchorMaxY, menuBarHeight: screen.menuBarHeight)
        let styleMask: NSWindow.StyleMask = [.borderless, .nonactivatingPanel, .utilityWindow]

        // The panel window is created at the COLLAPSED (fluid pill) size, not the
        // expanded size — this is the core fix for the dead click-zone: when
        // collapsed there is no window area below the pill, so nothing there
        // can be blocked. `applyFrame(to:isOpen:)` resizes it as the model
        // opens/closes.
        let panel = NotchPanel(contentRect: collapsedFrame, styleMask: styleMask, backing: .buffered, defer: false)
        panel.viewModel = model
        panel.notchFrame = notchFrame
        panel.anchorMaxY = anchorMaxY
        panel.isPhysical = isPhysical
        // 07-15 gap closure (D-06 row 1): the display's own measured menu-bar height, read once
        // here — `collapsedParams(for:)` derives the MacBook pill's depth from it instead of a
        // fixed constant. A later change is caught by `rebuildPanels()`'s kept-vs-rebuilt check.
        panel.menuBarHeight = screen.menuBarHeight
        panel.screenFrame = screen.frame
        panel.motion = motion
        panel.displayKey = displayKey

        let hostingView = NonKeyHostingView(rootView: NotchContentView(model: model, motion: motion, timer: timer, calendar: calendar, nowPlaying: nowPlaying, fullscreen: fullscreen, displayID: screen.displayID, hud: hud, isPhysical: isPhysical))
        // Decouple from the window's Auto Layout / constraint-update cycle:
        // `applyFrame` resizes the panel manually via `setFrame`, and letting
        // the hosting view participate in constraint-based sizing causes an
        // uncaught NSException (abort) the first time that manual resize
        // fires. Frame/autoresize-based sizing avoids the window display
        // cycle entirely while still tracking the window's content bounds.
        hostingView.sizingOptions = []
        hostingView.translatesAutoresizingMaskIntoConstraints = true

        // The hosting view is NOT the window's contentView. `NSHostingView`
        // calls `updateAnimatedWindowSize(_:)` on ITS OWN WINDOW whenever it
        // detects a `windowDidLayout` pass — if it IS the contentView, that
        // resizes the panel directly and collides with `applyFrame`'s manual
        // `setFrame`, aborting with an uncaught NSException. Wrapping it in a
        // plain `NSView` container means the window's contentView is never an
        // `NSHostingView`, so no window-resize feedback can originate from
        // SwiftUI's layout pass — `applyFrame` remains the ONLY code that
        // resizes the window.
        let expandedWidth = NotchLayout.expandedWidth
        let expandedHeight = NotchLayout.expandedHeight

        // A plain `NSView` cannot be relied upon for hover detection here:
        // `ExpandedPanelView`'s `KeyboardShortcuts.Recorder` (an AppKit
        // `NSView` bridged via `NSViewRepresentable`) is positioned on the
        // left of the panel and does not reliably honor SwiftUI's
        // `.allowsHitTesting(false)` for its own event tracking, so it
        // silently swallows hover over the left half of the collapsed notch
        // and SwiftUI's `.onHover` never fires there (SHELL-11). A
        // `NSTrackingArea` on this container — whose bounds always equal the
        // window's full content rect, collapsed or expanded — sidesteps
        // SwiftUI/NSView hit-testing entirely and is coordinate-exact for
        // both notch halves.
        let container = HoverTrackingView(frame: NSRect(origin: .zero, size: collapsedFrame.size))
        container.autoresizesSubviews = true
        container.wantsLayer = true
        container.layer?.masksToBounds = true

        // Fixed at the expanded size (matches the constant SwiftUI content
        // size in `NotchContentView`), centered horizontally and top-pinned
        // within the container. While the container is collapsed (notch
        // sized), only the top-center notch region is visible; the rest is
        // clipped by `masksToBounds`. When `applyFrame` grows the window, the
        // full hosting content becomes visible without ever resizing itself.
        hostingView.frame = NSRect(
            x: (container.bounds.width - expandedWidth) / 2,
            y: container.bounds.height - expandedHeight,
            width: expandedWidth,
            height: expandedHeight
        )
        // Horizontal centering + top-pinning across window resizes is owned by
        // `HoverTrackingView.resizeSubviews(withOldSize:)`, NOT an
        // `autoresizingMask`. The mask corrupts this: because the hosting view
        // is WIDER than the collapsed container (expandedWidth 2.2× the notch),
        // AppKit's autoresizing snaps the overflowing view to x=0 on the
        // collapsed→HUD-bump `setFrame` (height grows, width stays notch-sized),
        // which right-shifts the centered HUD content into the clipped right
        // half of the notch (only half the bump shows). Verified via an
        // offscreen render harness reproducing the exact geometry.
        container.addSubview(hostingView)
        container.onHoverChange = { [weak panel] hovering in
            guard let panel else { return }
            panel.notchHovering = hovering
            NotchPanelController.applyHover(panel: panel)
        }
        panel.contentView = container

        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = false
        panel.isReleasedWhenClosed = false
        // Stay non-activating, but allow the panel to become key ONLY when a
        // view that needs first-responder status is clicked — i.e. the duration
        // text field. Plain buttons (Start, presets) don't trigger it, so the
        // ambient overlay never steals focus except to accept typed input.
        panel.becomesKeyOnlyIfNeeded = true

        return panel
    }

    /// D-06 Wave 1 (07-02): the fluid pill's own rest parameters for a given display — the single
    /// source `makePanel`'s initial window size, `resolvedFrame(for:)`'s collapsed target,
    /// `makeOverlayPanel`'s sizing, and `handleMouseMoved`'s dwell/sticky-pull math all read, so
    /// none of them can disagree about how big the collapsed pill currently is. Physical derives
    /// `.macBookPill(menuBarHeight:notchHeight:)` from the display's own measured menu-bar height (257pt wide, 18pt shoulders,
    /// 3pt sag, 07-DESIGN-AGREEMENT.md §1 amended 2026-09-27 — 07-15 gap closure); synthetic
    /// derives a pill sized to the anchor's own damped-width/menu-bar-height rect exactly as
    /// before.
    private static func collapsedParams(isPhysical: Bool, notchFrame: NSRect, menuBarHeight: CGFloat) -> FluidParams {
        isPhysical ? .macBookPill(menuBarHeight: menuBarHeight, notchHeight: notchFrame.height) : .desktopPill(width: notchFrame.width, height: notchFrame.height)
    }

    /// 07-04 Task 1 (FLUID-01, agreement §1/§5): a collapsed synthetic panel whose own display is
    /// the frontmost-fullscreen one shows the bulge instead of the desktop pill — the retired
    /// sliver's replacement. Physical panels never branch here (`isFullscreenBulge` always false
    /// for them), matching this file's own `!set.panel.isPhysical` convention everywhere else
    /// fullscreen state is read.
    private func collapsedParams(for panel: NotchPanel) -> FluidParams {
        if isFullscreenBulge(for: panel) {
            return .fullscreenBulge(width: panel.notchFrame.width)
        }
        return Self.collapsedParams(isPhysical: panel.isPhysical, notchFrame: panel.notchFrame, menuBarHeight: panel.menuBarHeight)
    }

    /// True only for a collapsed (never open — plan 08's band owns the expanded fullscreen state)
    /// synthetic panel on the display `fullscreenObserver.isFrontmostFullscreen(on:)` currently
    /// reports as fullscreen — the plain app-fullscreen signal the retired sliver used (menu bar
    /// actually obscured, 20260912 decision).
    private func isFullscreenBulge(for panel: NotchPanel) -> Bool {
        !panel.isPhysical && panel.viewModel?.isOpen != true && fullscreenObserver.isFrontmostFullscreen(on: panel.displayID)
    }

    /// The interactive panel's collapsed window frame: the fluid outline's own bounding box
    /// (`2·half` wide — the curve's endpoints sit exactly at `cx ∓ half`), centered on the anchor,
    /// top flush with the screen, `d + sag + 6` tall — the extra 6pt is room for the sticky belly's
    /// live pull so a hover just past the drawn floor still passes clicks through the transparent
    /// margin rather than hitting dead window past the shape.
    private static func collapsedSurfaceFrame(isPhysical: Bool, notchFrame: NSRect, anchorMaxY: CGFloat, menuBarHeight: CGFloat) -> NSRect {
        let q = collapsedParams(isPhysical: isPhysical, notchFrame: notchFrame, menuBarHeight: menuBarHeight)
        let width = q.half * 2
        let height = q.d + q.sag + 6
        return NSRect(
            x: notchFrame.midX - width / 2,
            y: anchorMaxY - height,
            width: width,
            height: height
        )
    }

    /// 07-04 Task 1: routed through the instance `collapsedParams(for:)` above (not the static
    /// isPhysical/notchFrame-only variant `makePanel`'s initial window sizing still uses) so a
    /// panel currently showing the bulge gets the bulge's own — shallower — window height, "the
    /// bulge's bounding box plus the 6pt sticky room" exactly as `collapsedSurfaceFrame`'s own doc
    /// comment already promised for the pill case.
    private func collapsedSurfaceFrame(for panel: NotchPanel) -> NSRect {
        let q = collapsedParams(for: panel)
        let width = q.half * 2
        let height = q.d + q.sag + 6
        return NSRect(
            x: panel.notchFrame.midX - width / 2,
            y: panel.anchorMaxY - height,
            width: width,
            height: height
        )
    }

    /// The click-through overlay's frame (Task 1): wider/taller than the interactive panel by a
    /// fixed margin so the rim stroke and glow blur (both drawn outside the fill's own edge) never
    /// clip — `ceil(max(2·half·1.12, 160) + 24)` wide, `ceil(d + sag + 48)` tall, centered on the
    /// same anchor and top-flush, so both windows agree on the shape's global center (`cx`) even
    /// though their own local widths differ.
    private static func overlayPanelFrame(notchFrame: NSRect, anchorMaxY: CGFloat, q: FluidParams) -> NSRect {
        let width = ceil(max(2 * q.half * 1.12, 160) + 24)
        let height = ceil(q.d + q.sag + 48)
        return NSRect(
            x: notchFrame.midX - width / 2,
            y: anchorMaxY - height,
            width: width,
            height: height
        )
    }

    /// The click-through overlay window (replaces the old non-interactive "extended pill" bar):
    /// `ignoresMouseEvents = true` always — it draws rim/glow (`FluidOverlayView`) over the
    /// interactive panel's fill and never shadows that panel's own click-through toggling.
    /// `timer`/`fullscreen`/`displayID` (07-04 Task 2) let it draw the bulge's own outline timer
    /// line and the finished-timer pulse — the same providers/observer threaded to every other
    /// per-display view. `hud` (07-05 Task 1) lets it draw the HUD/alert drop — replaces the old
    /// separate, always-detached `hud` panel window entirely.
    private static func makeOverlayPanel(notchFrame: NSRect, anchorMaxY: CGFloat, isPhysical: Bool, menuBarHeight: CGFloat, motion: FluidMotion, model: NotchViewModel, timer: TimerViewModel, fullscreen: FullscreenObserver, displayID: CGDirectDisplayID?, hud: HUDViewModel) -> NSPanel {
        let q = collapsedParams(isPhysical: isPhysical, notchFrame: notchFrame, menuBarHeight: menuBarHeight)
        let frame = overlayPanelFrame(notchFrame: notchFrame, anchorMaxY: anchorMaxY, q: q)

        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel, .utilityWindow], backing: .buffered, defer: false)

        let container = NSView(frame: NSRect(origin: .zero, size: frame.size))
        container.autoresizesSubviews = true
        let hosting = NSHostingView(rootView: FluidOverlayView(motion: motion, model: model, isPhysical: isPhysical, timer: timer, fullscreen: fullscreen, displayID: displayID, hud: hud))
        hosting.frame = NSRect(origin: .zero, size: frame.size)
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        panel.contentView = container

        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        return panel
    }

    /// The window frame while expanded — grows downward from the notch,
    /// staying horizontally centered on it.
    private static func expandedFrame(notchFrame: NSRect, anchorMaxY: CGFloat) -> NSRect {
        let width = NotchLayout.expandedWidth
        let height = NotchLayout.expandedHeight
        return NSRect(
            x: notchFrame.midX - width / 2,
            y: anchorMaxY - height,
            width: width,
            height: height
        )
    }

    /// The one place that decides whether a given panel's window is at its
    /// collapsed (fluid pill) or expanded size. The Ambient HUD no longer factors in
    /// here — it's a detached pill in its own window.
    private func resolvedFrame(for panel: NotchPanel) -> NSRect {
        if panel.viewModel?.isOpen == true {
            return Self.expandedFrame(notchFrame: panel.notchFrame, anchorMaxY: panel.anchorMaxY)
        }
        return collapsedSurfaceFrame(for: panel)
    }

    /// Drives the AppKit window frame in step with the model's open/close
    /// state, regardless of whether that state change came from hover dwell
    /// or the global-hotkey `toggle()`.
    ///
    /// On expand, the window grows to its full size immediately — the extra
    /// area is transparent, so the jump is invisible, and the SwiftUI content
    /// morph (already animating via `NotchLayout.morphAnimation`) grows into
    /// it. On collapse, the window shrink is deferred until the content morph
    /// has visually finished (DEFECT B ordering), so the box never appears to
    /// pop/jump.
    private func applyFrame(to panel: NotchPanel, isOpen: Bool) {
        panel.pendingCollapse?.cancel()
        panel.pendingCollapse = nil

        // DIAGNOSTIC ONLY (plan 04-02 checkpoint round 5): correlate frame
        // changes against the hover-transition log in NotchViewModel and the
        // click-probe log lines from round 4 — testing whether the panel is
        // collapsing right around the moment a click on Grant Access lands.
        let frame = resolvedFrame(for: panel)
        let container = panel.contentView as? HoverTrackingView

        if isOpen {
            // The whole expanded window is the hover target again.
            container?.hoverRect = nil
            panel.setFrame(frame, display: true)
        } else {
            // D-11: shrink the tracking rect to the collapsed pill immediately —
            // before the window itself shrinks — so a cursor sweeping through
            // the dead zone below the still-oversized window never re-arms the
            // dwell, while moving onto the pill itself still gets a fresh
            // `mouseEntered` at any point during the 0.45s collapse animation.
            container?.hoverRect = NotchGeometry.collapsedHoverRect(
                containerSize: panel.frame.size,
                notchSize: collapsedSurfaceFrame(for: panel).size
            )
            var work: DispatchWorkItem!
            work = DispatchWorkItem { [weak self, weak panel] in
                guard let panel else { return }
                // Reset on every exit from this item (panel gone, panel reopened
                // before this fired, or the normal collapse-applied path below) —
                // never leave a stale reference behind, which permanently blocked
                // the sliver-follow guard's `pendingCollapse == nil` check above.
                // The identity check guards against a newer item clobbering itself
                // out from under a future call site; today every supersession path
                // (`applyFrame`'s own cancel+nil above, and `tearDown`) already
                // cancels this item before it can fire on the serial main queue, so
                // this branch is currently unreachable — it's defense-in-depth.
                defer { if panel.pendingCollapse === work { panel.pendingCollapse = nil } }
                guard let self, panel.viewModel?.isOpen != true else {
                    return
                }
                let collapseFrame = self.resolvedFrame(for: panel)
                panel.setFrame(collapseFrame, display: true)
                // The collapsed window now IS the pill — `.inVisibleRect`
                // tracking is correct again, and cheaper.
                (panel.contentView as? HoverTrackingView)?.hoverRect = nil
                self.logClickProbeNow(key: panel.displayKey)
            }
            panel.pendingCollapse = work
            DispatchQueue.main.asyncAfter(deadline: .now() + NotchLayout.collapseWindowDelay, execute: work)
        }
    }

    /// 2026-09-12 amendment ("Hotkey scope" — supersedes D-07's "the global hotkey opens every
    /// panel"): resolves the panel under `NSEvent.mouseLocation`, the identical gate
    /// `NotchPanel.canBecomeKey` already uses, and toggles only that one island. Every other
    /// island's `HoverDwell` state is untouched. No fallback state needed — the pointer always
    /// resolves to exactly one screen, the same assumption `canBecomeKey` already relies on.
    func toggle() {
        guard let panel = panels.first(where: { $0.screenFrame.contains(NSEvent.mouseLocation) }) else { return }
        withAnimation(NotchLayout.morphAnimation) {
            panel.viewModel?.toggle()
        }
    }

    /// Drives the hover-dwell state machine from the `HoverTrackingView`'s
    /// AppKit `NSTrackingArea` enter/exit events (SHELL-11 fix), replacing
    /// SwiftUI `.onHover` — which the left half of the notch never received
    /// (see `container` comment in `makePanel`). Mirrors the previous
    /// `NotchContentView.handleHover` timing exactly (0.25s open dwell,
    /// 0.1s close grace, cancel-on-new-event) but uses `DispatchWorkItem`s
    /// hung off the panel instead of a SwiftUI `@State` `Task`, matching the
    /// existing `pendingCollapse` pattern in this controller.
    private static func handleHoverChange(panel: NotchPanel, hovering: Bool) {
        panel.pendingDwellOpen?.cancel()
        panel.pendingDwellOpen = nil
        panel.pendingHoverClose?.cancel()
        panel.pendingHoverClose = nil

        guard let model = panel.viewModel else { return }


        if hovering {
            model.hoverBegan()
            let work = DispatchWorkItem { [weak panel] in
                guard let model = panel?.viewModel else { return }
                withAnimation(NotchLayout.morphAnimation) {
                    model.dwellElapsed()
                }
            }
            panel.pendingDwellOpen = work
            DispatchQueue.main.asyncAfter(deadline: .now() + NotchLayout.hoverDwellDelay, execute: work)
        } else {
            let work = DispatchWorkItem { [weak panel] in
                guard let model = panel?.viewModel else { return }
                withAnimation(NotchLayout.morphAnimation) {
                    model.hoverEnded()
                }
            }
            panel.pendingHoverClose = work
            DispatchQueue.main.asyncAfter(deadline: .now() + NotchLayout.hoverCollapseGrace, execute: work)
        }
    }

    /// D-04/FEEL-02 (07-02, Task 1): drives the collapsed pill's sticky pull/lean/glow and the
    /// toggle click-through mechanism (07-01's decision) from the live pointer, and — via
    /// `FluidPointer.isDwellTarget` — the dwell-to-open `outlineHovering` source (renamed from
    /// `wingHovering`: the dwell target is now the whole drawn outline, not a separate "wing"
    /// region). Pointer coordinates are converted once per panel into that display's own top-down
    /// space (`y = anchorMaxY − mouse.y`, `cx = notchFrame.midX`) — the same convention
    /// `FluidShapeGeometry`'s outline math and `FluidPointer` both use.
    private func handleMouseMoved() {
        let mouseGlobal = NSEvent.mouseLocation
        for panel in panels {
            guard let motion = panel.motion else { continue }
            let pointer = CGPoint(x: mouseGlobal.x, y: panel.anchorMaxY - mouseGlobal.y)
            let cx = panel.notchFrame.midX
            let q = collapsedParams(for: panel)
            let isOpen = panel.viewModel?.isOpen == true

            // 07-05 Task 3 (agreement §6): resting on a HUD/alert drop's own content must never
            // register as a dwell target, even where the base half-width/depth band would
            // otherwise say yes — `alertTop` is the drop's own current top edge (`baseY +
            // dropOffset`, the same `g` used everywhere else this plan).
            let alertTop: CGFloat? = hud.isShowingHUD
                ? FluidShapeGeometry.floorY(x: 0, q: q, cx: 0) + (motion.channels[.dropOffset] ?? 0)
                : nil
            let hovering = !isOpen && FluidPointer.isDwellTarget(pointer: pointer, cx: cx, q: q, alertTop: alertTop)
            if panel.outlineHovering != hovering {
                panel.outlineHovering = hovering
                Self.applyHover(panel: panel)
            }

            if isOpen {
                // Open panels stay catching until plan 08 gives the band an outline.
                panel.ignoresMouseEvents = false
                continue
            }

            // 07-05 (agreement §6): while a HUD/alert drop shows, the sticky pull/lean is damped
            // to 30% (index.html:519 `if (st.extra){ pull *= .3; lean *= .3; }`) — `hud` broadcasts
            // to every panel, so this reads the same shared flag every panel's own drop drives off.
            let pull = FluidPointer.stickyPull(pointer: pointer, cx: cx, q: q, damped: hud.isShowingHUD)
            motion.set(.belly, to: pull.pull, preset: .sticky)
            motion.set(.lean, to: pull.lean, preset: .sticky)
            motion.setChannel(.glow, to: 0.2 + pull.pull * 0.04, response: FluidMotionPreset.sticky.response, damping: FluidMotionPreset.sticky.damping)

            // D-04 toggle mechanism (07-01): a collapsed panel only catches clicks that land
            // inside its own drawn outline — everything else passes through to whatever is
            // behind it (menu bar, desktop, other apps). 07-05 Task 3 (T-07-01): a linked meeting
            // drop's own pebble is ALSO tested — its Join button lives in this same interactive
            // panel, so a click on the drop must reach it too.
            var inside = FluidShapeGeometry.contains(pointer, cx: cx, q: motion.params)
            if let meeting = hud.meeting, meeting.joinURL != nil {
                let baseY = FluidShapeGeometry.floorY(x: 0, q: q, cx: 0)
                let dropOffset = motion.channels[.dropOffset] ?? 0
                let dropHalfWidth = motion.channels[.dropHalfWidth] ?? 0
                let dropHeight = motion.channels[.dropHeight] ?? 0
                if dropHalfWidth > 1, dropHeight > 0.5 {
                    let pebble = FluidShapeGeometry.pebble(w: dropHalfWidth, y: baseY + dropOffset, h: dropHeight, ox: cx)
                    if pebble.contains(pointer, using: .winding, transform: .identity) {
                        inside = true
                    }
                }
            }
            panel.ignoresMouseEvents = !inside
        }
    }

    /// Collapses the notch-tracking-area and outline-dwell hover sources into a
    /// single dwell state, so moving the cursor between the two never reads as
    /// a leave (which would flicker the panel closed).
    private static func applyHover(panel: NotchPanel) {
        let hovering = panel.notchHovering || panel.outlineHovering
        guard hovering != panel.lastHoverApplied else { return }
        panel.lastHoverApplied = hovering
        handleHoverChange(panel: panel, hovering: hovering)
    }
}

/// Tracks hover over the container's full bounds via AppKit's
/// `NSTrackingArea` rather than SwiftUI `.onHover`, which is unreliable here
/// (see `container` comment in `NotchPanelController.makePanel`). Two
/// regimes (D-11): when `hoverRect` is nil, `.zero` + `.inVisibleRect` keeps
/// the tracking rect pinned to the view's current bounds automatically as
/// `applyFrame` resizes the window between the collapsed notch size and the
/// expanded panel size — used while open/expanded and once fully collapsed.
/// When `hoverRect` is set (during the collapse animation, before the window
/// itself has shrunk), the tracking area is pinned to that explicit rect
/// instead, so the dead zone below the still-oversized window never re-arms
/// the hover dwell.
private final class HoverTrackingView: NSView {
    var onHoverChange: ((Bool) -> Void)?
    var hoverRect: NSRect? { didSet { updateTrackingAreas() } }

    /// Keeps the (wider-than-container) hosting subview horizontally centered
    /// and top-pinned on every window resize, replacing the `autoresizingMask`
    /// that corrupted the hosting view's x (snapping it to 0 on the
    /// collapsed→HUD-bump resize, clipping the HUD to the notch's right half).
    /// Does NOT call `super` — this view owns its single subview's geometry.
    override func resizeSubviews(withOldSize oldSize: NSSize) {
        guard let hosting = subviews.first else { return }
        hosting.setFrameOrigin(NSPoint(
            x: ((bounds.width - hosting.frame.width) / 2).rounded(),
            y: bounds.height - hosting.frame.height
        ))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        if let hoverRect {
            // Explicit rect — no `.inVisibleRect`, which would override it and
            // track the full (still-oversized, mid-collapse) bounds instead.
            addTrackingArea(NSTrackingArea(
                rect: hoverRect,
                options: [.mouseEnteredAndExited, .activeAlways],
                owner: self,
                userInfo: nil
            ))
        } else {
            addTrackingArea(NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self,
                userInfo: nil
            ))
        }
    }

    override func mouseEntered(with event: NSEvent) { onHoverChange?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChange?(false) }
}

/// A plain `NSHostingView` doesn't expose per-control `needsPanelToBecomeKey`, so AppKit falls
/// back to the generic "window not key -> check acceptsFirstMouse" path (default NO) for any
/// SwiftUI button hosted in a non-key `.nonactivatingPanel`. That swallows the first click on
/// every button in the expanded panel — it's spent making the panel key instead of firing the
/// button — and only the second click, now that the panel is key, is delivered normally. This
/// override tells AppKit the hosted content itself never needs the panel to become key, so
/// `panel.becomesKeyOnlyIfNeeded` can do what its own name promises. `DurationField`'s real
/// `NSTextField` is a separate `NSViewRepresentable`, outside this view's hit-test chain, so it
/// keeps independently reporting `needsPanelToBecomeKey = true` and still accepts typed input.
private final class NonKeyHostingView<Content: View>: NSHostingView<Content> {
    override var needsPanelToBecomeKey: Bool { false }
}

/// Each screen's panel owns its own `NotchViewModel` (IN-02) — hovering or
/// toggling one screen's notch must not open/close another screen's.
private final class NotchPanel: NSPanel {
    weak var viewModel: NotchViewModel?
    var notchFrame: NSRect = .zero
    var anchorMaxY: CGFloat = 0
    /// 07-15 gap closure (D-06 row 1): the display's own measured menu-bar height at the moment
    /// this panel was (re)built — `collapsedParams(for:)` derives the MacBook pill's depth from
    /// it. `rebuildPanels()`'s kept-vs-rebuilt comparison rebuilds the set when this drifts from
    /// `screen.menuBarHeight`, so a resolution change never leaves the pill at a stale depth.
    var menuBarHeight: CGFloat = 0
    // Phase 6 SHELL-06/07: which `NotchGeometry.Mode` case this panel was
    // built from, and the owning screen's full frame — both set once in
    // `makePanel`, read by `NotchContentView`'s corner-radius branch and any
    // future per-display logic that needs the screen back.
    var isPhysical = true
    var screenFrame: NSRect = .zero
    /// Phase 6 Plan 03 (D-06/D-07): the `CGDirectDisplayID` this panel was built for, set once in
    /// `rebuildPanels()` from `screen.displayID`. Feeds `FullscreenObserver`'s per-display queries
    /// and `canBecomeKey`'s pointer-display gate below.
    var displayID: CGDirectDisplayID?
    /// The `FluidMotion` clock this panel's own `PanelSet` owns (07-02 Task 1) — read by
    /// `sendEvent(_:)` for the outsideClick detector's live outline geometry. Strong: nothing else
    /// in `FluidMotion` references `NotchPanel`, so there is no retain cycle, and the panel needs
    /// this reference to outlive any single `handleMouseMoved` call.
    var motion: FluidMotion?
    /// `NSScreen.displayKey` this panel was built for (07-02 Task 1) — logged by both the
    /// `outsideClick` detector below and the `clickProbe` diagnostic in
    /// `NotchPanelController.logClickProbeNow(key:)`.
    var displayKey: String = ""
    var pendingCollapse: DispatchWorkItem?
    var pendingDwellOpen: DispatchWorkItem?
    var pendingHoverClose: DispatchWorkItem?
    /// 07-05 Task 3: the deferred shrink-back-to-collapsed frame after a linked meeting drop ends
    /// (`endAlertDrop`) — mirrors `pendingCollapse`'s own cancel-on-supersession idiom.
    var pendingDropFrameRestore: DispatchWorkItem?
    // Two independent hover sources unified into one dwell state (see
    // `applyHover`): the notch's `NSTrackingArea` and the outline dwell-target
    // detector (`FluidPointer.isDwellTarget`, driven by the mouse-moved monitors).
    var notchHovering = false
    var outlineHovering = false
    var lastHoverApplied = false

    // Purely non-activating (Dicticus pattern): the hotkey recorder now lives
    // in a dedicated, activated Settings window (AppDelegate.showSettings),
    // so the notch panel never needs to become key/main and never steals
    // focus or activation from whatever the user is doing.
    // Can become key (so the duration text field accepts typing) but only when
    // needed — `becomesKeyOnlyIfNeeded` limits that to text-field clicks, so the
    // panel stays a non-activating ambient overlay otherwise. Never main.
    //
    // Phase 6 Plan 03 (D-07): the hotkey opens every panel at once, but only ONE panel may ever
    // become key — the one whose `screenFrame` contains the pointer — so typed input (today: the
    // minutes field after a click; Phase 8: keyboard navigation) always lands on the display the
    // user is actually looking at, never on a panel the pointer isn't over. `toggle()` itself
    // calls nothing that requests key status, so this gate alone (combined with
    // `becomesKeyOnlyIfNeeded`) is what enforces the rule — no forced-key AppKit call exists
    // anywhere in this file.
    override var canBecomeKey: Bool { screenFrame.contains(NSEvent.mouseLocation) }
    override var canBecomeMain: Bool { false }

    private static let outsideClickLogger = AppLog.make("NotchPanelController")

    /// D-04 production regression evidence (07-02 Task 1), ported from the spike's
    /// `FluidSpikePanel.sendEvent` (07-01): under BOTH click-through mechanisms this is the
    /// ground-truth check — if a `.leftMouseDown` reaches this window at all while it's outside the
    /// currently drawn outline, click-through has failed regardless of what `ignoresMouseEvents`
    /// was set to. Only checked while collapsed (`viewModel?.isOpen != true`) — the expanded panel
    /// is a plain rectangle with no outline concept until plan 08.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, let motion, viewModel?.isOpen != true {
            let globalPoint = NSEvent.mouseLocation
            let cx = frame.width / 2
            let localX = globalPoint.x - frame.minX
            let localY = frame.maxY - globalPoint.y
            let inside = FluidShapeGeometry.contains(CGPoint(x: localX, y: localY), cx: cx, q: motion.params)
            if !inside {
                Self.outsideClickLogger.notice("outsideClick display=\(self.displayKey, privacy: .public) x=\(localX, privacy: .public) y=\(localY, privacy: .public)")
            }
        }
        super.sendEvent(event)
    }

    // The notch overlay is a fixed, level-27 ambient window — it must never be
    // miniaturized or closed by the standard Window menu commands (⌘M / ⌘W),
    // which would otherwise reset its window level and position. Kept as a
    // defensive no-op even though the panel no longer becomes key.
    override func miniaturize(_ sender: Any?) { /* no-op: notch panel is not miniaturizable */ }
    override func performMiniaturize(_ sender: Any?) { /* no-op */ }
    override func performClose(_ sender: Any?) { /* no-op: not user-closable; Quit is via the panel's power button */ }
}
