import SwiftUI
import MyIslandCore

/// The Claude detail droplet: every session as a row, sorted with the ones that need the user
/// first; a click jumps to that session's pane and confirms inline. Every other control stays in
/// the pane itself, never here.
/// Every session-supplied string (`repo`, `detail`) passes through `ClaudeSessions.displaySafe`
/// first (T-07-21) — this view never renders a raw session field.
@MainActor
struct ClaudePanelView: View {
    let sessions: [ClaudeSession]

    /// The session ID currently showing an inline jump confirmation, and its message
    /// ("Jumping…"/"Pane not found") — shared across every row so a click
    /// anywhere in this droplet confirms the same way.
    @State private var flashSessionID: String?
    @State private var flashMessage: String = ""
    @State private var flashTask: Task<Void, Never>?

    var body: some View {
        Group {
            if sessions.isEmpty {
                Text("No Claude Code sessions")
                    .font(Tokens.Font.bodyMD)
                    .foregroundStyle(Tokens.Color.textFaint)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                sessionList
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var sessionList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(sessions.enumerated()), id: \.element.id) { offset, session in
                    sessionRow(session, index: offset)
                }
            }
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .scrollIndicators(.visible)
        .scrollBounceBehavior(.basedOnSize)
    }

    private func sessionRow(_ session: ClaudeSession, index: Int) -> some View {
        Button {
            jump(to: session)
        } label: {
            HStack(spacing: Tokens.Spacing.sm) {
                Circle()
                    .fill(session.status.needsYou ? Tokens.Color.signal : Tokens.Color.textFaint)
                    .frame(width: 7, height: 7)
                Text(ClaudeSessions.displaySafe(session.repo))
                    .font(.system(size: 11.5, weight: .regular))
                    .foregroundStyle(Tokens.Color.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
                Text(flashSessionID == session.id ? flashMessage : rowStatusText(session))
                    .font(.system(size: 10, weight: .regular).monospaced())
                    .foregroundStyle(Tokens.Color.textFaint)
                    .lineLimit(1)
            }
            .padding(.horizontal, Tokens.Spacing.sm)
            .padding(.vertical, Tokens.Spacing.xs)
            .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.sm))
        }
        .buttonStyle(GlyphButtonStyle())
        .dropletFocusable(index: index, ring: .roundedRect(Tokens.Radius.sm)) { jump(to: session) }
    }

    private func rowStatusText(_ session: ClaudeSession) -> String {
        switch session.status {
        case .working: return "working"
        case .idle: return "idle \(ageMinutesText(since: session.updatedAt))"
        case .awaitingPermission: return "permission"
        case .waitingInput: return "your turn"
        }
    }

    /// Cancels any in-flight confirmation from a PREVIOUS click before starting a new one, so
    /// rapid re-clicks (on the same or a different session) never leave a stale flash showing.
    private func jump(to session: ClaudeSession) {
        flashTask?.cancel()
        flashSessionID = session.id
        flashMessage = "Jumping\u{2026}"
        flashTask = Task { @MainActor in
            let succeeded = await ClaudePaneJumper.jump(to: session)
            guard !Task.isCancelled else { return }
            if succeeded {
                flashSessionID = nil
                return
            }
            flashMessage = "Pane not found"
            try? await Task.sleep(for: .seconds(1.3))
            guard !Task.isCancelled else { return }
            flashSessionID = nil
        }
    }

    private func ageMinutesText(since date: Date) -> String {
        "\(max(0, Int(Date.now.timeIntervalSince(date) / 60)))m"
    }
}
