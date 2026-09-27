import SwiftUI
import MyIslandCore

/// The Clipboard detail droplet (07-DESIGN-AGREEMENT.md §4, sketch `DETAIL.clip`,
/// `.planning/sketches/006-design-round/index.html:681-689`): a typed, aged list of recent items,
/// newest first, each classified by `ClipboardKind` for its row icon — clicking a row re-copies it
/// (`ClipboardViewModel.select(_:)`) without re-recording itself. Styled entirely from `Tokens` —
/// never a hardcoded color/spacing/typography value.
@MainActor
struct ClipboardPanelView: View {
    let clipboard: ClipboardViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
            HStack {
                Text("CLIPBOARD \u{00B7} \(clipboard.entries.count) of 10")
                    .font(.system(size: 9, weight: .bold).monospaced())
                    .tracking(0.4)
                    .foregroundStyle(Tokens.Color.textFaint)

                Spacer()

                Text("click copies")
                    .font(.system(size: 10.5, weight: .regular))
                    .foregroundStyle(Tokens.Color.textMuted)
            }

            // Edge PANEL-02 empty: with no history, say so plainly — the band glyph is already
            // hidden for this case (`BandView.actionGlyph`).
            if clipboard.entries.isEmpty {
                Text("Nothing copied yet")
                    .font(Tokens.Font.bodyMD)
                    .foregroundStyle(Tokens.Color.textFaint)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        // Edge PANEL-02 ordering: `entries` is already newest-first
                        // (`ClipboardViewModel.pollIfChanged`/`select` both maintain that order).
                        ForEach(Array(clipboard.entries.enumerated()), id: \.element.id) { index, entry in
                            ClipboardRowView(entry: entry, index: index) {
                                clipboard.select(entry)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .top)
                }
                .frame(maxHeight: .infinity, alignment: .top)
                .scrollIndicators(.visible)
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

/// A single clipboard-history row: a `ClipboardKind`-derived type icon, the sanitised text on one
/// line (mono for command/color, regular otherwise), and a trailing age/hover/"Copied" label. For
/// DISPLAY ONLY (V5), the entry's text is truncated and control-character-stripped before
/// rendering so an adversarial clipboard payload cannot corrupt the panel layout — the
/// stored/re-copied string (`entry.text`) stays full/verbatim.
private struct ClipboardRowView: View {
    let entry: ClipboardViewModel.ClipboardEntry
    /// 07-12 (PANEL-09): this row's own keyboard index within the droplet's `DropletFocus`.
    let index: Int
    let onSelect: () -> Void

    @State private var isHovering = false
    @State private var justCopied = false
    // Cancels an in-flight "Copied" reset if the row is clicked again before the
    // previous flash has expired, so rapid re-copies don't clear early.
    @State private var flashResetTask: Task<Void, Never>?

    private var kind: ClipboardKind { ClipboardKind.classify(entry.text) }

    var body: some View {
        // A single click already re-copies the entry to the system clipboard
        // (there is no separate "copy" button) — the trailing label flips to
        // "Copied ✓" for ~1.4s so the action is unmistakable.
        Button(action: copy) {
            HStack(spacing: Tokens.Spacing.sm) {
                typeIcon

                Text(displayText)
                    .font(textFont)
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
                        .font(.system(size: 10, weight: .regular).monospaced())
                        .foregroundStyle(Tokens.Color.textFaint)
                }
            }
            .padding(.horizontal, Tokens.Spacing.sm)
            .padding(.vertical, Tokens.Spacing.xs)
            .background((isHovering || justCopied) ? Tokens.Color.surfaceRaised : SwiftUI.Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.sm))
        }
        .buttonStyle(GlyphButtonStyle())
        .onHover { isHovering = $0 }
        .dropletFocusable(index: index, ring: .roundedRect(Tokens.Radius.sm)) { copy() }
    }

    @ViewBuilder
    private var typeIcon: some View {
        switch kind {
        case .command:
            Image(systemName: "terminal")
                .font(.system(size: 11))
                .foregroundStyle(Tokens.Color.textMuted)
        case .color:
            if let color = ClipboardColorSwatch.parse(entry.text) {
                Circle()
                    .fill(color)
                    .frame(width: 12, height: 12)
            } else {
                Image(systemName: "paintpalette")
                    .font(.system(size: 11))
                    .foregroundStyle(Tokens.Color.textMuted)
            }
        case .link:
            Image(systemName: "link")
                .font(.system(size: 11))
                .foregroundStyle(Tokens.Color.textMuted)
        case .text:
            Image(systemName: "text.alignleft")
                .font(.system(size: 11))
                .foregroundStyle(Tokens.Color.textMuted)
        }
    }

    private var textFont: Font {
        switch kind {
        case .command, .color: return .system(size: 11, weight: .regular).monospaced()
        case .link, .text: return .system(size: 11.5, weight: .regular)
        }
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

/// Best-effort CSS-color-string → `SwiftUI.Color` parsing for the row's type-icon swatch (App
/// layer, display-only — Core's `ClipboardKind` only classifies, it never decodes a color value).
/// `nil` when the string doesn't parse; the row falls back to a generic palette glyph.
private enum ClipboardColorSwatch {
    static func parse(_ text: String) -> SwiftUI.Color? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("#") { return hex(trimmed) }
        let lowered = trimmed.lowercased()
        if lowered.hasPrefix("rgb") { return rgb(trimmed) }
        if lowered.hasPrefix("hsl") { return hsl(trimmed) }
        return nil
    }

    private static func hex(_ text: String) -> SwiftUI.Color? {
        var digits = text
        digits.removeFirst()
        switch digits.count {
        case 3, 4:
            digits = digits.map { String(repeating: $0, count: 2) }.joined()
        case 6, 8:
            break
        default:
            return nil
        }
        guard let value = UInt64(digits.prefix(6), radix: 16) else { return nil }
        return SwiftUI.Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    private static func rgb(_ text: String) -> SwiftUI.Color? {
        guard let open = text.firstIndex(of: "("), let close = text.firstIndex(of: ")"), open < close else { return nil }
        let parts = text[text.index(after: open)..<close]
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 3,
              let r = Double(parts[0]), let g = Double(parts[1]), let b = Double(parts[2]) else { return nil }
        return SwiftUI.Color(red: r / 255, green: g / 255, blue: b / 255)
    }

    /// Approximate — SwiftUI's `Color(hue:saturation:brightness:)` is HSB, not exactly HSL, but
    /// close enough for a 12pt swatch glyph.
    private static func hsl(_ text: String) -> SwiftUI.Color? {
        guard let open = text.firstIndex(of: "("), let close = text.firstIndex(of: ")"), open < close else { return nil }
        let cleaned = text[text.index(after: open)..<close].replacingOccurrences(of: ",", with: " ")
        let tokens = cleaned.split(separator: " ").map { $0.trimmingCharacters(in: .whitespaces) }
        guard tokens.count >= 3,
              let h = Double(tokens[0].replacingOccurrences(of: "deg", with: "")),
              let s = Double(tokens[1].replacingOccurrences(of: "%", with: "")),
              let l = Double(tokens[2].replacingOccurrences(of: "%", with: "")) else { return nil }
        return SwiftUI.Color(hue: h / 360, saturation: s / 100, brightness: l / 100)
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
