import SwiftUI
import AppKit
import KeyboardShortcuts

@MainActor
struct ExpandedPanelView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("my-island")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)

            Text("Ambient content arrives in Phase 3.")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.6))

            Divider()
                .overlay(Color.white.opacity(0.12))

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Toggle shortcut")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.8))
                    Text(currentShortcutDescription)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.6))
                }

                Button {
                    NotificationCenter.default.post(name: .openMyIslandSettings, object: nil)
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                }
                .buttonStyle(.plain)
                .help("Change shortcut…")

                Spacer()

                Button {
                    NSApp.terminate(nil)
                } label: {
                    Image(systemName: "power")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.75))
                }
                .buttonStyle(.plain)
                .help("Quit my-island")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var currentShortcutDescription: String {
        if let shortcut = KeyboardShortcuts.getShortcut(for: .toggleNotchPanel) {
            return shortcut.description
        }
        return "Not set"
    }
}
