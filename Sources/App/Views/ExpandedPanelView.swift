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
                .font(Tokens.Font.title)
                .foregroundStyle(Tokens.Color.text)

            TimerPanelView(timer: timer)
            // Let the clipboard take the panel's remaining vertical space so its
            // scroll area actually uses the height (otherwise the slack becomes
            // empty space at the bottom and only ~2 rows show).
            ClipboardPanelView(clipboard: clipboard)
                .frame(maxHeight: .infinity, alignment: .top)
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
                .font(Tokens.Font.data)
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
                .font(Tokens.Font.bodyMD)
                .foregroundStyle(Tokens.Color.textFaint)
        }
        .buttonStyle(.plain)
        .help("Quit my-island")
    }
}
