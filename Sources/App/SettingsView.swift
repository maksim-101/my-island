import SwiftUI
import KeyboardShortcuts
import MyIslandCore

struct SettingsView: View {
    let calendar: CalendarProvider
    let panels: NotchPanelController

    @State private var calendarGroups: [(sourceName: String, calendars: [(id: String, title: String)])] = []
    @AppStorage(NotchPanelController.showOnNotchlessDisplaysKey) private var showOnNotchlessDisplays = NotchPanelController.showOnNotchlessDisplaysDefault
    @AppStorage(NotchPanelController.wingLeftContentKey) private var wingLeftContent = NotchPanelController.wingLeftContentDefault
    @AppStorage(NotchPanelController.surfaceMaterialKey) private var surfaceMaterial = NotchPanelController.surfaceMaterialDefault
    /// MOD-01 (07-11): the persisted enabled-module list — comma-joined `BandModule.rawValue`s,
    /// the same physical `String` representation `NotchPanelController.enabledModulesFromDefaults()`
    /// parses (SwiftUI's `AppStorage` has no native `Array<String>` support).
    @AppStorage(NotchPanelController.enabledModulesKey) private var enabledModulesRaw = NotchPanelController.enabledModulesDefault.joined(separator: ",")

    private var enabledModules: [BandModule] {
        BandModules.enabled(from: enabledModulesRaw.split(separator: ",").map(String.init))
    }

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

            // 07-11 (MOD-01, agreement §8): one switch per band module in fixed order — no
            // reordering in Phase 7. The stored raw-value list is the band's only module source
            // (NotchPanelController.enabledModules/NotchContentView's own copy) as of this plan;
            // Claude already persists here but stays out of the drawn band until plan 14 removes
            // modulesAwaitingDataSource.
            Section("Modules") {
                ForEach(BandModule.allCases, id: \.self) { module in
                    let enabled = enabledModules
                    Toggle(module.displayName, isOn: Binding(
                        get: { enabled.contains(module) },
                        set: { _ in
                            let updated = BandModules.toggling(module, in: enabled)
                            enabledModulesRaw = updated.map(\.rawValue).joined(separator: ",")
                        }
                    ))
                    .disabled(!BandModules.canDisable(module, in: enabled))
                }
                Text("The band needs at least one module. Reordering is not available.")
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
        .frame(width: 420, height: 640)
        .task {
            calendarGroups = await calendar.availableCalendarsGroupedBySource()
        }
        .onChange(of: showOnNotchlessDisplays) {
            panels.rebuildPanels()
        }
        .onChange(of: enabledModulesRaw) {
            panels.modulesChanged()
        }
    }
}
