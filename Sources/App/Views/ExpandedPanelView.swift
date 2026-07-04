import SwiftUI
import AppKit

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
                    Text("Recorder added in Plan 03")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.45))
                }

                Spacer()

                Button("Quit my-island") {
                    NSApp.terminate(nil)
                }
                .font(.system(size: 11, weight: .medium))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
