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
    let timer: TimerViewModel
    let nowPlaying: NowPlayingProvider
    let calendar: CalendarProvider
    let clipboard: ClipboardViewModel
    /// 07-14 (CLAUDE-01/02/03): the read-only, 3s-polled session list — the Claude cell's own
    /// data source, replacing plan 08's `EmptyView()` placeholder.
    let claudeSessions: ClaudeSessionsProvider
    let onTapCell: (Int) -> Void

    /// Transient "Opening…"/"Copied" confirmation text (sketch `say`, 1.3s) for the two glyphs
    /// whose action has no other visible state change to confirm it (Join opens a URL; the
    /// clipboard glyph re-copies silently) — keyed by module since only one instance of each
    /// module exists per band. Now Playing/Timer glyphs confirm via their own icon swap instead.
    @State private var flashMessages: [BandModule: String] = [:]
    @State private var flashTasks: [BandModule: Task<Void, Never>] = [:]

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
    }

    @ViewBuilder
    private func content(for module: BandModule) -> some View {
        switch module {
        case .nowPlaying: nowPlayingContent
        case .timer: timerContent
        case .nextMeeting: nextMeetingContent
        case .clipboard: clipboardContent
        case .claude: claudeContent
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
            if nowPlaying.currentModel != nil {
                glyphButton(
                    systemName: nowPlaying.isPlayingForDisplay ? "pause.fill" : "play.fill",
                    tooltip: nowPlaying.isPlayingForDisplay ? "Pause" : "Play",
                    symbolReplace: true
                ) {
                    nowPlaying.send(.togglePlayPause)
                }
            }

        case .timer:
            if timer.isPaused {
                glyphButton(systemName: "play.fill", tooltip: "Resume") {
                    timer.resume()
                }
            } else if timer.isRunning {
                glyphButton(systemName: "pause.fill", tooltip: "Pause") {
                    timer.pause()
                }
            } else {
                glyphButton(systemName: "play.fill", tooltip: "Start 25m") {
                    timer.startPomodoro()
                }
            }

        case .nextMeeting:
            if let event = calendar.events.first, shouldShowJoinGlyph(for: event) {
                glyphButton(systemName: "video.fill", tooltip: "Join", primary: true) {
                    startJoin(event)
                }
            }

        case .clipboard:
            if clipboard.entries.first != nil {
                glyphButton(systemName: "doc.on.doc", tooltip: "Copy latest again") {
                    copyLatestClipboardEntry()
                }
            }

        // 07-14 (CLAUDE-02, agreement §4): jump to the top waiting session's pane — absent when
        // nothing needs the user (edge PANEL-05 empty), matching every other module's glyph-absent
        // convention above.
        case .claude:
            if let top = claudeSessions.waiting.first {
                glyphButton(systemName: "arrow.up.right", tooltip: "Jump to pane", amber: true) {
                    jumpToClaudePane(top)
                }
            }
        }
    }

    private func glyphButton(
        systemName: String,
        tooltip: String,
        primary: Bool = false,
        amber: Bool = false,
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
            .foregroundStyle(primary ? Tokens.Color.accentInk : (amber ? Tokens.Color.signal : Tokens.Color.text))
            .frame(width: 24, height: 24)
            .background(primary ? Tokens.Color.accent : Tokens.Color.surfaceRaised)
            .clipShape(Circle())
        }
        .buttonStyle(GlyphButtonStyle())
        .help(tooltip)
    }

    /// Join shows only when the next event carries a link AND either starts within 15 minutes or
    /// is already under way (07-DESIGN-AGREEMENT.md §4).
    private func shouldShowJoinGlyph(for event: CalendarEventModel) -> Bool {
        guard event.joinURL != nil else { return false }
        let now = Date()
        let isRunning = event.startDate <= now && now < event.endDate
        let startsSoon = event.startDate > now && event.startDate.timeIntervalSince(now) <= 15 * 60
        return isRunning || startsSoon
    }

    private func startJoin(_ event: CalendarEventModel) {
        guard let joinURL = event.joinURL else { return }
        flash("Opening\u{2026}", for: .nextMeeting)
        NSWorkspace.shared.open(joinURL)
    }

    private func copyLatestClipboardEntry() {
        guard let entry = clipboard.entries.first else { return }
        clipboard.select(entry)
        flash("Copied", for: .clipboard)
    }

    /// 07-14: flashes "Jumping…" immediately (the subprocess chain — `/bin/ps` then
    /// `/usr/bin/osascript` — is not instant), then supersedes it with "Pane not found" on
    /// failure via the same `flash(_:for:)` cancel-and-restart mechanism every other glyph uses; a
    /// success leaves the "Jumping…" flash to clear on its own 1.3s timer.
    private func jumpToClaudePane(_ session: ClaudeSession) {
        flash("Jumping to iTerm2 pane\u{2026}", for: .claude)
        Task { @MainActor in
            let succeeded = await ClaudePaneJumper.jump(to: session)
            if !succeeded {
                flash("Pane not found", for: .claude)
            }
        }
    }

    /// Sketch `say` (1.3s flash, index.html `act()`): replaces the cell's own secondary line with
    /// `text` for confirmation, then restores it — cancels any flash already in flight for the
    /// SAME module so a rapid re-click doesn't clear early.
    private func flash(_ text: String, for module: BandModule) {
        flashTasks[module]?.cancel()
        flashMessages[module] = text
        flashTasks[module] = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.3))
            guard !Task.isCancelled else { return }
            flashMessages[module] = nil
        }
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

    // MARK: - Claude

    /// 07-14 (CLAUDE-01/03, sketch `CELL.claude`): a 30pt badge — amber with the waiting count
    /// when a session needs the user, quiet with the total session count otherwise; line 1 is the
    /// top waiting session's repo (amber) or "Claude"; line 2 is "Permission"/"Your turn", else
    /// the total-session summary. Every session-supplied string (only `repo` here) passes through
    /// `ClaudeSessions.displaySafe` (T-07-21).
    private var claudeContent: some View {
        let top = claudeSessions.waiting.first
        let badgeCount = top != nil ? claudeSessions.waitingCount : claudeSessions.sessions.count
        return Group {
            Text("\(badgeCount)")
                .font(.system(size: 12, weight: .bold).monospaced())
                .foregroundStyle(top != nil ? Tokens.Color.signal : Tokens.Color.textMuted)
                .frame(width: 30, height: 30)
                .background(top != nil ? Tokens.Color.signal.opacity(0.14) : Tokens.Color.surfaceRaised)
                .clipShape(Circle())
            twoLine(
                primary: top.map { ClaudeSessions.displaySafe($0.repo) } ?? "Claude",
                secondary: flashMessages[.claude] ?? claudeSecondary(top: top),
                primaryColor: top != nil ? Tokens.Color.signal : nil
            )
        }
    }

    /// "Permission" / "Your turn" while a session waits; otherwise the total-session summary
    /// (edge: 0 sessions reads "No sessions", matching the must_haves empty-state truth exactly).
    private func claudeSecondary(top: ClaudeSession?) -> String {
        if let top {
            return top.status == .awaitingPermission ? "Permission" : "Your turn"
        }
        let total = claudeSessions.sessions.count
        guard total > 0 else { return "No sessions" }
        return "\(total) session\(total == 1 ? "" : "s") working"
    }

    // MARK: - Shared two-line summary

    private func twoLine(
        primary: String,
        secondary: String,
        primaryMuted: Bool = false,
        primaryColor: SwiftUI.Color? = nil,
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
            .foregroundStyle(primaryColor ?? (primaryMuted ? Tokens.Color.textMuted : Tokens.Color.text))
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
