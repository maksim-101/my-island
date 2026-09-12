import SwiftUI
import Foundation
import AppKit

/// The Calendar stage body (popup-cockpit3-FINAL.html "Calendar selected · 3
/// concurrent"): up to three event pills from `calendar.events`. Each pill is
/// tappable to open the event in Calendar.app (`calshow:` deep link); a `Join`
/// primary button appears to its right ONLY when the event carries a detected
/// video link. Keeps the denied/not-determined access-gate state and the
/// neutral empty-state line. Never the amber attention color and no persistent
/// collapsed-notch badge — a denied calendar (or an empty one) is neutral, not
/// urgent (D-03).
@MainActor
struct CalendarPanelView: View {
    let calendar: CalendarProvider

    var body: some View {
        switch calendar.authorizationState {
        case .denied, .restricted, .notDetermined:
            accessGateState
        case .granted:
            grantedState
        }
    }

    @ViewBuilder
    private var grantedState: some View {
        if !calendar.events.isEmpty {
            VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                // Render `events` (up to 3 concurrent), not the 2-capped
                // `displayedEvents` — the Cockpit stage shows every overlapping
                // meeting, not just the running one + its successor.
                ForEach(calendar.events.prefix(3)) { event in
                    EventPillView(event: event, countdownText: calendar.countdowns[event.id] ?? "")
                }
            }
        } else {
            Text("No upcoming meetings.")
                .font(Tokens.Font.bodyMD)
                .foregroundStyle(Tokens.Color.textFaint)
        }
    }

    private var accessGateState: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.sm) {
            Text("Calendar access needed — my-island can't read your events until access is granted.")
                .font(Tokens.Font.bodyMD)
                .foregroundStyle(Tokens.Color.textMuted)

            Button {
                calendar.requestOrOpenSettings()
            } label: {
                Text("Grant Access")
                    .font(Tokens.Font.label)
                    .foregroundStyle(Tokens.Color.accent)
                    .padding(.horizontal, Tokens.Spacing.sm)
                    .padding(.vertical, Tokens.Spacing.xs)
                    .overlay {
                        RoundedRectangle(cornerRadius: Tokens.Radius.sm)
                            .stroke(Tokens.Color.hairline, lineWidth: 1)
                    }
            }
            .buttonStyle(.plain)
            .help("Grant Calendar access")
        }
    }
}

/// A single event pill: "{Title} — {Location} · {Time}" (the "— {Location}"
/// segment omitted when `location` is nil/empty — never a dangling em dash)
/// with a trailing live countdown in `accent`. Tapping the pill opens the event
/// in Calendar.app via a `calshow:` deep link. A `Join` button follows only
/// when `event.joinURL` is non-nil (hidden, never disabled/greyed, when no
/// video link was detected).
private struct EventPillView: View {
    let event: CalendarEventModel
    let countdownText: String

    @State private var isJoinHovering = false

    var body: some View {
        HStack(spacing: Tokens.Spacing.sm) {
            Button {
                openInCalendar()
            } label: {
                HStack(spacing: Tokens.Spacing.xs) {
                    // 06-UI-SPEC.md "Panel Content — Calendar Title Truncation": explicit priority
                    // order, title highest, location droppable first. Title raised above the
                    // HStack's implicit default (0) so it is the last thing SwiftUI shrinks; Time
                    // is .fixedSize() so it always renders in full; Location is left at the
                    // default priority so it degrades before Title ever loses a character.
                    Text(event.title)
                        .font(Tokens.Font.bodyMD)
                        .foregroundStyle(Tokens.Color.text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(2)

                    if let location = event.location, !location.isEmpty {
                        Text("— \(location)")
                            .font(Tokens.Font.bodyMD)
                            .foregroundStyle(Tokens.Color.text)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }

                    Text("\u{00B7} \(Self.timeFormatter.string(from: event.startDate))")
                        .font(Tokens.Font.bodyMD)
                        .foregroundStyle(Tokens.Color.text)
                        .fixedSize()

                    Spacer(minLength: Tokens.Spacing.sm)

                    Text(countdownText)
                        .font(Tokens.Font.label)
                        .foregroundStyle(Tokens.Color.accent)
                }
                .padding(.horizontal, Tokens.Spacing.md)
                .padding(.vertical, Tokens.Spacing.xs)
                .frame(maxWidth: .infinity)
                .background(Tokens.Color.surfaceRaised)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("Open in Calendar")

            if let joinURL = event.joinURL {
                Button {
                    NSWorkspace.shared.open(joinURL)
                } label: {
                    Text("Join")
                        .font(Tokens.Font.buttonPrimary)
                        .foregroundStyle(Tokens.Color.accentInk)
                        .padding(.horizontal, Tokens.Spacing.md)
                        .padding(.vertical, Tokens.Spacing.sm)
                        .background(Tokens.Color.accent)
                        .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.sm))
                }
                .buttonStyle(.plain)
                .brightness(isJoinHovering ? 0.1 : 0)
                .onHover { isJoinHovering = $0 }
                .help("Join meeting")
            }
        }
    }

    /// Opens Calendar.app and navigates it to the event's day. The documented
    /// `calshow:` URL scheme is NOT registered on this Mac (verified: even
    /// `/usr/bin/open calshow:…` returns `kLSApplicationNotFoundErr`), so
    /// `NSWorkspace.open` can't route it. Instead we drive Calendar via an
    /// Apple Event, matching this codebase's subprocess-`osascript` convention
    /// (`CCMetrics/SessionFocuser`). Only integer date components are
    /// interpolated — never any event string (T-05-01) — and the date is built
    /// day-first so a short month can't overflow. Triggers a one-time Automation
    /// (Apple Events → Calendar) permission prompt on first use.
    private func openInCalendar() {
        let c = Foundation.Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute], from: event.startDate
        )
        guard let y = c.year, let mo = c.month, let d = c.day,
              let h = c.hour, let mi = c.minute else { return }
        let script = """
        set d to current date
        set day of d to 1
        set year of d to \(y)
        set month of d to \(mo)
        set day of d to \(d)
        set hours of d to \(h)
        set minutes of d to \(mi)
        set seconds of d to 0
        tell application "Calendar"
        activate
        view calendar at d
        switch view to day view
        end tell
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        try? process.run()
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()
}
