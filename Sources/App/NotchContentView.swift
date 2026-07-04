import SwiftUI
import AppKit

@MainActor
struct NotchContentView: View {
    private var collapsedSize: CGSize {
        if let notchFrame = NSScreen.main?.notchFrame {
            return CGSize(width: notchFrame.width, height: notchFrame.height)
        }
        return CGSize(width: 200, height: 32)
    }

    var body: some View {
        NotchShape(topCornerRadius: 6, bottomCornerRadius: 14)
            .fill(Color.black)
            .frame(width: collapsedSize.width, height: collapsedSize.height)
            .overlay {
                Image(systemName: "circle.lefthalf.filled")
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(.white.opacity(0.55))
            }
    }
}
