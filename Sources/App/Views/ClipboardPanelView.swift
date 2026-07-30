import SwiftUI

/// Expanded-panel Clipboard group (CLIP-01, CLIP-02): a filtered, in-memory,
/// 10-entry recent-clipboard history. Selecting a row re-copies it to the
/// system clipboard without re-recording itself (see
/// `ClipboardViewModel.select(_:)`). Styled entirely from `Tokens` — never a
/// hardcoded color/spacing/typography value.
@MainActor
struct ClipboardPanelView: View {
    let clipboard: ClipboardViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
            HStack {
                Text("Clipboard")
                    .font(Tokens.Font.label)
                    .foregroundStyle(Tokens.Color.textMuted)

                Spacer()

                Text("\(clipboard.entries.count) recent")
                    .font(Tokens.Font.label)
                    .foregroundStyle(Tokens.Color.textFaint)
            }

            // Cockpit-3: the stage above sizes to its content, so the Clipboard
            // takes whatever vertical space remains (top-aligned) — the list
            // fills it and only scrolls once the up-to-10 history exceeds it,
            // never leaving a dead whitespace band under a compact stage.
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(clipboard.entries) { entry in
                        ClipboardRowView(entry: entry) {
                            clipboard.select(entry)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .scrollIndicators(.visible)
            .scrollBounceBehavior(.basedOnSize)

            Text("Text only \u{00B7} 10 max \u{00B7} in-memory \u{00B7} password-manager copies skipped")
                .font(Tokens.Font.label)
                .foregroundStyle(Tokens.Color.textFaint)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

/// A single clipboard-history row. For DISPLAY ONLY (V5), the entry's text is
/// truncated and control-character-stripped before rendering so an
/// adversarial clipboard payload cannot corrupt the panel layout — the
/// stored/re-copied string (`entry.text`) stays full/verbatim.
private struct ClipboardRowView: View {
    let entry: ClipboardViewModel.ClipboardEntry
    let onSelect: () -> Void

    @State private var isHovering = false
    @State private var justCopied = false
    // Cancels an in-flight "Copied" reset if the row is clicked again before the
    // previous flash has expired, so rapid re-copies don't clear early.
    @State private var flashResetTask: Task<Void, Never>?

    var body: some View {
        // A single click already re-copies the entry to the system clipboard
        // (there is no separate "copy" button) — the trailing label flips to
        // "Copied ✓" for ~1.4s so the action is unmistakable.
        Button(action: copy) {
            HStack(spacing: Tokens.Spacing.sm) {
                Text(displayText)
                    .font(Tokens.Font.data)
                    .foregroundStyle(Tokens.Color.text)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer()

                if justCopied {
                    Text("Copied \u{2713}")
                        .font(Tokens.Font.label)
                        .foregroundStyle(Tokens.Color.accentCool)
                } else if isHovering {
                    Text("click to copy")
                        .font(Tokens.Font.label)
                        .foregroundStyle(Tokens.Color.accent)
                } else {
                    Text(ageLabel)
                        .font(Tokens.Font.label)
                        .foregroundStyle(Tokens.Color.textFaint)
                }
            }
            .padding(.horizontal, Tokens.Spacing.sm)
            .padding(.vertical, Tokens.Spacing.xs)
            .background((isHovering || justCopied) ? Tokens.Color.surfaceRaised : SwiftUI.Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.sm))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }

    private func copy() {
        onSelect()
        justCopied = true
        flashResetTask?.cancel()
        flashResetTask = Task {
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            guard !Task.isCancelled else { return }
            justCopied = false
        }
    }

    /// Truncated to ~200 characters with control/non-printable characters
    /// stripped (V5) — display-only; the stored/re-copied string is
    /// untouched.
    private var displayText: String {
        let stripped = String(entry.text.unicodeScalars.filter { scalar in
            !scalar.properties.generalCategory.isControlLike
        })
        if stripped.count > 200 {
            return String(stripped.prefix(200)) + "\u{2026}"
        }
        return stripped
    }

    private var ageLabel: String {
        let seconds = max(0, Int(Date.now.timeIntervalSince(entry.copiedAt)))
        if seconds < 60 { return "now" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        return "\(hours)h"
    }
}

private extension Unicode.GeneralCategory {
    /// Control, format, and unassigned/surrogate categories — the classes of
    /// non-printable characters that could corrupt a single-line panel row.
    var isControlLike: Bool {
        switch self {
        case .control, .format, .surrogate, .unassigned, .lineSeparator, .paragraphSeparator:
            return true
        default:
            return false
        }
    }
}
