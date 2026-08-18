import SwiftUI
import AppKit

/// Compact minutes input that supports BOTH manual typing AND scroll-to-adjust
/// (mouse wheel / trackpad), replacing the fiddly `Stepper`. Backed by a native
/// `NSTextField` subclass so the scroll wheel and keyboard land on one control.
struct DurationField: NSViewRepresentable {
    /// `nil` renders the field empty (placeholder only) — the idle picker starts
    /// with no duration chosen rather than a silent default.
    @Binding var minutes: Int?
    /// Up to 24h — the old 180-minute ceiling silently clamped anything longer
    /// with no feedback, so typing 1000 became 180.
    var range: ClosedRange<Int> = 1...1440

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
        field.placeholderString = "\u{2013}\u{2013}"
        field.stringValue = minutes.map(String.init) ?? ""
        // The SwiftUI `.accessibilityLabel` modifier applied at the call site lands on this
        // `NSViewRepresentable` wrapper, not on the `NSTextField` itself — AX clients read the
        // text field's own element, so that modifier alone never reaches VoiceOver (BL-05 Finding
        // 3). Setting it directly here makes the accessible name true at the layer that actually
        // serves it.
        field.setAccessibilityLabel("Duration in minutes")
        field.onScrollChange = { [weak coordinator = context.coordinator] value in
            coordinator?.commit(value)
        }
        context.coordinator.field = field
        return field
    }

    func updateNSView(_ nsView: ScrollableIntField, context: Context) {
        // Don't stomp the value while the user is typing in it.
        guard nsView.currentEditor() == nil else { return }
        let shown = nsView.stringValue.isEmpty ? nil : Int(nsView.stringValue)
        if shown != minutes {
            nsView.stringValue = minutes.map(String.init) ?? ""
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

        func clear() {
            field?.stringValue = ""
            parent.minutes = nil
        }

        /// Push the value to the binding on every keystroke — WITHOUT rewriting
        /// the field text mid-edit — so clicking Start (with no Enter first)
        /// uses the just-typed value instead of the previous one. The field
        /// text is only clamped/normalized on end-editing.
        func controlTextDidChange(_ obj: Notification) {
            guard let field else { return }
            if field.stringValue.isEmpty {
                parent.minutes = nil
                return
            }
            guard let value = Int(field.stringValue) else { return }
            parent.minutes = min(max(value, parent.range.lowerBound), parent.range.upperBound)
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            if field?.stringValue.isEmpty ?? true {
                clear()
                return
            }
            commit(field?.integerValue ?? parent.range.lowerBound)
        }
    }
}

/// `NSTextField` that steps its integer value on scroll (up = more).
final class ScrollableIntField: NSTextField {
    /// Up to 24h — the old 180-minute ceiling silently clamped anything longer
    /// with no feedback, so typing 1000 became 180.
    var range: ClosedRange<Int> = 1...1440
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
        NSSize(width: 34, height: super.intrinsicContentSize.height)
    }
}
