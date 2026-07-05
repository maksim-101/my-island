import SwiftUI
import AppKit

/// Compact minutes input that supports BOTH manual typing AND scroll-to-adjust
/// (mouse wheel / trackpad), replacing the fiddly `Stepper`. Backed by a native
/// `NSTextField` subclass so the scroll wheel and keyboard land on one control.
struct DurationField: NSViewRepresentable {
    @Binding var minutes: Int
    var range: ClosedRange<Int> = 1...180

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> ScrollableIntField {
        let field = ScrollableIntField()
        field.range = range
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.alignment = .right
        field.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        field.textColor = NSColor(Tokens.Color.text)
        field.delegate = context.coordinator
        field.integerValue = minutes
        field.onScrollChange = { [weak coordinator = context.coordinator] value in
            coordinator?.commit(value)
        }
        context.coordinator.field = field
        return field
    }

    func updateNSView(_ nsView: ScrollableIntField, context: Context) {
        // Don't stomp the value while the user is typing in it.
        if nsView.currentEditor() == nil, nsView.integerValue != minutes {
            nsView.integerValue = minutes
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        let parent: DurationField
        weak var field: ScrollableIntField?
        init(_ parent: DurationField) { self.parent = parent }

        func commit(_ raw: Int) {
            let clamped = min(max(raw, parent.range.lowerBound), parent.range.upperBound)
            field?.integerValue = clamped
            parent.minutes = clamped
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            commit(field?.integerValue ?? parent.minutes)
        }
    }
}

/// `NSTextField` that steps its integer value on scroll (up = more).
final class ScrollableIntField: NSTextField {
    var range: ClosedRange<Int> = 1...180
    var onScrollChange: ((Int) -> Void)?
    private var accumulated: CGFloat = 0

    override func scrollWheel(with event: NSEvent) {
        accumulated += event.scrollingDeltaY
        let pointsPerStep: CGFloat = 4
        var changed = false
        while abs(accumulated) >= pointsPerStep {
            let direction = accumulated > 0 ? 1 : -1
            let next = min(max(integerValue + direction, range.lowerBound), range.upperBound)
            if next != integerValue {
                integerValue = next
                changed = true
            }
            accumulated -= CGFloat(direction) * pointsPerStep
        }
        if changed { onScrollChange?(integerValue) }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 26, height: super.intrinsicContentSize.height)
    }
}
