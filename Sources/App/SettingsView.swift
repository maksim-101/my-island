import SwiftUI
import KeyboardShortcuts

struct SettingsView: View {
    var body: some View {
        Form {
            Section("Toggle shortcut") {
                KeyboardShortcuts.Recorder(for: .toggleNotchPanel)
                Text("Requires ⌘, ⌃, or ⌥ (not ⇧ alone). System-reserved keys (e.g. ⌘M, ⌃Space) won't take.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 180)
    }
}
