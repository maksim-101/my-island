import SwiftUI
import KeyboardShortcuts

struct SettingsView: View {
    let calendar: CalendarProvider

    @State private var calendarGroups: [(sourceName: String, calendars: [(id: String, title: String)])] = []

    var body: some View {
        Form {
            Section("Toggle shortcut") {
                KeyboardShortcuts.Recorder(for: .toggleNotchPanel)
                Text("Requires ⌘, ⌃, or ⌥ (not ⇧ alone). System-reserved keys (e.g. ⌘M, ⌃Space) won't take.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Calendars") {
                if calendarGroups.isEmpty {
                    Text("No calendars found.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(calendarGroups, id: \.sourceName) { group in
                        Text(group.sourceName)
                            .font(.headline)
                        ForEach(group.calendars, id: \.id) { calendarItem in
                            Toggle(calendarItem.title, isOn: Binding(
                                get: { calendar.isCalendarSelected(calendarItem.id) },
                                set: { newValue in
                                    Task { await calendar.setCalendarSelected(calendarItem.id, selected: newValue) }
                                }
                            ))
                        }
                    }
                }
                Text("Only toggled-on calendars count toward the next-meeting slot. Newly discovered calendars default to on.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 460)
        .task {
            calendarGroups = await calendar.availableCalendarsGroupedBySource()
        }
    }
}
