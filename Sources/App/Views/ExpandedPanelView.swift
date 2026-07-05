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

            VStack(alignment: .leading, spacing: 2) {
                Text("Toggle shortcut")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.8))
                Text(currentShortcutDescription)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(alignment: .topTrailing) {
            settingsButton
                .padding(12)
        }
        .overlay(alignment: .bottomTrailing) {
            quitButton
                .padding(12)
        }
    }

    private var settingsButton: some View {
        Button {
            NotificationCenter.default.post(name: .openMyIslandSettings, object: nil)
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
        }
        .buttonStyle(.plain)
        .help("Settings…")
    }

    private var quitButton: some View {
        Button {
            NSApp.terminate(nil)
        } label: {
            Image(systemName: "power")
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(.white.opacity(0.5))
        }
        .buttonStyle(.plain)
        .help("Quit my-island")
    }

    private var currentShortcutDescription: String {
        let shortcut = KeyboardShortcuts.getShortcut(for: .toggleNotchPanel)
            ?? KeyboardShortcuts.Name.toggleNotchPanel.defaultShortcut
        return shortcut?.description ?? "Not set"
    }
}
