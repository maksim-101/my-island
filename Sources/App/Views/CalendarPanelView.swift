import SwiftUI
import Foundation

/// Expanded-panel Calendar group (CAL-01, D-03). This plan renders only the
/// denied/not-determined access-gate state; `.granted` is a placeholder
/// (`EmptyView`) until plan 04-03 fills in the upcoming-event chip. Never the
/// amber attention color and no persistent collapsed-notch badge — a denied
/// calendar is neutral, not urgent (D-03).
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
                EmptyView()
            }
        }
    }

    private var accessGateState: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.sm) {
            Text("Calendar access needed — my-island can't read your events until access is granted.")
                .font(Tokens.Font.bodyMD)
                .foregroundStyle(Tokens.Color.textMuted)

            Button {
                NSLog("[CalendarPanelView] Grant Access button action fired")
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
