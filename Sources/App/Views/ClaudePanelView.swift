import SwiftUI
import MyIslandCore

/// The Claude detail droplet (07-DESIGN-AGREEMENT.md §4, sketch `DETAIL.claude`,
/// `.planning/sketches/006-design-round/index.html:671-680`): the top session's own request card
/// when it needs the user, then every other session as a row that jumps to its own pane on click.
/// Per the agreement's own closing section, this droplet only ever jumps to the pane and confirms
/// the action inline — every other control the user needs stays in the pane itself, never here.
/// Every session-supplied string (`repo`, `detail`) passes through `ClaudeSessions.displaySafe`
/// first (T-07-21) — this view never renders a raw session field.
@MainActor
struct ClaudePanelView: View {
    let sessions: [ClaudeSession]

    /// The session ID currently showing an inline jump confirmation, and its message
    /// ("Jumping…"/"Pane not found") — shared across the request card and every row so a click
    /// anywhere in this droplet confirms the same way.
    @State private var flashSessionID: String?
    @State private var flashMessage: String = ""
    @State private var flashTask: Task<Void, Never>?

    /// `sessions` is already `ClaudeSessions.sorted` (the provider's own contract) — the first
    /// entry is the one that most needs attention, or simply the newest if nothing does.
    private var featured: ClaudeSession? { sessions.first }
    private var featuredNeedsAttention: Bool { featured?.status.needsYou == true }

    /// Everyone except the featured request card — but when NOTHING needs attention, nothing was
    /// "used up" as a card, so every session (including the sorted-first one) appears as a row
    /// (sketch: the third row only appears when `D.claude !== 'needs'`).
    private var otherSessions: [ClaudeSession] {
        featuredNeedsAttention ? Array(sessions.dropFirst()) : sessions
    }

    var body: some View {
        Group {
            if sessions.isEmpty {
                Text("No Claude Code sessions")
                    .font(Tokens.Font.bodyMD)
                    .foregroundStyle(Tokens.Color.textFaint)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                VStack(alignment: .leading, spacing: Tokens.Spacing.sm) {
                    header
                    sessionList
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private var header: some View {
        if let featured, featuredNeedsAttention {
            requestCard(featured)
        } else {
            Text("\(sessions.count) SESSION\(sessions.count == 1 ? "" : "S") \u{00B7} NONE WAITING")
                .font(.system(size: 9, weight: .bold).monospaced())
                .tracking(0.4)
                .foregroundStyle(Tokens.Color.textFaint)
        }
    }

    private func requestCard(_ session: ClaudeSession) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
            HStack {
                HStack(spacing: 7) {
                    Circle()
                        .fill(Tokens.Color.signal)
                        .frame(width: 7, height: 7)
                    Text(ClaudeSessions.displaySafe(session.repo))
                        .font(.system(size: 12.5, weight: .bold))
                        .foregroundStyle(Tokens.Color.text)
                }
                Spacer()
                Text("iTerm2 \u{00B7} \(ageText(since: session.turnStartedAt ?? session.updatedAt))")
                    .font(.system(size: 10, weight: .regular).monospaced())
                    .foregroundStyle(Tokens.Color.textFaint)
                    .lineLimit(1)
            }

            if session.status == .awaitingPermission {
                Text("Wants to run")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(Tokens.Color.textMuted)
                Text(ClaudeSessions.displaySafe(session.detail ?? "\u{2014}"))
                    .font(.system(size: 11, weight: .regular).monospaced())
                    .foregroundStyle(Tokens.Color.text)
                    .lineLimit(2)
                    .truncationMode(.tail)
            } else {
                Text("Your turn")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(Tokens.Color.textMuted)
            }

            HStack {
                Button {
                    jump(to: session)
                } label: {
                    Text(flashSessionID == session.id ? flashMessage : "Jump to pane \u{2197}")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Tokens.Color.accent)
                        .lineLimit(1)
                }
                .buttonStyle(GlyphButtonStyle())
                .dropletFocusable(index: 0, ring: .roundedRect(6)) { jump(to: session) }

                Spacer()

                if flashSessionID != session.id {
                    Text("approve in the pane")
                        .font(.system(size: 10.5, weight: .regular))
                        .foregroundStyle(Tokens.Color.textMuted)
                }
            }
        }
        .padding(Tokens.Spacing.sm)
        .background(Tokens.Color.surfaceRaised)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var sessionList: some View {
        if !otherSessions.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    // 07-12 (PANEL-09): each row's own keyboard index continues right after the
                    // request card's index 0 when that card is showing (`featuredNeedsAttention`);
                    // otherwise the rows themselves start at 0 (no card "used up" an index).
                    ForEach(Array(otherSessions.enumerated()), id: \.element.id) { offset, session in
                        sessionRow(session, index: featuredNeedsAttention ? offset + 1 : offset)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .scrollIndicators(.visible)
            .scrollBounceBehavior(.basedOnSize)
        }
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
        case .awaitingPermission, .waitingInput: return "your turn"
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

    private func ageText(since date: Date) -> String {
        let minutes = max(0, Int(Date.now.timeIntervalSince(date) / 60))
        if minutes < 60 { return "\(minutes) min" }
        return "\(minutes / 60) h"
    }

    private func ageMinutesText(since date: Date) -> String {
        "\(max(0, Int(Date.now.timeIntervalSince(date) / 60)))m"
    }
}
