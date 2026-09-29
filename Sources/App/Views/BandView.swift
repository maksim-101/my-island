import SwiftUI
import AppKit
import MyIslandCore

/// D-06 Wave 2 (PANEL-04) + 07-09 (PANEL-05): the band's row of two-line module summaries plus,
/// per cell, the module's one-click action glyph — ported per D-02 from
/// `.planning/sketches/006-design-round/index.html`'s `.cell`/`CELL`/`.act` (lines 43-49, 64-70,
/// 612-627). `hotIndex`/`pinnedIndex` and `onTapCell` are wired to real interactive state by plan
/// 08 Task 2 (`NotchPanelController.hotModule`/`pinnedModule`/`showDroplet(_:)`); this file
/// renders the row, its hot/pinned states, and each cell's own glyph action. The glyph is a
/// SEPARATE `Button` from the cell body (07-DESIGN-AGREEMENT.md §4, Phase 6 UAT finding F1: a
/// glyph click must never pin, open or collapse anything else).
@MainActor
struct BandView: View {
    let modules: [BandModule]
    let layout: BandLayout
    let hotIndex: Int?
    let pinnedIndex: Int?
    /// 07-12 (PANEL-09): the band cell currently keyboard-focused (`NotchViewModel.keyFocusIndex`,
    /// mirroring `BandFocus.zone == .band(i)`) — draws the standard 2pt accent ring, distinct from
    /// `pinnedIndex`'s own bottom-capsule indicator.
    let keyFocusIndex: Int?
    let timer: TimerViewModel
    let nowPlaying: NowPlayingProvider
    let calendar: CalendarProvider
    let clipboard: ClipboardViewModel
    /// 07-12: transient "Opening…"/"Copied" confirmation text (sketch `say`, 1.3s) —
    /// moved up to `NotchViewModel.flashMessages` (from this view's own local `@State`) so
    /// `performPrimaryAction` sets the SAME flash regardless of whether a glyph click or a
    /// keyboard Return triggered it.
    let flashMessages: [BandModule: String]
    let onTapCell: (Int) -> Void
    /// 07-12 (PANEL-09): fired by both a glyph click (below) and, via `NotchPanelController`'s own
    /// key routing, a Return press on a focused band cell — the one place either trigger's
    /// underlying action (`NotchPanelController.performPrimaryAction(for:on:)`) actually runs.
    let onPerformPrimaryAction: (BandModule) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(modules.enumerated()), id: \.offset) { index, module in
                cell(for: module, index: index)
                    .frame(width: layout.cellWidth)
            }
        }
    }

    private func cell(for module: BandModule, index: Int) -> some View {
        let hot = hotIndex == index
        let pinned = pinnedIndex == index
        return HStack(spacing: Tokens.Spacing.sm) {
            Button {
                onTapCell(index)
            } label: {
                HStack(spacing: Tokens.Spacing.sm) {
                    content(for: module)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(GlyphButtonStyle())
            .accessibilityLabel(module.displayName)

            actionGlyph(for: module)
        }
        .padding(.horizontal, Tokens.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 50)
        .background(hot ? Tokens.Color.surface : SwiftUI.Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(alignment: .bottom) {
            if pinned {
                Capsule()
                    .fill(Tokens.Color.accent)
                    .frame(height: 2)
                    .padding(.horizontal, Tokens.Spacing.sm)
                    .padding(.bottom, 1)
            }
        }
        .overlay {
            // 07-12 (PANEL-09): the standard 2pt accent focus ring, drawn only for the band's OWN
            // keyboard focus (`BandFocus.zone == .band(i)`) — distinct from `pinned`'s bottom
            // capsule, which tracks the mouse/keyboard-shared droplet-pin state above.
            if keyFocusIndex == index {
                RoundedRectangle(cornerRadius: 12)
                    .inset(by: 1)
                    .stroke(Tokens.Color.accent, lineWidth: 2)
            }
        }
    }

    @ViewBuilder
    private func content(for module: BandModule) -> some View {
        switch module {
        case .nowPlaying: nowPlayingContent
        case .timer: timerContent
        case .nextMeeting: nextMeetingContent
        case .clipboard: clipboardContent
        }
    }

    // MARK: - Action glyphs (PANEL-05)

    /// The module's one-click primary action, a 24pt circle whose hit region never overlaps the
    /// cell body's own `Button` — absent entirely when the module has no applicable action right
    /// now (edge PANEL-05 empty: no session to play/pause, no soon/linked meeting, empty history).
    @ViewBuilder
    private func actionGlyph(for module: BandModule) -> some View {
        switch module {
        case .nowPlaying:
            if Self.hasNowPlayingAction(nowPlaying) {
                glyphButton(
                    systemName: nowPlaying.isPlayingForDisplay ? "pause.fill" : "play.fill",
                    tooltip: nowPlaying.isPlayingForDisplay ? "Pause" : "Play",
                    symbolReplace: true
                ) {
                    performPrimaryAction(for: .nowPlaying)
                }
            }

        case .timer:
            if timer.isPaused {
                glyphButton(systemName: "play.fill", tooltip: "Resume") {
                    performPrimaryAction(for: .timer)
                }
            } else if timer.isRunning {
                glyphButton(systemName: "pause.fill", tooltip: "Pause") {
                    performPrimaryAction(for: .timer)
                }
            } else {
                glyphButton(systemName: "play.fill", tooltip: "Start 25m") {
                    performPrimaryAction(for: .timer)
                }
            }

        case .nextMeeting:
            if let event = calendar.events.first, Self.shouldShowJoinGlyph(for: event) {
                glyphButton(systemName: "video.fill", tooltip: "Join", primary: true) {
                    performPrimaryAction(for: .nextMeeting)
                }
            }

        case .clipboard:
            if Self.hasClipboardAction(clipboard) {
                glyphButton(systemName: "doc.on.doc", tooltip: "Copy latest again") {
                    performPrimaryAction(for: .clipboard)
                }
            }
        }
    }

    /// Now Playing shows its play/pause glyph only when there's a current track to act on
    /// (07-review IN-01, mirroring `shouldShowJoinGlyph`'s own doc comment): `static` so
    /// `NotchPanelController.performPrimaryAction(for:on:)`'s guard reads the identical check
    /// and the two can never drift apart.
    static func hasNowPlayingAction(_ provider: NowPlayingProvider) -> Bool {
        provider.currentModel != nil
    }

    /// Copy-latest-again shows only when clipboard history has an entry (07-review IN-01) —
    /// `static` for the same reason as `hasNowPlayingAction`.
    static func hasClipboardAction(_ provider: ClipboardViewModel) -> Bool {
        provider.entries.first != nil
    }

    /// 07-12 (PANEL-09): the one place a glyph click AND a keyboard Return (routed through
    /// `NotchPanelController.sendEvent`'s key routing → `.performGlyph(i)` →
    /// `NotchViewModel.onPerformPrimaryAction`) both land — `onPerformPrimaryAction` is the
    /// injected closure to `NotchPanelController.performPrimaryAction(for:on:)`, the actual action
    /// implementation (moved off this view so the AppKit key-routing path can call the identical
    /// code a click already ran).
    private func performPrimaryAction(for module: BandModule) {
        onPerformPrimaryAction(module)
    }

    private func glyphButton(
        systemName: String,
        tooltip: String,
        primary: Bool = false,
        symbolReplace: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Group {
                if symbolReplace {
                    Image(systemName: systemName)
                        .contentTransition(.symbolEffect(.replace))
                } else {
                    Image(systemName: systemName)
                }
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(primary ? Tokens.Color.accentInk : Tokens.Color.text)
            .frame(width: 24, height: 24)
            .background(primary ? Tokens.Color.accent : Tokens.Color.surfaceRaised)
            .clipShape(Circle())
        }
        .buttonStyle(GlyphButtonStyle())
        .help(tooltip)
    }

    /// Join shows only when the next event carries a link AND either starts within 15 minutes or
    /// is already under way (07-DESIGN-AGREEMENT.md §4). `static` (07-12): reused by
    /// `NotchPanelController.performPrimaryAction(for:on:)` so the glyph-visibility check and the
    /// action's own guard can never drift apart.
    static func shouldShowJoinGlyph(for event: CalendarEventModel) -> Bool {
        guard event.joinURL != nil else { return false }
        let now = Date()
        let isRunning = event.startDate <= now && now < event.endDate
        let startsSoon = event.startDate > now && event.startDate.timeIntervalSince(now) <= 15 * 60
        return isRunning || startsSoon
    }

    // MARK: - Now Playing

    private var nowPlayingContent: some View {
        let playing = nowPlaying.currentModel?.isPlaying == true
        return Group {
            ArtworkTile(artwork: nowPlaying.artwork, size: 30, cornerRadius: 8)
                .opacity(playing ? 1 : 0.4)
                .saturation(playing ? 1 : 0)
            twoLine(
                primary: nowPlaying.currentModel?.title.isEmpty == false ? nowPlaying.currentModel!.title : "Not playing",
                secondary: nowPlaying.currentModel?.artist.isEmpty == false ? nowPlaying.currentModel!.artist : "—",
                primaryMuted: !playing
            )
        }
    }

    // MARK: - Timer

    private var timerContent: some View {
        Group {
            if timer.isRunning {
                ZStack {
                    Circle()
                        .stroke(Tokens.timerColor(for: timer.tokenState).opacity(0.18), lineWidth: 2.5)
                    Circle()
                        .trim(from: 0, to: timer.progressFraction)
                        .stroke(Tokens.timerColor(for: timer.tokenState), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 30, height: 30)
                twoLine(
                    primary: clockText(timer.remaining),
                    secondary: timerSubtitle,
                    primaryFont: Tokens.Font.data,
                    primaryTransition: true
                )
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Tokens.Color.surfaceRaised)
                    .frame(width: 30, height: 30)
                    .overlay {
                        Text("25m")
                            .font(.system(size: 10, weight: .semibold).monospaced())
                            .foregroundStyle(Tokens.Color.textMuted)
                    }
                twoLine(primary: "No timer", secondary: "Start focus 25m", primaryMuted: true)
            }
        }
    }

    private var timerSubtitle: String {
        switch timer.mode {
        case .pomodoroFocus: return "Focus \(max(timer.cycle, 1))/\(timer.totalCycles)"
        case .pomodoroBreak: return "Break"
        case .countdown, nil: return "Countdown"
        }
    }

    private func clockText(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    // MARK: - Next meeting

    private var nextMeetingContent: some View {
        Group {
            switch calendar.authorizationState {
            case .granted:
                if let event = calendar.events.first {
                    calendarTile(date: event.startDate)
                    twoLine(
                        primary: event.title,
                        secondary: flashMessages[.nextMeeting] ?? "\(Self.timeFormatter.string(from: event.startDate)) \u{00B7} in \(RelativeTimeFormat.string(remaining: event.startDate.timeIntervalSinceNow, rounding: .floor))"
                    )
                } else {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Tokens.Color.surfaceRaised)
                        .frame(width: 30, height: 30)
                        .overlay {
                            Image(systemName: "calendar")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Tokens.Color.textMuted)
                        }
                    twoLine(primary: "No meetings", secondary: "—", primaryMuted: true)
                }
            case .denied, .restricted, .notDetermined:
                RoundedRectangle(cornerRadius: 8)
                    .fill(Tokens.Color.surfaceRaised)
                    .frame(width: 30, height: 30)
                    .overlay {
                        Image(systemName: "calendar")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Tokens.Color.textMuted)
                    }
                twoLine(primary: "Calendar", secondary: "Calendar access", primaryMuted: true)
            }
        }
    }

    private func calendarTile(date: Date) -> some View {
        VStack(spacing: 0) {
            Text(Self.weekdayFormatter.string(from: date).uppercased())
                .font(.system(size: 7, weight: .bold).monospaced())
                .tracking(0.6)
                .foregroundStyle(Tokens.Color.accentWarm)
            Text(Self.dayFormatter.string(from: date))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Tokens.Color.text)
        }
        .frame(width: 30, height: 30)
        .background(Tokens.Color.surfaceRaised)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Clipboard

    private var clipboardContent: some View {
        Group {
            RoundedRectangle(cornerRadius: 8)
                .fill(Tokens.Color.surfaceRaised)
                .frame(width: 30, height: 30)
                .overlay {
                    Image(systemName: "list.clipboard")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Tokens.Color.textMuted)
                }
            twoLine(primary: "Clipboard", secondary: flashMessages[.clipboard] ?? (clipboard.entries.first?.text ?? "Empty"))
        }
    }

    // MARK: - Shared two-line summary

    private func twoLine(
        primary: String,
        secondary: String,
        primaryMuted: Bool = false,
        primaryFont: Font = .system(size: 12.5, weight: .semibold),
        primaryTransition: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Group {
                if primaryTransition {
                    Text(primary)
                        .contentTransition(.numericText())
                        .animation(.default, value: primary)
                } else {
                    Text(primary)
                }
            }
            .font(primaryFont)
            .foregroundStyle(primaryMuted ? Tokens.Color.textMuted : Tokens.Color.text)
            .lineLimit(1)
            .truncationMode(.tail)

            Text(secondary)
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(Tokens.Color.textMuted)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(minWidth: 0, alignment: .leading)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    private static let weekdayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEE")
        return formatter
    }()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("d")
        return formatter
    }()
}
