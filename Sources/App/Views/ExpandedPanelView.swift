import SwiftUI
import AppKit

@MainActor
struct ExpandedPanelView: View {
    let timer: TimerViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.md) {
            Text("my-island")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Tokens.Color.text)

            TimerPanelView(timer: timer)
        }
        .padding(Tokens.Spacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(alignment: .topTrailing) {
            settingsButton
                .padding(Tokens.Spacing.md)
        }
        .overlay(alignment: .bottomTrailing) {
            quitButton
                .padding(Tokens.Spacing.md)
        }
    }

    private var settingsButton: some View {
        Button {
            NotificationCenter.default.post(name: .openMyIslandSettings, object: nil)
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Tokens.Color.textMuted)
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
                .foregroundStyle(Tokens.Color.textFaint)
        }
        .buttonStyle(.plain)
        .help("Quit my-island")
    }
}
