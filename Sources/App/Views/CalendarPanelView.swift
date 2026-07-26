import SwiftUI
import Foundation
import AppKit

/// Expanded-panel Calendar group (CAL-01, CAL-02, D-03). Renders the
/// denied/not-determined access-gate state, and — once granted — the
/// upcoming-event chip with a live countdown + Join button, or the neutral
/// empty-state line when nothing is scheduled. Never the amber attention
/// color and no persistent collapsed-notch badge — a denied calendar (or an
/// empty one) is neutral, not urgent (D-03).
@MainActor
struct CalendarPanelView: View {
    let calendar: CalendarProvider

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.sm) {
            Text("Calendar")
                .font(Tokens.Font.label)
                .foregroundStyle(Tokens.Color.textMuted)

            switch calendar.authorizationState {
            case .denied, .restricted, .notDetermined:
                accessGateState
            case .granted:
                grantedState
            }
        }
    }

    @ViewBuilder
    private var grantedState: some View {
        if !calendar.displayedEvents.isEmpty {
            // Two rows only while a running meeting overlaps the next one —
            // the running one keeps its Join button, the upcoming one gets a
            // real countdown instead of being hidden for the full hour.
            VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                ForEach(calendar.displayedEvents) { event in
                    UpcomingChipView(event: event, countdownText: calendar.countdowns[event.id] ?? "")
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

/// The upcoming-meeting chip: "{Title} — {Location} · {Time}" (the "—
/// {Location}" segment omitted when `location` is nil/empty — never a
/// dangling em dash) with a trailing live countdown pinned by a `Spacer()`
/// inside the pill, followed by a Join button only when `event.joinURL`
/// is non-nil (hidden, never disabled/greyed, when no video link was
/// detected).
private struct UpcomingChipView: View {
    let event: CalendarEventModel
    let countdownText: String

    @State private var isJoinHovering = false

    var body: some View {
        HStack(spacing: Tokens.Spacing.sm) {
            HStack(spacing: Tokens.Spacing.sm) {
                Text(chipText)
                    .font(Tokens.Font.bodyMD)
                    .foregroundStyle(Tokens.Color.text)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer()

                Text(countdownText)
                    .font(Tokens.Font.label)
                    .foregroundStyle(Tokens.Color.accent)
            }
            .padding(.horizontal, Tokens.Spacing.md)
            .padding(.vertical, Tokens.Spacing.xs)
            .background(Tokens.Color.surfaceRaised)
            .clipShape(Capsule())

            if let joinURL = event.joinURL {
                Button {
                    NSWorkspace.shared.open(joinURL)
                } label: {
                    Text("Join")
                        .font(Tokens.Font.bodyMD.weight(.semibold))
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

    private var chipText: String {
        let time = Self.timeFormatter.string(from: event.startDate)
        if let location = event.location, !location.isEmpty {
            return "\(event.title) — \(location) · \(time)"
        }
        return "\(event.title) · \(time)"
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()
}
