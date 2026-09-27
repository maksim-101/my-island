import SwiftUI
import Foundation
import AppKit

/// The Next-meeting detail droplet (07-DESIGN-AGREEMENT.md §4, §9, sketch `DETAIL.meet`,
/// `.planning/sketches/006-design-round/index.html:659-670`): the next/running event's title,
/// time range and service (or location), up to three attendee initials + head count, Join (only
/// with a detected video link) and Open in Calendar — both `GlyphButtonStyle` — and a filler row
/// naming what follows or, with nothing after it, when the calendar's own alerts fire. Renders the
/// one event `CalendarSlotSelector` already promotes to `displayedEvents.first` — the old
/// up-to-three-concurrent event pill list is gone (D-02/D-12's "up to 3 concurrent" reading was
/// superseded by the band+droplet redesign, 07-08).
@MainActor
struct CalendarPanelView: View {
    let calendar: CalendarProvider

    var body: some View {
        Group {
            switch calendar.authorizationState {
            case .denied, .restricted, .notDetermined:
                accessGateState
            case .granted:
                grantedState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private var grantedState: some View {
        if let event = calendar.displayedEvents.first {
            eventDetail(event)
        } else {
            emptyState
        }
    }

    private func eventDetail(_ event: CalendarEventModel) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.sm) {
            Text(label(for: event))
                .font(.system(size: 9, weight: .bold).monospaced())
                .tracking(0.4)
                .foregroundStyle(Tokens.Color.textFaint)

            Text(event.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Tokens.Color.text)
                .lineLimit(1)
                .truncationMode(.tail)

            Text(timeRangeText(event))
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(Tokens.Color.textMuted)
                .lineLimit(1)
                .truncationMode(.tail)

            if !event.attendeeNames.isEmpty {
                HStack {
                    attendeeAvatars(event.attendeeNames)
                    Spacer()
                    Text("\(event.attendeeNames.count) people")
                        .font(.system(size: 10.5, weight: .regular))
                        .foregroundStyle(Tokens.Color.textMuted)
                }
            }

            HStack(spacing: Tokens.Spacing.sm) {
                if let joinURL = event.joinURL {
                    Button {
                        NSWorkspace.shared.open(joinURL)
                    } label: {
                        Text("Join")
                            .font(Tokens.Font.buttonPrimary)
                            .foregroundStyle(Tokens.Color.accentInk)
                            .frame(maxWidth: .infinity)
                            .frame(height: 28)
                            .background(Tokens.Color.accent)
                            .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.sm))
                    }
                    .buttonStyle(GlyphButtonStyle())
                    .help("Join meeting")
                }

                Button {
                    openInCalendar(event.startDate)
                } label: {
                    Text("Open")
                        .font(Tokens.Font.bodyMD)
                        .foregroundStyle(Tokens.Color.text)
                        .frame(maxWidth: .infinity)
                        .frame(height: 28)
                        .background(Tokens.Color.surfaceRaised)
                        .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.sm))
                }
                .buttonStyle(GlyphButtonStyle())
                .help("Open in Calendar")
            }

            Spacer(minLength: 0)

            fillerRow
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.sm) {
            Text("NOTHING ELSE TODAY")
                .font(.system(size: 9, weight: .bold).monospaced())
                .tracking(0.4)
                .foregroundStyle(Tokens.Color.textFaint)

            Button {
                openInCalendar(.now)
            } label: {
                Text("Open in Calendar")
                    .font(Tokens.Font.bodyMD)
                    .foregroundStyle(Tokens.Color.text)
                    .padding(.horizontal, Tokens.Spacing.md)
                    .frame(height: 28)
                    .background(Tokens.Color.surfaceRaised)
                    .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.sm))
            }
            .buttonStyle(GlyphButtonStyle())
            .help("Open in Calendar")

            Spacer(minLength: 0)

            fillerRow
        }
    }

    /// "Then · HH:mm · secondary title" when a second event is running/imminent alongside the
    /// primary one; otherwise the fixed 1h/15m/at-start alert schedule (`ThresholdScheduler`'s own
    /// three thresholds, agreement §9) — the literal string below is what the plan's own
    /// acceptance grep matches, so it is written with the real middle dot, not an escape.
    private var fillerRow: some View {
        HStack {
            if calendar.displayedEvents.count > 1 {
                let secondary = calendar.displayedEvents[1]
                Text("Then")
                Spacer()
                Text("\(Self.timeFormatter.string(from: secondary.startDate)) \u{00B7} \(secondary.title)")
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else {
                Text("Alerts")
                Spacer()
                Text("1 h · 15 min · at start")
            }
        }
        .font(.system(size: 11, weight: .regular))
        .foregroundStyle(Tokens.Color.textMuted)
        .padding(.top, Tokens.Spacing.sm)
        .overlay(alignment: .top) {
            Rectangle().fill(Tokens.Color.hairline).frame(height: 1)
        }
    }

    private func attendeeAvatars(_ names: [String]) -> some View {
        let shown = Array(names.prefix(3))
        let overflow = max(0, names.count - shown.count)
        return HStack(spacing: -5) {
            ForEach(Array(shown.enumerated()), id: \.offset) { _, name in
                avatarCircle(text: initials(for: name), foreground: Tokens.Color.text)
            }
            if overflow > 0 {
                avatarCircle(text: "+\(overflow)", foreground: Tokens.Color.textMuted)
            }
        }
    }

    private func avatarCircle(text: String, foreground: SwiftUI.Color) -> some View {
        Text(text)
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(foreground)
            .frame(width: 22, height: 22)
            .background(Circle().fill(Tokens.Color.surfaceRaised))
            .overlay(Circle().stroke(Tokens.Color.background, lineWidth: 1.5))
    }

    private func initials(for name: String) -> String {
        let parts = name.split(separator: " ")
        let letters = parts.prefix(2).compactMap { $0.first }
        if letters.isEmpty { return String(name.prefix(2)).uppercased() }
        return String(letters).uppercased()
    }

    /// "NEXT · IN {RelativeTimeFormat}", or "NOW" once the event has started — `countdowns[event.id]`
    /// already reads "now" at/below zero remaining (`RelativeTimeFormat.string`), so this needs no
    /// separate has-it-started check of its own.
    private func label(for event: CalendarEventModel) -> String {
        let countdown = calendar.countdowns[event.id] ?? ""
        return countdown == "now" ? "NOW" : "NEXT \u{00B7} IN \(countdown)"
    }

    private func timeRangeText(_ event: CalendarEventModel) -> String {
        let range = "\(Self.timeFormatter.string(from: event.startDate)) \u{2013} \(Self.timeFormatter.string(from: event.endDate))"
        let location = event.location?.trimmingCharacters(in: .whitespaces)
        let detail = event.serviceName ?? (location?.isEmpty == false ? location : nil)
        guard let detail, !detail.isEmpty else { return range }
        return "\(range) \u{00B7} \(detail)"
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
            .buttonStyle(GlyphButtonStyle())
            .help("Grant Calendar access")
        }
    }

    /// Opens Calendar.app and navigates it to `date`'s day. The documented `calshow:` URL scheme
    /// is NOT registered on this Mac (verified: even `/usr/bin/open calshow:…` returns
    /// `kLSApplicationNotFoundErr`), so `NSWorkspace.open` can't route it. Instead we drive
    /// Calendar via an Apple Event, matching this codebase's subprocess-`osascript` convention
    /// (`CCMetrics/SessionFocuser`). Only integer date components are interpolated — never any
    /// event string (T-05-01) — and the date is built day-first so a short month can't overflow.
    /// Triggers a one-time Automation (Apple Events → Calendar) permission prompt on first use.
    private func openInCalendar(_ date: Date) {
        let c = Foundation.Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute], from: date
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
