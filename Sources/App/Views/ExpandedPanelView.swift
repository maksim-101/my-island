import SwiftUI
import AppKit

@MainActor
struct ExpandedPanelView: View {
    let timer: TimerViewModel

    // Owned here (not in NotchPanelController) so the clipboard slice stays
    // fully decoupled from the HUD/Timer slices (documented trade). Because
    // history is in-memory and clears on quit anyway (D-14), the negligible
    // reset on a rare screen-parameter rebuild of this view is acceptable.
    @State private var clipboard = ClipboardViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.md) {
            Text("my-island")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Tokens.Color.text)

            TimerPanelView(timer: timer)
            ClipboardPanelView(clipboard: clipboard)
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
