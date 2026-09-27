import SwiftUI
import KeyboardShortcuts

struct SettingsView: View {
    let calendar: CalendarProvider
    let panels: NotchPanelController

    @State private var calendarGroups: [(sourceName: String, calendars: [(id: String, title: String)])] = []
    @AppStorage(NotchPanelController.showOnNotchlessDisplaysKey) private var showOnNotchlessDisplays = NotchPanelController.showOnNotchlessDisplaysDefault
    @AppStorage(NotchPanelController.wingLeftContentKey) private var wingLeftContent = NotchPanelController.wingLeftContentDefault
    @AppStorage(NotchPanelController.surfaceMaterialKey) private var surfaceMaterial = NotchPanelController.surfaceMaterialDefault

    var body: some View {
        Form {
            Section("Toggle shortcut") {
                KeyboardShortcuts.Recorder(for: .toggleNotchPanel)
                Text("Requires ⌘, ⌃, or ⌥ (not ⇧ alone). System-reserved keys (e.g. ⌘M, ⌃Space) won't take.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // 07-02 Task 3: the two Fluid-redesign settings — the left wing's content while a
            // timer runs (agreement §2's promoted assumption-delta decision) and, since 07-01
            // recorded `material_decision: option`, the collapsed-surface material (D-07).
            Section("Notch") {
                Picker("With a timer running, the left wing shows", selection: $wingLeftContent) {
                    Text("Artwork").tag("artwork")
                    Text("Sound wave").tag("wave")
                }
                Text("With no timer running, the left wing always shows artwork when music plays.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Surface", selection: $surfaceMaterial) {
                    Text("Black").tag("black")
                    Text("Liquid Glass").tag("glass")
                }
                Text("The MacBook pill stays black so it merges with the camera.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Displays") {
                Toggle("Show on displays without a notch", isOn: $showOnNotchlessDisplays)
                Text("Draws a pill under the menu bar on external displays. Off hides it there; the built-in notch is unaffected.")
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
        .onChange(of: showOnNotchlessDisplays) {
            panels.rebuildPanels()
        }
    }
}
