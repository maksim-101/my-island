import SwiftUI
import MyIslandCore

/// D-06 Wave 2 (PANEL-04): the band's row of two-line module summaries — ported per D-02 from
/// `.planning/sketches/006-design-round/index.html`'s `.cell`/`CELL` (lines 43-49, 612-627).
/// `hotIndex`/`pinnedIndex` and `onTapCell` are wired to real interactive state by plan 08 Task 2
/// (`NotchPanelController.hotModule`/`pinnedModule`/`showDroplet(_:)`); this file only renders the
/// row and its own visual hot/pinned states. The trailing round action glyph (sketch `.act`) is
/// plan 09's — not built here.
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
    let onTapCell: (Int) -> Void

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
        return Button {
            onTapCell(index)
        } label: {
            HStack(spacing: Tokens.Spacing.sm) {
                content(for: module)
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
        .buttonStyle(GlyphButtonStyle())
        .accessibilityLabel(module.displayName)
    }

    @ViewBuilder
    private func content(for module: BandModule) -> some View {
        switch module {
        case .nowPlaying: nowPlayingContent
        case .timer: timerContent
        case .nextMeeting: nextMeetingContent
        case .clipboard: clipboardContent
        // Interim (07-15 gap closure note stays 07-08-scoped): unreachable while
        // `NotchPanelController.modulesAwaitingDataSource` keeps `.claude` out of the enabled set —
        // plan 14 adds the real content and removes that set.
        case .claude: EmptyView()
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
                        secondary: "\(Self.timeFormatter.string(from: event.startDate)) \u{00B7} in \(RelativeTimeFormat.string(remaining: event.startDate.timeIntervalSinceNow, rounding: .floor))"
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
            twoLine(primary: "Clipboard", secondary: clipboard.entries.first?.text ?? "Empty")
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
