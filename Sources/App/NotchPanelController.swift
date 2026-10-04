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
    let fineTuneMonitor = FineTuneMonitor()

    // Owned ONCE here too (HUD-04): the tap must survive every screen-parameter rebuild. Internal,
    // not private, so plan 08-02's Settings row can read its state.
    let brightnessTap = BrightnessKeyTap()

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

    // Owned ONCE here too (07-08, PANEL-02 prerequisite): the clipboard-history slice moves up
    // from `ExpandedPanelView`'s old local `@State` (deleted this plan) so history survives every
    // panel rebuild, matching every other provider's convention above.
    let clipboard = ClipboardViewModel()

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

    /// HUD-03/04: persisted key for the opt-in "replace the system brightness bezel" setting.
    /// Same reverse-DNS convention; renaming it after shipping silently resets every install.
    static let replaceBrightnessBezelKey = "com.myisland.replaceBrightnessBezel"
    static let replaceBrightnessBezelDefault = false

    /// HUD-05: persisted override for "Show volume HUD". There is deliberately no paired default
    /// constant: an absent value means automatic (hidden while FineTune runs). Never rename it —
    /// that silently drops every stored override.
    static let showVolumeHUDKey = "com.myisland.showVolumeHUD"

    /// Debug-only UserDefaults flag (never a Settings toggle — mirrors `MyIslandVerboseLogging`'s
    /// convention): when set, `makePanelSet` and every completed collapse log a `clickProbe` line
    /// so `scripts/clickthrough-probe.sh` can confirm D-04 holds on production surfaces. Under the
    /// `toggle` click-through mechanism (07-01's decision) there is nothing to alpha-probe — the
    /// probe line records `skipped mode=toggle`, and the real D-04 evidence is the `outsideClick`
    /// detector on `NotchPanel.sendEvent(_:)` logging zero swallowed outside clicks.
    static let clickProbeKey = "MyIslandClickProbe"

    /// 07-13 (FEEL-05): debug-only UserDefaults flag, same convention as `clickProbeKey` above —
    /// when set at launch, `runMotionSelfTest()` drives a repeatable 20s open/droplet/close loop on
    /// the main display's own panel set so xctrace's Animation Hitches template has a scripted
    /// interaction to record against, and logs `selfTest done` when it finishes.
    static let motionSelfTestKey = "MyIslandMotionSelfTest"

    /// MOD-01 (07-11): persisted key for the Settings "Modules" toggles — Alcove-style per-module
    /// on/off, Settings-driven, same `com.myisland.*` reverse-DNS convention as every other
    /// persisted key above. Stored as a comma-joined list of `BandModule.rawValue`s: SwiftUI's
    /// `AppStorage` has no native `Array<String>` support (only scalar types and
    /// `RawRepresentable` with an `Int`/`String` raw value), so a plain `String` is the shared
    /// physical representation this reader and `SettingsView`/`NotchContentView`'s own
    /// `@AppStorage` bindings all parse identically.
    static let enabledModulesKey = "com.myisland.enabledModules"

    /// WR-04 paired-constant convention: the default when nothing is persisted yet — every
    /// module.
    static let enabledModulesDefault: [String] = BandModule.allCases.map(\.rawValue)

    /// The persisted enabled subset (MOD-01) — every set's `BandLayout`/window frame/droplet
    /// lookup below is built from this instead of `BandModule.allCases`. A missing key or an
    /// unknown-name value degrades to `enabledModulesDefault` via `BandModules.enabled(from:)`
    /// (T-07-05: the band can never be built with zero modules).
    private var enabledModules: [BandModule] { Self.enabledModulesFromDefaults() }

    /// Static form of `enabledModules` — `Self.makePanel` (a static factory, no instance to read
    /// from) and `NotchContentView`'s own SwiftUI-side module list (no controller instance is
    /// threaded to that view) both read this directly — one shared UserDefaults read for a Settings-driven value
    /// consumed on both the AppKit and SwiftUI side of this app.
    static func enabledModulesFromDefaults() -> [BandModule] {
        let stored = UserDefaults.standard.string(forKey: enabledModulesKey)
        return BandModules.enabled(from: stored?.split(separator: ",").map(String.init))
    }

    /// 07-08 (D-06 Wave 2): the band's own outline parameters for `moduleCount`/`contentTop` — the
    /// single source `openFrame(for:)`'s window sizing and `NotchContentView`'s constant hosting
    /// frame both read, so the two can never disagree about how big the open band is. `18 + 7 + 8`
    /// is the droplet's own rim/shadow margin beyond its raw `dropletHeight`.
    static func openFrameSize(moduleCount: Int, contentTop: CGFloat) -> CGSize {
        let params = FluidParams.band(moduleCount: moduleCount, contentTop: contentTop)
        let width = params.half * 2
        let height = params.d + params.sag + FluidShapeGeometry.dropletHeight + 18 + 7 + 8
        return CGSize(width: width, height: height)
    }

    /// A non-Bool value written by hand (or by a future migration bug) degrades to
    /// the default rather than crashing or reading as off (T-06-08).
    private var showOnNotchlessDisplays: Bool {
        UserDefaults.standard.object(forKey: Self.showOnNotchlessDisplaysKey) as? Bool ?? Self.showOnNotchlessDisplaysDefault
    }

    private var replaceBrightnessBezel: Bool {
        UserDefaults.standard.object(forKey: Self.replaceBrightnessBezelKey) as? Bool ?? Self.replaceBrightnessBezelDefault
    }

    private var volumeHUDOverride: Bool? {
        UserDefaults.standard.object(forKey: Self.showVolumeHUDKey) as? Bool
    }

    private func volumeHUDShouldShow() -> Bool {
        VolumeHUDPolicy.shouldShow(override: volumeHUDOverride, fineTuneRunning: fineTuneMonitor.isRunning)
    }

    private func logVolumeHUDPolicy() {
        let override = volumeHUDOverride
        let running = fineTuneMonitor.isRunning
        let show = volumeHUDShouldShow()
        let overrideText = override.map { String($0) } ?? "nil"
        logger.notice("volumeHUD policy override=\(overrideText, privacy: .public) fineTuneRunning=\(running, privacy: .public) show=\(show, privacy: .public)")
    }

    func volumeHUDSettingChanged() {
        logVolumeHUDPolicy()
    }

    /// A press at a rail fires no change notification (A7), so the drop is shown explicitly.
    private func applyBrightnessKey(_ press: BrightnessKey.Event) -> Bool {
        guard let level = brightnessProvider.step(up: press.up, fine: press.fine) else { return false }
        hud.showBrightness(level: Double(BrightnessScale.barFraction(for: level)))
        return true
    }

    override init() {
        super.init()

        brightnessTap.apply = { [weak self] press in self?.applyBrightnessKey(press) ?? false }
        brightnessTap.canApply = brightnessProvider.canSetBrightness

        // `level` is now `Float?` (T-7h2 §1.3): a device with no readable volume property hides
        // the row rather than showing the previous device's stale value, mirroring how
        // `brightnessProvider.onChange` already guards below.
        volumeProvider.onChange = { [weak self] in
            guard let self, let level = self.volumeProvider.level else { return }
            self.fineTuneMonitor.rescan()
            let override = self.volumeHUDOverride
            guard self.volumeHUDShouldShow() else {
                self.logger.notice("volumeHUD suppressed reason=\(override == nil ? "fineTune" : "override", privacy: .public)")
                return
            }
            if override == true, self.fineTuneMonitor.isRunning {
                self.logger.notice("volumeHUD shown reason=override")
            }
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
            for (key, set) in self.panelSets {
                if set.model.isOpen == true {
                    if visible { self.logger.notice("hudDrop skip key=\(key, privacy: .public) reason=open") }
                    continue
                }
                if visible {
                    self.logHUDDropStart(key: key, set: set)
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
        fullscreenObserver.onAccessibilityTrustChange = { [weak self] trusted in
            guard let self else { return }
            self.logger.notice("accessibility trusted=\(trusted, privacy: .public)")
            self.brightnessTap.reconcile(enabled: self.replaceBrightnessBezel)
        }
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
                (set.panel.contentView as? HoverTrackingView)?.hoverTargetSize = self.hoverTriggerFrame(for: set.panel).size
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
        brightnessTap.reconcile(enabled: replaceBrightnessBezel)

        // 07-13 (FEEL-05): the scripted self-test only ever runs when a human/script opted in via
        // `motionSelfTestKey` at launch — never on a normal run. `rebuildPanels()` above must have
        // already built the main display's own `PanelSet` for this to find anything to drive.
        if UserDefaults.standard.bool(forKey: Self.motionSelfTestKey) {
            runMotionSelfTest()
        }

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
        // keystroke event mask, and never a low-level event-tap creation/enable call — so this
        // monitor needs no grant. The app's only event tap is the opt-in brightness tap in
        // BrightnessKeyTap.swift (HUD-03), created only after the user turns on the Settings
        // toggle and grants Accessibility; Info.plist and MyIsland.entitlements still declare no
        // input-monitoring or accessibility usage key. It lets a hover over a timer
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

        fineTuneMonitor.onChange = { [weak self] in self?.logVolumeHUDPolicy() }
        logVolumeHUDPolicy()
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
    func brightnessBezelSettingChanged() {
        brightnessTap.reconcile(enabled: replaceBrightnessBezel)
    }

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
            // The decision lives in DisplayReconcilePolicy (relative geometry; its doc comment
            // carries the 2026-09-27 transient-zero menu-bar rationale).
            let previousGeometry = DisplayGeometry(screenFrame: set.panel.screenFrame, anchorRect: set.panel.notchFrame, isPhysical: set.panel.isPhysical, menuBarHeight: set.panel.menuBarHeight)
            let currentGeometry = DisplayGeometry(screenFrame: screen.frame, anchorRect: mode.anchorRect, isPhysical: mode.isPhysical, menuBarHeight: screen.menuBarHeight)
            if case .rebuild(let reason) = DisplayReconcilePolicy.decide(previous: previousGeometry, current: currentGeometry) {
                logger.notice("reconcile key=\(key, privacy: .public) decision=rebuilt reason=\(reason.rawValue, privacy: .public)")
                // WR-02 (06-REVIEW.md): a fresh `NotchViewModel` always starts collapsed — carry
                // the torn-down set's open state forward through the SAME code path a hover/hotkey
                // open uses (`toggle()`), rather than reaching into the new model's private dwell
                // state directly, so frame/animation bookkeeping stays consistent with every other
                // open trigger.
                let wasOpen = set.model.isOpen
                tearDown(set)
                let newSet = makePanelSet(for: screen, mode: mode, key: key)
                panelSets[key] = newSet
                // 07-08: the band's own open/close motion is driven entirely by `FluidMotion`'s
                // spring clock (`onOpenChange` below), never by SwiftUI's `withAnimation`
                // (RESEARCH.md Pitfall 2) — the old SwiftUI cross-fade spring is retired.
                if wasOpen {
                    newSet.model.toggle()
                }
                rebuilt += 1
            } else {
                logger.notice("reconcile key=\(key, privacy: .public) decision=kept")
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

        // 2026-09-27 (regression found live): `makePanelSet` orders `panel` then `overlay` front
        // exactly ONCE, at creation — nothing re-asserts that relative order afterward. Both
        // windows share the same level (`mainMenu+3`), and WindowServer can and does reshuffle
        // same-level window ordering across a Space/fullscreen transition. If the overlay (which
        // draws the rim and, since 2026-09-27, the pill's own timer line) ends up BEHIND the
        // interactive panel (which draws the opaque black fill), the fill occludes the inner half
        // of every stroke straddling the outline — worst at the sharply curved shoulders near the
        // wings, barely noticeable on the flat floor, exactly the asymmetry reported. `kept`
        // panels (the common case for a fullscreen toggle, now that the menu-bar-height rebuild
        // trigger above is scoped to real changes) never went through `makePanelSet` again, so
        // nothing here ever re-asserted it. `orderFrontRegardless()` is idempotent and cheap when
        // the order is already correct — safe to call unconditionally on every reapply, not just
        // when something drifted.
        set.panel.orderFrontRegardless()
        set.overlay.orderFrontRegardless()
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
        set.panel.pendingBandClose?.cancel()
        set.panel.pendingIntent?.cancel()
        set.motion.cancelWhenSettled()
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

        let panel = Self.makePanel(notchFrame: anchorRect, screen: screen, isPhysical: mode.isPhysical, model: model, motion: motion, timer: timer, calendar: calendarProvider, nowPlaying: nowPlayingProvider, fullscreen: fullscreenObserver, displayKey: key, hud: hud, clipboard: clipboard)
        panel.displayID = screen.displayID
        // `makePanel`'s own window sizing is the static, non-fullscreen-aware
        // `collapsedSurfaceFrame(isPhysical:notchFrame:anchorMaxY:)` (it has no panel/displayID to
        // query yet) — reapply now that `displayID` is set, so a fresh bulge starts at its own
        // (shallower) window frame rather than the desktop pill's.
        if startsAsBulge {
            panel.setFrame(resolvedFrame(for: panel), display: true)
        }
        if let container = panel.contentView as? HoverTrackingView {
            container.hoverTargetSize = hoverTriggerFrame(for: panel).size
            // AppKit can report `mouseEntered` for a pointer outside the tracking rect (seen on a
            // cursor warp into the window below the band), so a collapsed enter only counts once
            // the live pointer is confirmed inside the trigger band.
            container.onHoverChange = { [weak self, weak panel] hovering in
                guard let self, let panel else { return }
                let confirmed = hovering && (panel.viewModel?.isOpen == true || self.isInHoverTrigger(panel, NSEvent.mouseLocation))
                panel.notchHovering = confirmed
                Self.applyHover(panel: panel)
            }
        }
        model.onOpenChange = { [weak self, weak panel] isOpen in
            guard let self, let panel, let motion = panel.motion else { return }
            // 07-05 Task 3 (sketch's own `openBand`): opening the band — by hover-dwell or the
            // global hotkey, either path lands here via `NotchViewModel` — ends any HUD/alert
            // drop immediately rather than letting it linger under the expanding band.
            if isOpen {
                self.hud.dismissNow()
                // WR-02 (07-review fix): `hud.onVisibilityChange`'s broadcast (wired in `init`)
                // excludes THIS panel via its `where set.model.isOpen != true` filter, because
                // `isOpen` has already flipped true by the time this closure runs
                // (`NotchViewModel.toggle()`/`dwellElapsed()`/`hoverEnded()` all flip `isOpen`
                // before invoking `onOpenChange`). Without this direct call, this panel's own
                // drop channels (`.dropOffset`/`.dropHalfWidth`/`.dropAlpha`) are never
                // retracted, so a stale, still-visually-live drop can reappear once the band
                // closes again and `NotchContentView` re-mounts its linked-meeting `AlertDropView`.
                self.endAlertDrop(on: panel, motion: motion)
            }
            if isOpen {
                self.openBand(on: panel, motion: motion)
            } else {
                self.closeBand(on: panel, motion: motion)
                // PANEL-09 (07-12 deviation — Rule 2, missing critical functionality): EVERY
                // close funnels through here — hover dwell-close, a pointer-driven `.closeBand`
                // (`handleMouseMoved`'s own `pendingBandClose`), the hotkey's own close branch,
                // and Esc's `.closeBand` effect all end at `model.toggle()` eventually landing
                // here — so this is the ONE place keyboard focus is handed back, not just the
                // paths that happen to go through `closeBandAndRestoreFocus`. Without this, a
                // hover-driven close (or the pointer just wandering off the band) left the panel
                // key with `previousApp` still unset, silently swallowing every subsequent
                // keystroke — T-07-16's own mitigation column says "Esc AND CLOSING return focus
                // to the previous app," and this closure is the only path that actually covers
                // every close, not a subset of them.
                self.relinquishKeyFocus(on: panel)
                panel.bandFocus = BandFocus(moduleCount: self.enabledModules.count)
                panel.keyboardPointerAnchor = nil
                panel.dropletFocus.reset()
                self.syncKeyFocus(on: panel)
                // Same funnel, same reasoning as the keyboard-focus fix above: `applyHover`
                // debounces on `lastHoverApplied` but is a no-op entirely while the band is open
                // (see its own doc comment), so any close that bypasses it directly —
                // `handleMouseMoved`'s pointer-outside `.closeBand` chief among them — leaves
                // `lastHoverApplied` stuck wherever it was at hover-in time.
                //
                // RESYNC, don't force-clear: `notchHovering` (the AppKit tracking area, pinned to
                // the container's full bounds — wider than the drawn pill) can still read `true`
                // here even though `outlineHovering` (the drawn-shape `contains` check that
                // actually drove the `.closeBand` pointer-outside close) has already gone false.
                // Forcing `lastHoverApplied` to `false` unconditionally manufactures a false
                // false→true edge the moment ANY mouse-moved event lands inside that still-hot
                // wider container — even one that never crosses the pill's own drawn border —
                // and reopens the band prematurely. Mirroring the two live source booleans here
                // instead means the next `applyHover` only fires on a REAL edge: if the pointer
                // has genuinely left both regions the mirrored value is already `false` and a
                // fresh hover-in triggers correctly (the original bug); if the pointer is still
                // inside the wider tracking rect the mirrored value stays `true` and no premature
                // reopen fires until the pointer actually leaves that rect too.
                panel.lastHoverApplied = panel.notchHovering || panel.outlineHovering
            }
            self.applyFrame(to: panel, isOpen: isOpen)
        }
        // 07-08 Task 2 (PANEL-04): a band cell's body click toggles its pin — clicking the already
        // pinned cell unpins; clicking a different cell moves the pin there and shows its droplet.
        model.onCellTap = { [weak self, weak panel] index in
            guard let self, let panel, let motion = panel.motion, let model = panel.viewModel else { return }
            if model.pinnedModule == index {
                model.setPinnedModule(nil)
            } else {
                model.setPinnedModule(index)
                self.showDroplet(index, on: panel, motion: motion)
            }
        }
        // 07-12 (PANEL-09): the SAME action a glyph click and a keyboard Return both run —
        // `BandView`'s own `performPrimaryAction(for:)` wrapper calls this closure directly; the
        // AppKit key-routing path (`applyBandFocusEffect`'s `.performGlyph` case) calls
        // `performPrimaryAction(for:on:)` on `self` directly, no closure indirection needed there.
        model.onPerformPrimaryAction = { [weak self, weak panel] module in
            guard let self, let panel else { return }
            self.performPrimaryAction(for: module, on: panel)
        }
        panel.controller = self
        panel.orderFrontRegardless()

        let overlay = Self.makeOverlayPanel(notchFrame: anchorRect, anchorMaxY: anchorMaxY, isPhysical: mode.isPhysical, menuBarHeight: screen.menuBarHeight, motion: motion, model: model, timer: timer, hud: hud)
        overlay.orderFrontRegardless()

        // The printed height distinguishes the launched-app menu-bar value from the 22pt
        // status-bar fallback.
        logger.notice("panel set key=\(key, privacy: .public) mode=\(mode.isPhysical ? "physical" : "synthetic", privacy: .public) anchor=\(NSStringFromRect(anchorRect), privacy: .public) menuBar=\(screen.menuBarHeight, privacy: .public)")
        logClickProbeAfterDelay(key: key, panel: panel)

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

    /// FLUID-02 evidence (08-04): which surface the drop grows from on this display and whether
    /// its settled bottom (floor at the centre + the 8 pt rest offset + drop height) fits the
    /// overlay window. Observation only; the drop geometry is not touched.
    private func logHUDDropStart(key: String, set: PanelSet) {
        let surface = set.panel.isPhysical ? "physical" : (isFullscreenBulge(for: set.panel) ? "bulge" : "pill")
        let floor = FluidShapeGeometry.floorY(x: 0, q: collapsedParams(for: set.panel), cx: 0)
        let dropBottom = ((floor + 8 + dropSize(for: set.panel).height) * 2).rounded() / 2
        let overlayHeight = set.overlay.frame.height
        logger.notice("hudDrop start key=\(key, privacy: .public) surface=\(surface, privacy: .public) dropBottom=\(dropBottom, privacy: .public) overlayHeight=\(overlayHeight, privacy: .public) fits=\(dropBottom <= overlayHeight, privacy: .public)")
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

    /// D-06 Wave 2 (PANEL-04): this panel's own band cell/droplet geometry — `cx` is the panel's
    /// GLOBAL notch midpoint (matching every other pointer/`FluidShapeGeometry.contains` call in
    /// this file), NOT the SwiftUI-local `cx` `NotchContentView`'s own `bandLayout` uses for
    /// on-screen positioning. Same module list/content-top rule as that view's copy — kept as two
    /// independent computations (not a shared type) because they operate in two different
    /// coordinate spaces for two different callers (AppKit pointer math here, SwiftUI layout there).
    private func bandLayout(for panel: NotchPanel) -> BandLayout {
        let contentTop: CGFloat = panel.isPhysical ? FluidShapeGeometry.bandContentTopPhysical : FluidShapeGeometry.bandContentTopSynthetic
        return BandLayout(moduleCount: enabledModules.count, contentTop: contentTop, cx: panel.notchFrame.midX)
    }

    /// The open window's own frame — the band's bounding box plus droplet room, `openFrameSize`'s
    /// single source. Replaces the old fixed `expandedFrame`.
    private func openFrame(for panel: NotchPanel) -> NSRect {
        let contentTop: CGFloat = panel.isPhysical ? FluidShapeGeometry.bandContentTopPhysical : FluidShapeGeometry.bandContentTopSynthetic
        let size = Self.openFrameSize(moduleCount: enabledModules.count, contentTop: contentTop)
        return NSRect(
            x: panel.notchFrame.midX - size.width / 2,
            y: panel.anchorMaxY - size.height,
            width: size.width,
            height: size.height
        )
    }

    /// Ported from the sketch's `openBand` (index.html:334-343): pours the collapsed outline into
    /// the band on the open spring/stagger, settles belly/lean back to rest, brightens the glow,
    /// and rises `bandAlpha` after `FluidTiming.contentDelay` so content fades in slightly behind
    /// the box growth. `hud.dismissNow()` (any drop) is already called by the `onOpenChange` wiring
    /// above before this runs.
    private func openBand(on panel: NotchPanel, motion: FluidMotion) {
        let layout = bandLayout(for: panel)
        motion.goTo(layout.params, preset: .open, stagger: FluidStagger.pour)
        motion.set(.belly, to: 0, preset: .open)
        motion.set(.lean, to: 0, preset: .open)
        motion.setChannel(.glow, to: 0.28, response: FluidMotionPreset.open.response, damping: FluidMotionPreset.open.damping)
        DispatchQueue.main.asyncAfter(deadline: .now() + FluidTiming.contentDelay) { [weak panel, weak motion] in
            guard let panel, let motion, panel.viewModel?.isOpen == true else { return }
            motion.setChannel(.bandAlpha, to: 1, response: 0.45, damping: 1)
        }
    }

    /// Ported from the sketch's `closeBand` (index.html:345-351): the droplet closes first (Task 2's
    /// `closeDroplet`), then drains `bandAlpha` back to 0, retracts the outline to the collapsed
    /// rest params on the close spring/stagger with `FluidTiming.lag`, and dims the glow back down.
    /// Also clears the pinned/candidate/intent bookkeeping — none of it should survive a close.
    private func closeBand(on panel: NotchPanel, motion: FluidMotion) {
        closeDroplet(on: panel, motion: motion)
        panel.viewModel?.setPinnedModule(nil)
        panel.candidateCell = nil
        panel.pendingIntent?.cancel()
        panel.pendingIntent = nil
        motion.setChannel(.bandAlpha, to: 0, response: 0.2, damping: 1)
        motion.goTo(collapsedParams(for: panel), preset: .close, lag: FluidTiming.lag, stagger: FluidStagger.drain)
        motion.setChannel(.glow, to: 0.2, response: FluidMotionPreset.close.response, damping: FluidMotionPreset.close.damping)
    }

    /// D-06 Wave 2 (PANEL-04): ports the sketch's `setHot(i)` (index.html:356-368) — the first
    /// droplet drips/grows in place (`mx` jumps straight to target, `m` jumps to 60% and animates
    /// the rest, `dip` scaled ×1.25 on the `.droplet` preset); every later one slides on the
    /// `.slide` preset instead of restarting the drip. `dropAlpha` always jumps to 0 first, then
    /// rises at response 0.5 (first) or 0.32 (slide).
    private func showDroplet(_ index: Int, on panel: NotchPanel, motion: FluidMotion) {
        guard let model = panel.viewModel else { return }
        let modules = enabledModules
        guard index >= 0, index < modules.count else { return }
        let layout = bandLayout(for: panel)
        let target = layout.droplet(forCell: index, halfWidth: modules[index].dropletWidth / 2)
        let wasShowing = model.hotModule != nil

        model.setHotModule(index, frame: DropletFrame(mx: target.mx, m: target.m))

        let preset: FluidMotionPreset = wasShowing ? .slide : .droplet
        if !wasShowing {
            motion.jumpParam(.mx, to: target.mx)
            motion.jumpParam(.m, to: target.m * 0.6)
        }
        motion.set(.mx, to: target.mx, preset: preset)
        motion.set(.m, to: target.m, preset: preset, scale: 0.8)
        motion.set(.s2, to: target.s2, preset: preset)
        motion.set(.dip, to: target.dip, preset: preset, scale: wasShowing ? 1 : 1.25)
        motion.jumpChannel(.dropAlpha, to: 0)
        motion.setChannel(.dropAlpha, to: 1, response: wasShowing ? 0.32 : 0.5, damping: 1)
    }

    /// Ports the sketch's `closeDrop` (index.html:369-373): `dip` and `m` retract on the close
    /// preset (×0.8 / ×1.3 response respectively), `dropAlpha` fades fast (0.12, damping 1). A
    /// no-op when nothing is showing.
    private func closeDroplet(on panel: NotchPanel, motion: FluidMotion) {
        guard let model = panel.viewModel, model.hotModule != nil else { return }
        model.setHotModule(nil, frame: nil)
        motion.set(.dip, to: 0, preset: .close, scale: 0.8)
        motion.set(.m, to: 0, preset: .close, scale: 1.3)
        motion.setChannel(.dropAlpha, to: 0, response: 0.12, damping: 1)
    }

    /// MOD-01 (07-11): called from `SettingsView`'s `.onChange` of the persisted enabled list —
    /// every set may have been showing a droplet for a module that just left the enabled set, so
    /// each one drops its droplet and clears its pin first, then rebuilds its own `BandLayout` for
    /// the new module count. An OPEN set re-flows live on the sketch's own slide spring
    /// (index.html:764-771 module-switch handler); a closed set simply picks up the new layout the
    /// next time it opens — no immediate motion needed since nothing is drawn.
    func modulesChanged() {
        for set in panelSets.values {
            closeDroplet(on: set.panel, motion: set.motion)
            set.model.setPinnedModule(nil)
            let layout = bandLayout(for: set.panel)
            if set.model.isOpen {
                set.motion.goTo(layout.params, preset: .slide)
            }
            // PANEL-09 (07-12): a module switch can shrink the band while keyboard focus is
            // active — clamps `bandFocus`'s own pinned/showing/zone indices to the new count.
            _ = set.panel.bandFocus.moduleCountChanged(enabledModules.count)
            syncKeyFocus(on: set.panel)
        }
    }

    /// D-04 regression evidence for `scripts/clickthrough-probe.sh` (Task 1/2): only active when
    /// `clickProbeKey` is set. Under the `toggle` click-through mechanism there is no alpha
    /// hit-test to probe — see `clickProbeKey`'s doc comment — so this always logs the `skipped`
    /// form; the real evidence is `NotchPanel.sendEvent(_:)`'s `outsideClick` detector logging zero
    /// swallowed outside clicks over the same run. 07-08 Task 3: once the collapsed line is logged,
    /// chains into `runOpenSurfaceProbe` for the band/droplet surfaces — same debug-flag gate.
    private func logClickProbeAfterDelay(key: String, panel: NotchPanel) {
        guard UserDefaults.standard.bool(forKey: Self.clickProbeKey) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self, weak panel] in
            guard let self else { return }
            self.logClickProbeNow(key: key)
            guard let panel else { return }
            Task { @MainActor [weak self, weak panel] in
                guard let self, let panel else { return }
                await self.runOpenSurfaceProbe(key: key, panel: panel)
            }
        }
    }

    private func logClickProbeNow(key: String) {
        guard UserDefaults.standard.bool(forKey: Self.clickProbeKey) else { return }
        logger.notice("clickProbe skipped mode=toggle display=\(key, privacy: .public)")
    }

    /// 07-08 Task 3 (D-04 regression evidence, T-07-01): gated strictly behind `clickProbeKey` —
    /// the "never auto-expand" prohibition (D-05/agreement §10) is judgment-verified, and this
    /// must never gain a code path a normal launch can reach. Opens the band through the SAME
    /// `model.toggle()` path the hotkey uses (never taking key focus — `becomesKeyOnlyIfNeeded`
    /// already guards that), probes the band surface, shows the droplet for cell 0, probes that
    /// surface, then closes.
    private func runOpenSurfaceProbe(key: String, panel: NotchPanel) async {
        guard UserDefaults.standard.bool(forKey: Self.clickProbeKey) else { return }
        guard let model = panel.viewModel, let motion = panel.motion else { return }
        model.toggle()
        try? await Task.sleep(nanoseconds: 900_000_000)
        // See `probeInProgress`'s own doc comment: a real mouse-moved event landing mid-measurement
        // would otherwise race the probe's own `ignoresMouseEvents` writes.
        panel.probeInProgress = true
        await probeOpenSurface(name: "band", panel: panel, motion: motion, key: key)

        showDroplet(0, on: panel, motion: motion)
        try? await Task.sleep(nanoseconds: 700_000_000)
        await probeOpenSurface(name: "droplet", panel: panel, motion: motion, key: key)
        panel.probeInProgress = false

        model.toggle()
    }

    /// The open-state click-through measurement itself (advisor-reviewed per 07-01's own toggle
    /// mechanism finding: a synchronous set-then-query lies — `ignoresMouseEvents` measured
    /// p50 3.55ms / p99 9.02ms to take effect, so each of the 48 points sets the flag, waits 20ms,
    /// THEN queries `NSWindow.windowNumber(at:)` — the same honest per-point protocol
    /// `FluidSpikeController`'s collapsed-state probe established in 07-01.
    private func probeOpenSurface(name: String, panel: NotchPanel, motion: FluidMotion, key: String) async {
        let cx = panel.frame.width / 2
        let params = motion.params
        let probes = FluidShapeGeometry.probePoints(cx: cx, q: params, count: 24, offset: 1)
        var insideHit = 0
        var outsidePass = 0
        for pair in probes {
            let insideGlobal = CGPoint(x: panel.frame.minX + pair.inside.x, y: panel.frame.maxY - pair.inside.y)
            panel.ignoresMouseEvents = !FluidShapeGeometry.contains(pair.inside, cx: cx, q: params)
            try? await Task.sleep(nanoseconds: 20_000_000)
            if NSWindow.windowNumber(at: insideGlobal, belowWindowWithWindowNumber: 0) == panel.windowNumber {
                insideHit += 1
            }

            let outsideGlobal = CGPoint(x: panel.frame.minX + pair.outside.x, y: panel.frame.maxY - pair.outside.y)
            panel.ignoresMouseEvents = !FluidShapeGeometry.contains(pair.outside, cx: cx, q: params)
            try? await Task.sleep(nanoseconds: 20_000_000)
            if NSWindow.windowNumber(at: outsideGlobal, belowWindowWithWindowNumber: 0) != panel.windowNumber {
                outsidePass += 1
            }
        }
        logger.notice("clickProbe surface=\(name, privacy: .public) mode=toggle display=\(key, privacy: .public) insideHit=\(insideHit, privacy: .public)/\(probes.count, privacy: .public) outsidePass=\(outsidePass, privacy: .public)/\(probes.count, privacy: .public)")
    }

    private static func makePanel(notchFrame: NSRect, screen: NSScreen, isPhysical: Bool, model: NotchViewModel, motion: FluidMotion, timer: TimerViewModel, calendar: CalendarProvider, nowPlaying: NowPlayingProvider, fullscreen: FullscreenObserver, displayKey: String, hud: HUDViewModel, clipboard: ClipboardViewModel) -> NotchPanel {
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

        let hostingView = NonKeyHostingView(rootView: NotchContentView(model: model, motion: motion, timer: timer, calendar: calendar, nowPlaying: nowPlaying, fullscreen: fullscreen, displayID: screen.displayID, hud: hud, clipboard: clipboard, dropletFocus: panel.dropletFocus, isPhysical: isPhysical))
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
        // 07-08 (D-06 Wave 2): the band's own bounding box plus droplet room — the single source
        // `NotchContentView`'s own `openSize` and `openFrame(for:)` both read, so the hosting
        // view's fixed content size can never disagree with either.
        let contentTop: CGFloat = isPhysical ? FluidShapeGeometry.bandContentTopPhysical : FluidShapeGeometry.bandContentTopSynthetic
        let openSize = Self.openFrameSize(moduleCount: Self.enabledModulesFromDefaults().count, contentTop: contentTop)
        let hostingWidth = openSize.width
        let hostingHeight = openSize.height

        // A plain `NSView` cannot be relied upon for hover detection here — SwiftUI's own
        // `.onHover` has repeatedly proven unreliable inside this app's non-activating `NSPanel`
        // (SHELL-11; confirmed again for `GlyphButtonStyle`'s hover state in 07-05). A
        // `NSTrackingArea` on this container — whose bounds always equal the window's full
        // content rect, collapsed or open — sidesteps SwiftUI/NSView hit-testing entirely and is
        // coordinate-exact for both.
        let container = HoverTrackingView(frame: NSRect(origin: .zero, size: collapsedFrame.size))
        container.autoresizesSubviews = true
        container.wantsLayer = true
        container.layer?.masksToBounds = true

        // Fixed at the open (band) size (matches the constant SwiftUI content
        // size in `NotchContentView`), centered horizontally and top-pinned
        // within the container. While the container is collapsed (notch
        // sized), only the top-center notch region is visible; the rest is
        // clipped by `masksToBounds`. When `applyFrame` grows the window, the
        // full hosting content becomes visible without ever resizing itself.
        hostingView.frame = NSRect(
            x: (container.bounds.width - hostingWidth) / 2,
            y: container.bounds.height - hostingHeight,
            width: hostingWidth,
            height: hostingHeight
        )
        // Horizontal centering + top-pinning across window resizes is owned by
        // `HoverTrackingView.resizeSubviews(withOldSize:)`, NOT an
        // `autoresizingMask`. The mask corrupts this: because the hosting view
        // is WIDER than the collapsed container (the open band's own bounding box),
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

    /// The collapsed hover trigger band in global screen coordinates (full surface width, top-pinned, the upper two-thirds of the surface's depth), shared by the tracking area and the mouse-moved self-correct.
    private func hoverTriggerFrame(for panel: NotchPanel) -> NSRect {
        let q = collapsedParams(for: panel)
        let depth = FluidPointer.triggerDepth(q: q)
        return NSRect(
            x: panel.notchFrame.midX - q.half,
            y: panel.anchorMaxY - depth,
            width: q.half * 2,
            height: depth
        )
    }

    /// Includes the band's top edge, which `NSRect.contains` excludes, so a pointer pushed against
    /// the top of the screen still counts.
    private func isInHoverTrigger(_ panel: NotchPanel, _ point: NSPoint) -> Bool {
        let band = hoverTriggerFrame(for: panel)
        return point.x >= band.minX && point.x < band.maxX && point.y >= band.minY && point.y <= band.maxY
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
    /// `timer` (07-04 Task 2) lets it draw the outline timer line and the finished-timer pulse —
    /// the same provider threaded to every other per-display view. `hud` (07-05 Task 1) lets it draw the HUD/alert drop — replaces the old
    /// separate, always-detached `hud` panel window entirely.
    private static func makeOverlayPanel(notchFrame: NSRect, anchorMaxY: CGFloat, isPhysical: Bool, menuBarHeight: CGFloat, motion: FluidMotion, model: NotchViewModel, timer: TimerViewModel, hud: HUDViewModel) -> NSPanel {
        let q = collapsedParams(isPhysical: isPhysical, notchFrame: notchFrame, menuBarHeight: menuBarHeight)
        let frame = overlayPanelFrame(notchFrame: notchFrame, anchorMaxY: anchorMaxY, q: q)

        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel, .utilityWindow], backing: .buffered, defer: false)

        let container = NSView(frame: NSRect(origin: .zero, size: frame.size))
        container.autoresizesSubviews = true
        let hosting = NSHostingView(rootView: FluidOverlayView(motion: motion, model: model, isPhysical: isPhysical, timer: timer, hud: hud))
        hosting.frame = NSRect(origin: .zero, size: frame.size)
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        panel.contentView = container

        // 2026-09-27 (Fable consult, verified live): ONE LEVEL ABOVE the interactive panel
        // (mainMenu+3), not the same level. Sharing a level with the interactive panel meant any
        // same-level reorder — `panel.makeKey()` on hover/hotkey open chief among them, never
        // followed by an overlay re-front — could put the interactive panel's opaque fill in
        // front of this window, occluding the inner half of every stroke on the shared outline
        // path (worst at the sharply curved shoulders, matching what was reported). A strictly
        // higher level makes that entire class of bug structurally impossible — WindowServer
        // never interleaves windows across levels — rather than requiring every future call site
        // that might reorder same-level windows to remember to re-assert this one's front order.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 4)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        return panel
    }

    /// The one place that decides whether a given panel's window is at its
    /// collapsed (fluid pill) or open (band) size. The Ambient HUD no longer factors in
    /// here — it's a detached pill in its own window.
    private func resolvedFrame(for panel: NotchPanel) -> NSRect {
        if panel.viewModel?.isOpen == true {
            return openFrame(for: panel)
        }
        return collapsedSurfaceFrame(for: panel)
    }

    /// Drives the AppKit window frame in step with the model's open/close
    /// state, regardless of whether that state change came from hover dwell
    /// or the global-hotkey `toggle()`.
    ///
    /// On expand, the window grows to its full size immediately — the extra
    /// area is transparent, so the jump is invisible, and the fluid outline
    /// (already animating on `motion`'s own spring clock, `openBand` above)
    /// pours into it. On collapse, the window shrink is deferred until
    /// `motion.whenSettled` reports the retract has actually finished (07-08:
    /// replaces the old fixed `NotchLayout.collapseWindowDelay` timer), so the
    /// box never appears to pop/jump ahead of the still-draining outline.
    private func applyFrame(to panel: NotchPanel, isOpen: Bool) {
        panel.pendingCollapse?.cancel()
        panel.pendingCollapse = nil
        // 07-08: cancel any pending settle-then-shrink registration too — "cancelled by a reopen"
        // is what keeps a stale close's window-shrink from firing after a fresh open superseded it.
        panel.motion?.cancelWhenSettled()

        // DIAGNOSTIC ONLY (plan 04-02 checkpoint round 5): correlate frame
        // changes against the hover-transition log in NotchViewModel and the
        // click-probe log lines from round 4 — testing whether the panel is
        // collapsing right around the moment a click on Grant Access lands.
        let frame = resolvedFrame(for: panel)
        let container = panel.contentView as? HoverTrackingView

        if isOpen {
            // The whole expanded window is the hover target again.
            container?.hoverTargetSize = nil
            panel.setFrame(frame, display: true)
        } else {
            // D-11: shrink the tracking target to the trigger band immediately, before the
            // window shrinks, so neither the dead zone below the still-oversized window nor the
            // pill's lower third re-arms the dwell, while moving onto the band still gets a fresh
            // `mouseEntered` during the collapse animation.
            container?.hoverTargetSize = hoverTriggerFrame(for: panel).size
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
                // Re-derived for the surface actually settled on (pill or bulge).
                (panel.contentView as? HoverTrackingView)?.hoverTargetSize = self.hoverTriggerFrame(for: panel).size
                self.logClickProbeNow(key: panel.displayKey)
            }
            panel.pendingCollapse = work
            panel.motion?.whenSettled { [weak work] in work?.perform() }
        }
    }

    /// 2026-09-12 amendment ("Hotkey scope" — supersedes D-07's "the global hotkey opens every
    /// panel"): resolves the panel under `NSEvent.mouseLocation`, the identical gate
    /// `NotchPanel.canBecomeKey` already uses, and toggles only that one island. Every other
    /// island's `HoverDwell` state is untouched. No fallback state needed — the pointer always
    /// resolves to exactly one screen, the same assumption `canBecomeKey` already relies on.
    func toggle() {
        guard let panel = panels.first(where: { $0.screenFrame.contains(NSEvent.mouseLocation) }) else { return }
        // 07-08: the band's own motion is driven entirely by `FluidMotion`'s spring clock
        // (`onOpenChange` → `openBand`/`closeBand`), never by SwiftUI's `withAnimation`.
        panel.viewModel?.toggle()
    }

    /// 07-13 (FEEL-04): the app's own latency signposter — static (not per-instance) because
    /// `handleHoverChange`'s own `makePanel`-owned closure has no controller `self` to read an
    /// instance property from. `beginHotkeyLatency`/`beginDwellLatency`/`beginActionLatency` each
    /// begin ONE named interval and end it (plus log `latency kind=<hotkey|dwell|action>
    /// ms=<value>` at `.notice`) from `FluidMotion.onNextFrame` — "first frame" is exactly what
    /// that callback already means.
    private static let latencySignposter = OSSignposter(subsystem: AppIdentity.bundleID, category: "Latency")
    private static let latencyLogger = AppLog.make("NotchPanelController")
    private static let hoverLogger = AppLog.make("NotchPanelController")

    private static func beginHotkeyLatency(motion: FluidMotion) {
        beginLatency(name: "hotkeyToFrame", kind: "hotkey", motion: motion)
    }

    private static func beginDwellLatency(motion: FluidMotion) {
        beginLatency(name: "dwellToFrame", kind: "dwell", motion: motion)
    }

    private static func beginActionLatency(motion: FluidMotion) {
        beginLatency(name: "actionToFrame", kind: "action", motion: motion)
    }

    private static func beginLatency(name: StaticString, kind: String, motion: FluidMotion) {
        let state = latencySignposter.beginInterval(name)
        let start = DispatchTime.now()
        motion.onNextFrame {
            latencySignposter.endInterval(name, state)
            let ms = Double(DispatchTime.now().uptimeNanoseconds &- start.uptimeNanoseconds) / 1_000_000
            latencyLogger.notice("latency kind=\(kind, privacy: .public) ms=\(ms, privacy: .public)")
        }
    }

    /// PANEL-09 (07-12): the ⌥Space entry point — the ONLY path that takes keyboard focus (see
    /// `NotchPanel.canBecomeKey`'s own doc comment). Resolves the panel under the pointer exactly
    /// like `toggle()` above; on open, remembers the frontmost app so Esc/a second ⌥Space can give
    /// it back, opens through the same `model.toggle()` path hover uses, becomes key ONCE, seeds
    /// `BandFocus` at the first module, and shows its droplet after the sketch's own 260ms delay
    /// (index.html:334-344 `openBand(true)`, distinct from `FluidTiming.contentDelay`'s 160ms
    /// `bandAlpha` rise); on close, hands focus straight back.
    func toggleFromHotkey() {
        guard let panel = panels.first(where: { $0.screenFrame.contains(NSEvent.mouseLocation) }) else { return }
        guard let model = panel.viewModel else { return }
        // 07-13 (FEEL-04): begun before either branch below — a hotkey press opening OR closing
        // the band both count as "hotkey press → first reacting frame."
        if let motion = panel.motion {
            Self.beginHotkeyLatency(motion: motion)
        }
        if model.isOpen {
            closeBandAndRestoreFocus(on: panel)
            return
        }
        panel.previousApp = NSWorkspace.shared.frontmostApplication
        model.toggle()
        // The ONE forced-key call in this file — see `NotchPanel.canBecomeKey`'s own doc comment.
        panel.makeKey()
        panel.keyboardPointerAnchor = NSEvent.mouseLocation
        panel.bandFocus = BandFocus(moduleCount: enabledModules.count)
        _ = panel.bandFocus.hotkeyOpened()
        model.setPinnedModule(0)
        syncKeyFocus(on: panel)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.26) { [weak self, weak panel] in
            guard let self, let panel, let motion = panel.motion, panel.viewModel?.isOpen == true else { return }
            self.showDroplet(0, on: panel, motion: motion)
        }
    }

    /// 07-13 (FEEL-05): `motionSelfTestKey`'s scripted run — the panel set for `NSScreen.main`
    /// only, never every display, and never real key focus (unlike `toggleFromHotkey`). Reuses the
    /// SAME dwell (`Self.applyHover`) and action (`performPrimaryAction`) call sites a real
    /// hover/click would use rather than a bespoke path, so the run also exercises `dwellToFrame`/
    /// `actionToFrame` (FEEL-04), not just the open/droplet/close motion this exists for (FEEL-05).
    /// The one action exercised is always `.clipboard` — `ClipboardViewModel.select` re-copies
    /// whatever is ALREADY the top pasteboard entry (a safe, idempotent no-op; see that method's
    /// own doc comment), unlike every other module's primary action (driving real playback,
    /// starting a real Pomodoro, or opening a real meeting URL) — none of which an unattended scripted run may ever trigger.
    private func runMotionSelfTest() {
        guard let mainScreen = NSScreen.main, let set = panelSets[mainScreen.displayKey] else {
            logger.notice("selfTest done")
            return
        }
        selfTestStep(panel: set.panel, motion: set.motion, deadline: Date().addingTimeInterval(20))
    }

    /// One open→droplets→close cycle of the self-test loop, re-scheduling itself until `deadline`.
    private func selfTestStep(panel: NotchPanel, motion: FluidMotion, deadline: Date) {
        guard Date() < deadline else {
            logger.notice("selfTest done")
            return
        }
        let modules = enabledModules
        guard !modules.isEmpty else {
            logger.notice("selfTest done")
            return
        }

        // Open: the same dwell path a real hover uses (`hoverBegan` → `NotchLayout.hoverDwellDelay`
        // → `dwellElapsed`, where `dwellToFrame` begins) — reset so this cycle's `hoverBegan` fires
        // again even though the previous cycle already applied `hovering: true` once.
        panel.lastHoverApplied = false
        panel.notchHovering = true
        Self.applyHover(panel: panel)

        for (i, module) in modules.enumerated() {
            let delay = NotchLayout.hoverDwellDelay + 0.6 * Double(i + 1)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak panel] in
                guard let self, let panel, panel.viewModel?.isOpen == true else { return }
                self.showDroplet(i, on: panel, motion: motion)
                if module == .clipboard {
                    self.performPrimaryAction(for: .clipboard, on: panel)
                }
            }
        }

        let closeDelay = NotchLayout.hoverDwellDelay + 0.6 * Double(modules.count + 1)
        DispatchQueue.main.asyncAfter(deadline: .now() + closeDelay) { [weak self, weak panel] in
            guard let self, let panel else { return }
            panel.notchHovering = false
            panel.lastHoverApplied = false
            if panel.viewModel?.isOpen == true {
                panel.viewModel?.toggle()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                self.selfTestStep(panel: panel, motion: motion, deadline: deadline)
            }
        }
    }

    /// PANEL-09: closes the band through the SAME `model.toggle()` path hover uses (never a direct
    /// `closeBand` call — that would desync `HoverDwell`'s own state) — `model.onOpenChange`'s own
    /// `isOpen == false` branch (above, in `makePanelSet`) is where the actual focus-restore now
    /// lives (07-12 deviation, Rule 2), since THAT closure is the one place every close funnels
    /// through, not just the Esc chain and the hotkey's own close branch. This wrapper exists so
    /// `applyBandFocusEffect`'s `.closeBand` case and `toggleFromHotkey`'s close branch have a
    /// single, guarded call site rather than each checking `isOpen` themselves.
    private func closeBandAndRestoreFocus(on panel: NotchPanel) {
        guard panel.viewModel?.isOpen == true else { return }
        panel.viewModel?.toggle()
    }

    /// PANEL-09 (07-12 deviation — Rule 2): gives real OS keyboard focus back to whichever app was
    /// frontmost before `toggleFromHotkey` took it. Resigning key when the panel isn't currently
    /// key (e.g. a mouse-only close that was never keyboard-driven) is a documented no-op, and
    /// `previousApp` is `nil` on that same path, so `app?.activate()` is also a no-op — safe to
    /// call unconditionally from every close. Deliberately does NOT touch `bandFocus`/
    /// `dropletFocus` — a caller mid-open (the pointer-moved-ends-keyboard-mode path in
    /// `handleMouseMoved`) needs ONLY this; a caller that's actually closing the band resets those
    /// itself, since a still-open, still-registered droplet must not have its registry wiped out
    /// from under it.
    private func relinquishKeyFocus(on panel: NotchPanel) {
        let app = panel.previousApp
        panel.previousApp = nil
        // When my-island's own Settings window was frontmost, activating "the previous app" moves
        // no focus and a bare `resignKey()` left the AX focus on the panel, so the next ⌥Space's
        // keys never reached `handleBandKeyDown` (2026-10-01 UAT: 1 of 10 runs worked). Hand key
        // status to that window instead.
        if app?.processIdentifier == NSRunningApplication.current.processIdentifier, panel.isKeyWindow,
           let window = NSApp.orderedWindows.first(where: { !($0 is NotchPanel) && $0.isVisible && $0.canBecomeKey }) {
            window.makeKey()
            return
        }
        if panel.isKeyWindow {
            panel.resignKey()
        }
        app?.activate()
    }

    /// PANEL-09: turns one `BandFocus.Effect` into the matching AppKit/SwiftUI action — the single
    /// place both `toggleFromHotkey`'s own `.showDroplet(0)` (applied inline above, not through
    /// here — it needs the 260ms delay) and `NotchPanel.sendEvent`'s key routing (`handleBandKeyDown`
    /// below) dispatch through.
    private func applyBandFocusEffect(_ effect: BandFocus.Effect, on panel: NotchPanel, motion: FluidMotion) {
        switch effect {
        case .none:
            break
        case .showDroplet(let i):
            // Mirrors `model.onCellTap`'s own click-to-pin behaviour (07-08 Task 2) — a
            // keyboard-selected module "sticks" exactly like a clicked one, so `handleMouseMoved`'s
            // own `model.pinnedModule == nil` gate leaves it alone.
            panel.viewModel?.setPinnedModule(i)
            showDroplet(i, on: panel, motion: motion)
        case .closeDroplet:
            panel.viewModel?.setPinnedModule(nil)
            closeDroplet(on: panel, motion: motion)
        case .closeBand:
            closeBandAndRestoreFocus(on: panel)
        case .performGlyph(let i):
            let modules = enabledModules
            guard i >= 0, i < modules.count else { break }
            performPrimaryAction(for: modules[i], on: panel)
        case .pressControl(let i):
            panel.dropletFocus.perform(i)
        }
        syncKeyFocus(on: panel)
    }

    /// PANEL-09: mirrors `panel.bandFocus.zone` into the SwiftUI-observable side (`keyFocusIndex`
    /// on `NotchViewModel` for the band ring, `focusedIndex` on `DropletFocus` for the droplet
    /// ring) after every `BandFocus` mutation, and logs the change.
    private func syncKeyFocus(on panel: NotchPanel) {
        switch panel.bandFocus.zone {
        case .band(let i):
            panel.viewModel?.setKeyFocusIndex(i)
            panel.dropletFocus.setFocusedIndex(nil)
            logger.notice("keyFocus zone=band index=\(i, privacy: .public)")
        case .droplet(let i):
            panel.viewModel?.setKeyFocusIndex(nil)
            panel.dropletFocus.setFocusedIndex(i)
            logger.notice("keyFocus zone=droplet index=\(i, privacy: .public)")
        case .none:
            panel.viewModel?.setKeyFocusIndex(nil)
            panel.dropletFocus.setFocusedIndex(nil)
            logger.notice("keyFocus zone=none index=-1")
        }
    }

    /// PANEL-09: `NotchPanel.sendEvent`'s own key-routing entry point — `fileprivate` so that type
    /// (declared later in this same file) can call it. Returns `true` when the event was consumed
    /// (a recognized key while the band is open, the panel is key, and no text field is editing);
    /// every other key returns `false` so `sendEvent` falls through to `super`.
    fileprivate func handleBandKeyDown(_ event: NSEvent, on panel: NotchPanel) -> Bool {
        // 07-12 deviation (Rule 1 — bug): `panel.bandFocus.zone != nil` is required too — without
        // it, a recognized key code arriving AFTER `pointerMoved()` already set `zone = nil` (the
        // pointer moved, ending keyboard mode, while the band stayed open under pointer control)
        // still matched a key code below, computed `.none` from `BandFocus`, and returned `true`
        // — silently swallowing every arrow/Tab/Return/Esc instead of falling through to `super`.
        guard panel.isKeyWindow, panel.viewModel?.isOpen == true, panel.bandFocus.zone != nil else { return false }
        // The field editor for the minutes `NSTextField` is an `NSTextView` while editing is
        // active (AppKit's field-editor pattern) — this is what "first responder is not a text
        // view" actually detects; a click has already made the field first responder by the time
        // any of these key codes could route here.
        if panel.firstResponder is NSTextView { return false }
        guard let motion = panel.motion else { return false }
        let controlCount = panel.dropletFocus.count
        let effect: BandFocus.Effect
        switch event.keyCode {
        case 123: effect = panel.bandFocus.arrowLeft()
        case 124: effect = panel.bandFocus.arrowRight()
        case 125: effect = panel.bandFocus.arrowDown(controlCount: controlCount)
        case 126: effect = panel.bandFocus.arrowUp(controlCount: controlCount)
        case 48: effect = panel.bandFocus.tab(backward: event.modifierFlags.contains(.shift), controlCount: controlCount)
        case 36, 76: effect = panel.bandFocus.returnKey()
        case 53: effect = panel.bandFocus.escape()
        default: return false
        }
        applyBandFocusEffect(effect, on: panel, motion: motion)
        return true
    }

    /// PANEL-05/PANEL-09: the module's one-click primary action — extracted from `BandView`'s own
    /// former inline glyph closures so a glyph click (via `NotchViewModel.onPerformPrimaryAction`)
    /// and a keyboard Return (via `applyBandFocusEffect`'s `.performGlyph` case) run the exact same
    /// code. Reads the SAME provider instances `BandView` itself reads (this controller owns all
    /// of them once — `timer`/`nowPlayingProvider`/`calendarProvider`/`clipboard`)
    /// so no data needs threading from the view; each case's own guard mirrors the corresponding
    /// glyph-visibility check in `BandView.actionGlyph(for:)` exactly, so a keyboard Return on a
    /// module with no applicable action is a safe no-op instead of a crash.
    fileprivate func performPrimaryAction(for module: BandModule, on panel: NotchPanel) {
        // 07-13 (FEEL-04): begun unconditionally — even a module whose own guard below no-ops
        // (nothing playing, no clipboard entry, ...) still measures "action → first reacting
        // frame," and every REAL action always reaches this line first regardless of module.
        if let motion = panel.motion {
            Self.beginActionLatency(motion: motion)
        }
        switch module {
        case .nowPlaying:
            guard BandView.hasNowPlayingAction(nowPlayingProvider) else { return }
            nowPlayingProvider.send(.togglePlayPause)

        case .timer:
            if timer.isPaused {
                timer.resume()
            } else if timer.isRunning {
                timer.pause()
            } else {
                timer.startPomodoro()
            }

        case .nextMeeting:
            guard let event = calendarProvider.events.first, BandView.shouldShowJoinGlyph(for: event), let joinURL = event.joinURL else { return }
            panel.viewModel?.flash("Opening\u{2026}", for: .nextMeeting)
            NSWorkspace.shared.open(joinURL)

        case .clipboard:
            guard BandView.hasClipboardAction(clipboard), let entry = clipboard.entries.first else { return }
            clipboard.select(entry)
            panel.viewModel?.flash("Copied", for: .clipboard)
        }
    }

    /// Drives the hover-dwell state machine from the `HoverTrackingView`'s
    /// AppKit `NSTrackingArea` enter/exit events (SHELL-11 fix), replacing
    /// SwiftUI `.onHover` — which the left half of the notch never received
    /// (see `container` comment in `makePanel`). Mirrors the previous
    /// `NotchContentView.handleHover` timing exactly (`NotchLayout.hoverDwellDelay` open dwell,
    /// `NotchLayout.hoverCollapseGrace` close grace, cancel-on-new-event) but uses `DispatchWorkItem`s
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
                guard let panel else { return }
                // 07-13 (FEEL-04): begun exactly where the dwell elapses — the instant this
                // DispatchWorkItem actually fires, not when it was merely scheduled above.
                if let motion = panel.motion {
                    beginDwellLatency(motion: motion)
                }
                panel.viewModel?.dwellElapsed()
            }
            panel.pendingDwellOpen = work
            DispatchQueue.main.asyncAfter(deadline: .now() + NotchLayout.hoverDwellDelay, execute: work)
        } else {
            let work = DispatchWorkItem { [weak panel] in
                panel?.viewModel?.hoverEnded()
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
            // PANEL-09 (07-12, index.html:431): real pointer movement ends keyboard mode. The
            // `.mouseMoved` monitors can also fire without movement (seen once in five ⌥Space
            // opens in the 2026-10-01 UAT), so while keyboard mode is on, an event with the pointer
            // still at `keyboardPointerAnchor` is skipped for that panel entirely.
            // `zone` is only ever non-nil while a hotkey-opened band is up, so this is a no-op the
            // rest of the time. The band itself stays open under pointer control (this is NOT a
            // close), so only `relinquishKeyFocus` runs — NOT a `bandFocus`/`dropletFocus` reset,
            // which would wipe the still-mounted droplet's own control registry out from under it
            // (07-12 deviation, Rule 1: keeps real OS keyboard focus in sync with the now-nil
            // zone, closing the gap `handleBandKeyDown`'s own `zone != nil` guard, above, depends
            // on — without this, the panel stayed key with nowhere for a keystroke to go).
            if panel.bandFocus.zone != nil {
                if mouseGlobal == panel.keyboardPointerAnchor {
                    logger.notice("keyFocus kept: mouseMoved without pointer movement")
                    continue
                }
                panel.keyboardPointerAnchor = nil
                _ = panel.bandFocus.pointerMoved()
                relinquishKeyFocus(on: panel)
                syncKeyFocus(on: panel)
            }
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

            // `notchHovering` is otherwise driven ONLY by `HoverTrackingView`'s AppKit
            // `NSTrackingArea` enter/exit callbacks (see that type's own doc comment), which have
            // a known AppKit failure mode: a pointer that exits fast through the physical SCREEN
            // edge — exactly what "move up off a notch that sits at the very top of the display"
            // is — can leave `mouseExited` never firing. That strands `notchHovering` at `true`
            // forever, which no later close-time resync can distinguish from a pointer that is
            // genuinely still there, because both look identical from the cached flag alone.
            // Self-correct it here from the SAME live `NSEvent.mouseLocation` this method already
            // reads on every real mouse-moved event anywhere on screen (the global monitor above),
            // exactly mirroring how `outlineHovering` already self-corrects two lines up.
            //
            // The band comes from `hoverTriggerFrame(for:)`, never `panel.frame`: on close the
            // window frame lags `isOpen` through the drain animation (gotcha #2), while the
            // trigger frame is computed from the panel's anchor and collapsed params and is the
            // collapsed target immediately. It is the same band the tracking area
            // (`HoverTrackingView.hoverTargetSize`) and `FluidPointer.isDwellTarget` use, so no
            // hover source can open the panel from the lower third.
            if !isOpen {
                let insideTrigger = isInHoverTrigger(panel, mouseGlobal)
                if panel.notchHovering != insideTrigger {
                    panel.notchHovering = insideTrigger
                    Self.applyHover(panel: panel)
                }
            }

            if isOpen, let model = panel.viewModel {
                // 07-08 (D-06 Wave 2): the AppKit tracking-area exit no longer closes the band —
                // the open window is now much larger than the drawn band+droplet outline, so
                // `handleHoverChange`'s own dwell-close would fire far too late (only once the
                // pointer leaves the whole window). `BandLayout.pointerOutside` ports the sketch's
                // own stay/closeDroplet/closeBand pointer rule instead.
                let layout = bandLayout(for: panel)
                let modules = enabledModules

                // Task 2 (index.html:526-528 `if (i >= 0 && st.pinned < 0 ...)`): candidate-cell
                // dwell tracking only runs while nothing is pinned — a pinned droplet stays put
                // regardless of where the pointer wanders inside the band.
                if model.pinnedModule == nil {
                    let cellIndex = layout.cellAt(pointer)
                    if let cellIndex, cellIndex != panel.candidateCell {
                        panel.candidateCell = cellIndex
                        panel.pendingIntent?.cancel()
                        panel.pendingIntent = nil
                        if model.hotModule != nil {
                            // A droplet is already up — slide immediately (sketch: `st.hot >= 0`
                            // bypasses the `candT > INTENT` dwell check).
                            self.showDroplet(cellIndex, on: panel, motion: motion)
                        } else {
                            let work = DispatchWorkItem { [weak self, weak panel] in
                                guard let self, let panel, let motion = panel.motion, let model = panel.viewModel,
                                      panel.candidateCell == cellIndex, model.pinnedModule == nil else { return }
                                self.showDroplet(cellIndex, on: panel, motion: motion)
                            }
                            panel.pendingIntent = work
                            DispatchQueue.main.asyncAfter(deadline: .now() + FluidTiming.intent, execute: work)
                        }
                    } else if cellIndex == nil {
                        panel.candidateCell = nil
                        panel.pendingIntent?.cancel()
                        panel.pendingIntent = nil
                    }
                }

                let dropletGeom: (mx: CGFloat, m: CGFloat, s2: CGFloat, dip: CGFloat)?
                if let hot = model.hotModule, hot < modules.count {
                    dropletGeom = layout.droplet(forCell: hot, halfWidth: modules[hot].dropletWidth / 2)
                } else {
                    dropletGeom = nil
                }

                switch layout.pointerOutside(pointer, currentHalf: motion.params.half, droplet: dropletGeom, pinned: model.pinnedModule != nil) {
                case .stay:
                    panel.pendingBandClose?.cancel()
                    panel.pendingBandClose = nil
                case .closeDroplet:
                    if panel.pendingBandClose == nil {
                        let work = DispatchWorkItem { [weak self, weak panel] in
                            guard let self, let panel, let motion = panel.motion, panel.viewModel?.isOpen == true else { return }
                            panel.pendingBandClose = nil
                            self.closeDroplet(on: panel, motion: motion)
                        }
                        panel.pendingBandClose = work
                        DispatchQueue.main.asyncAfter(deadline: .now() + NotchLayout.hoverCollapseGrace, execute: work)
                    }
                case .closeBand:
                    if panel.pendingBandClose == nil {
                        let work = DispatchWorkItem { [weak panel] in
                            guard let panel, panel.viewModel?.isOpen == true else { return }
                            panel.pendingBandClose = nil
                            panel.viewModel?.hoverEnded()
                        }
                        panel.pendingBandClose = work
                        DispatchQueue.main.asyncAfter(deadline: .now() + NotchLayout.hoverCollapseGrace, execute: work)
                    }
                }
                // D-04 (07-01's toggle decision) extended to the open band: a click only catches
                // when it lands inside the LIVE (still-animating) outline. Skipped while
                // `probeInProgress` — see that field's own doc comment (the race it fixes).
                if !panel.probeInProgress {
                    panel.ignoresMouseEvents = !FluidShapeGeometry.contains(pointer, cx: cx, q: motion.params)
                }
                continue
            }
            panel.pendingBandClose?.cancel()
            panel.pendingBandClose = nil

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
    ///
    /// 07-08 (D-06 Wave 2): while open, this AppKit-tracking-area-driven path is disabled
    /// entirely — the plan's own instruction ("the tracking area's exit no longer closes the
    /// band"). The open window is sized to the band+droplet room, much larger than the drawn
    /// outline within it; `handleMouseMoved`'s `pendingBandClose` (pointer-outside-the-OUTLINE,
    /// not outside-the-WINDOW) is the sole close trigger while open.
    private static func applyHover(panel: NotchPanel) {
        guard panel.viewModel?.isOpen != true else { return }
        let hovering = panel.notchHovering || panel.outlineHovering
        guard hovering != panel.lastHoverApplied else { return }
        panel.lastHoverApplied = hovering
        hoverLogger.notice("hover applied=\(hovering, privacy: .public) notch=\(panel.notchHovering, privacy: .public) outline=\(panel.outlineHovering, privacy: .public) mouse=\(NSStringFromPoint(NSEvent.mouseLocation), privacy: .public)")
        handleHoverChange(panel: panel, hovering: hovering)
    }
}

/// Tracks hover via AppKit's `NSTrackingArea` rather than SwiftUI `.onHover`, which is unreliable
/// here (see `container` comment in `NotchPanelController.makePanel`). Two regimes (D-11): when
/// `hoverTargetSize` is nil, `.zero` + `.inVisibleRect` tracks the whole visible rect, used only
/// while open. When non-nil, the tracking area is the trigger band of that size, used while
/// collapsed and collapsing and positioned top-pinned against live bounds, so neither the dead
/// zone below a still-oversized window nor the pill's lower third re-arms the dwell.
private final class HoverTrackingView: NSView {
    var onHoverChange: ((Bool) -> Void)?
    var hoverTargetSize: CGSize? { didSet { updateTrackingAreas() } }

    /// Keeps the (wider-than-container) hosting subview horizontally centered
    /// and top-pinned on every window resize, replacing the `autoresizingMask`
    /// that corrupted the hosting view's x (snapping it to 0 on the
    /// collapsed→HUD-bump resize, clipping the HUD to the notch's right half).
    /// Does NOT call `super` — this view owns its single subview's geometry.
    override func resizeSubviews(withOldSize oldSize: NSSize) {
        updateTrackingAreas()
        guard let hosting = subviews.first else { return }
        hosting.setFrameOrigin(NSPoint(
            x: ((bounds.width - hosting.frame.width) / 2).rounded(),
            y: bounds.height - hosting.frame.height
        ))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        if let hoverTargetSize {
            // Explicit trigger band — no `.inVisibleRect`, which would override it and
            // track the full (possibly still-oversized) bounds instead.
            addTrackingArea(NSTrackingArea(
                rect: NotchGeometry.collapsedHoverRect(containerSize: bounds.size, notchSize: hoverTargetSize),
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
    /// 07-08 (D-06 Wave 2): the open band's own pointer-driven close grace — armed when
    /// `BandLayout.pointerOutside` first reports `.closeDroplet` or `.closeBand`, cancelled the
    /// moment the pointer re-enters the band/droplet (`.stay`). Replaces the collapsed pill's
    /// AppKit `NSTrackingArea` exit as the open-state close trigger (that tracking area now covers
    /// the whole, much larger open window, not the drawn band+droplet outline within it). Only one
    /// of `.closeDroplet`/`.closeBand` is ever pending at a time — a single slot is enough.
    var pendingBandClose: DispatchWorkItem?
    /// 07-08 Task 2: the candidate cell the pointer is currently resting on while open and nothing
    /// is pinned — paired with `pendingIntent`'s `FluidTiming.intent` (0.14s) dwell timer, ported
    /// from the sketch's own `st.cand`/`st.candT`.
    var candidateCell: Int?
    /// 07-08 Task 2: the intent-dwell timer for `candidateCell` — cancelled on every candidate
    /// change; fires `showDroplet` only if the candidate is still current when it elapses.
    var pendingIntent: DispatchWorkItem?
    /// 07-08 Task 3 (Rule 1 fix — measured, not assumed): `true` only while
    /// `NotchPanelController.probeOpenSurface` is mid-measurement. Found live: a real global
    /// `mouseMoved` event landing between the probe's own `ignoresMouseEvents` write and its 20ms
    /// settle wait lets `handleMouseMoved`'s open-panel branch overwrite that same flag from the
    /// ACTUAL pointer position before the probe queries `windowNumber(at:)` — one run measured
    /// `insideHit=23/24`, a second (same code, same geometry) measured `24/24` clean, confirming
    /// the miss was this race, not a geometry defect. `handleMouseMoved` skips its own
    /// `ignoresMouseEvents` write for a panel while this is `true`.
    var probeInProgress = false
    /// PANEL-09 (07-12): weak back-reference to the owning controller, set once in
    /// `makePanelSet` — lets `sendEvent(_:)` below route a key-down into
    /// `NotchPanelController.handleBandKeyDown(_:on:)` without this file needing a second,
    /// duplicate copy of the key-routing switch. Weak: `panelSets` already owns this panel
    /// strongly, so a strong back-reference here would be a retain cycle.
    weak var controller: NotchPanelController?
    /// PANEL-09: this panel's own keyboard-focus state machine (Core, 07-07) — reset to a fresh
    /// `BandFocus(moduleCount:)` on every `toggleFromHotkey` open/close and every Esc-driven close,
    /// mutated in place by `NotchPanelController.handleBandKeyDown(_:on:)` on every recognized key.
    var bandFocus = BandFocus(moduleCount: 0)
    /// Pointer location when ⌥Space opened the band: `handleMouseMoved` ends keyboard mode only once the pointer has left it, because AppKit can deliver `.mouseMoved` without movement.
    var keyboardPointerAnchor: NSPoint?
    /// PANEL-09: this panel's own droplet control registry (07-12) — one instance for the panel's
    /// whole lifetime (not recreated per droplet open), reset by `DropletView` whenever the shown
    /// module changes.
    let dropletFocus = DropletFocus()
    /// PANEL-09: the app that was frontmost when `toggleFromHotkey` opened this panel — `nil`
    /// whenever the band isn't open via the hotkey path. Restored (and cleared) by
    /// `NotchPanelController.closeBandAndRestoreFocus(on:)`.
    var previousApp: NSRunningApplication?
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
    // minutes field after a click, and keyboard band/droplet navigation, 07-12) always lands on
    // the display the user is actually looking at, never on a panel the pointer isn't over.
    // `toggle()` itself calls nothing that requests key status, so this gate alone (combined with
    // `becomesKeyOnlyIfNeeded`) is what enforces the rule for every path except one: 07-12's
    // `NotchPanelController.toggleFromHotkey()` deliberately forces this ONE panel's key status on
    // open — the single, documented exception to "no forced-key AppKit call" this file otherwise
    // holds to everywhere else (hover-open, every pointer path, `toggle()` above).
    override var canBecomeKey: Bool { screenFrame.contains(NSEvent.mouseLocation) }
    override var canBecomeMain: Bool { false }

    private static let outsideClickLogger = AppLog.make("NotchPanelController")

    /// D-04 production regression evidence (07-02 Task 1), ported from the spike's
    /// `FluidSpikePanel.sendEvent` (07-01): under BOTH click-through mechanisms this is the
    /// ground-truth check — if a `.leftMouseDown` reaches this window at all while it's outside the
    /// currently drawn outline, click-through has failed regardless of what `ignoresMouseEvents`
    /// was set to. 07-08 Task 3 (Rule 2 — missing critical functionality, T-07-01's own
    /// mitigation): no longer gated on `viewModel?.isOpen != true` — the band has its own outline
    /// now (`motion.params` while open IS the band, `cx = frame.width / 2` is still correct since
    /// the open window is centered on the same `cx`), so this detector covers a swallowed-outside
    /// click on the open band for free, not just the collapsed pill.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, let motion {
            let globalPoint = NSEvent.mouseLocation
            let cx = frame.width / 2
            let localX = globalPoint.x - frame.minX
            let localY = frame.maxY - globalPoint.y
            let inside = FluidShapeGeometry.contains(CGPoint(x: localX, y: localY), cx: cx, q: motion.params)
            if !inside {
                Self.outsideClickLogger.notice("outsideClick display=\(self.displayKey, privacy: .public) x=\(localX, privacy: .public) y=\(localY, privacy: .public)")
            }
        }
        if event.type == .rightMouseDown, let contentView, let motion,
           FluidShapeGeometry.contains(CGPoint(x: NSEvent.mouseLocation.x - frame.minX, y: frame.maxY - NSEvent.mouseLocation.y), cx: frame.width / 2, q: motion.params) {
            let menu = NSMenu()
            let settings = NSMenuItem(title: "Settings…", action: #selector(openSettingsFromMenu), keyEquivalent: ",")
            settings.target = self
            menu.addItem(settings)
            menu.addItem(.separator())
            menu.addItem(NSMenuItem(title: "Quit my-island", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
            NSMenu.popUpContextMenu(menu, with: event, for: contentView)
            return
        }
        // PANEL-09 (07-12): only reachable at all while THIS panel is key, which only happens via
        // `NotchPanelController.toggleFromHotkey()` — every other open path leaves the panel
        // non-key, so this branch is simply never entered for a hover-opened or click-opened band.
        if event.type == .keyDown, let controller, controller.handleBandKeyDown(event, on: self) {
            return
        }
        super.sendEvent(event)
    }

    @objc private func openSettingsFromMenu() {
        NotificationCenter.default.post(name: .openMyIslandSettings, object: nil)
    }

    // The notch overlay is a fixed, level-27 ambient window — it must never be
    // miniaturized or closed by the standard Window menu commands (⌘M / ⌘W),
    // which would otherwise reset its window level and position. Kept as a
    // defensive no-op even though the panel no longer becomes key.
    override func miniaturize(_ sender: Any?) { /* no-op: notch panel is not miniaturizable */ }
    override func performMiniaturize(_ sender: Any?) { /* no-op */ }
    override func performClose(_ sender: Any?) { /* no-op: not user-closable; Settings/Quit live in the right-click menu */ }
}
