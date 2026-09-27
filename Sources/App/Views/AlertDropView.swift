import SwiftUI
import AppKit
import MyIslandCore

/// One drop type for the volume/brightness HUD and the meeting alert (07-DESIGN-AGREEMENT.md §6,
/// FLUID-02/PANEL-07): a pebble that swells out of whatever the collapsed surface currently shows
/// (MacBook pill, Dell pill or fullscreen bulge), hangs by a neck that narrows to an hourglass,
/// pinches off at 7pt and settles 8pt below. `motion` supplies every geometry channel (`params`,
/// `channels[.dropOffset/.dropHeight/.dropHalfWidth/.dropAlpha]`) plus the attachment hysteresis
/// (`dropDetached`) kept ON `FluidMotion` itself — not this transient struct — so it survives being
/// torn down and recreated on every SwiftUI re-render. `kind` only ever decides the CONTENT drawn
/// inside the drop, never the shape math both kinds share.
struct AlertDropView: View {
    enum Kind {
        case level(glyph: HUDGlyph, level: Double)
        /// `onJoin` fires only when the label is actually tapped (never on a link-less meeting,
        /// which never draws a Join button in the first place) — 07-05 Task 3's "leaves 0.5s
        /// later" behavior lives in whoever supplies this closure (`HUDViewModel.endSoon`).
        case meeting(title: String, lead: String, joinURL: URL?, onJoin: () -> Void)
    }

    let motion: FluidMotion
    let kind: Kind
    let isPhysical: Bool

    var body: some View {
        GeometryReader { proxy in
            let cx = proxy.size.width / 2
            let q = motion.params
            // Ported from index.html:547 `floorY(cx, Q, cx)` — the floor's own height at the
            // shape's center, in this view's local top-down coordinate space.
            let baseY = FluidShapeGeometry.floorY(x: cx, q: q, cx: cx)
            let dropOffset = motion.channels[.dropOffset] ?? 0
            let dropHeight = max(0, motion.channels[.dropHeight] ?? 0)
            let dropHalfWidth = max(0, motion.channels[.dropHalfWidth] ?? 0)
            let dropAlpha = max(0, min(1, motion.channels[.dropAlpha] ?? 0))
            let yT = baseY + dropOffset
            // `g = yT - baseY` in the sketch — `baseY` cancels, so `g` is just `dropOffset`.
            let g = dropOffset
            let dropVisible = yT + dropHeight > baseY + 0.5 && dropHalfWidth > 1

            if dropVisible {
                let pebblePath = Path(FluidShapeGeometry.pebble(w: dropHalfWidth, y: yT, h: dropHeight, ox: cx))
                ZStack {
                    pebblePath
                        .fill(Tokens.Color.accent)
                        .opacity(0.22)
                        .blur(radius: 4)
                    pebblePath
                        .fill(Color.black)
                    pebblePath
                        .stroke(Tokens.Color.accent.opacity(0.34), lineWidth: 0.9)

                    // The neck hides the seam between the floor and the falling drop — shown
                    // only while still attached (index.html:554-555): `na`/`waist` port verbatim.
                    if !motion.dropDetached, g > -1.5 {
                        let na = min(dropHalfWidth * 0.6, 60)
                        let t = max(0, min(1, g / 7))
                        let waist = na * pow(1 - t, 1.4)
                        if waist > 0.8 {
                            Path(FluidShapeGeometry.neck(a: na, y0: baseY, y1: yT, waist: waist))
                                .offsetBy(dx: cx, dy: 0)
                                .fill(Color.black)
                        }
                    }

                    // Content fades in only after separation (index.html:587's
                    // `clamp((g-4)/4)`), never before — resting eyes see the drop swell and pinch
                    // off before anything inside it becomes legible.
                    content
                        .frame(width: max(1, dropHalfWidth * 2 - Tokens.Spacing.sm), height: max(1, dropHeight))
                        .position(x: cx, y: yT + dropHeight / 2)
                        .opacity(dropAlpha * max(0, min(1, (g - 4) / 4)))
                }
            }
        }
        .allowsHitTesting(kindHasClickTarget)
    }

    /// Only a linked meeting drop (Join) ever wants clicks — the level HUD and a link-less
    /// meeting drop stay fully click-through even where this view happens to be hosted.
    private var kindHasClickTarget: Bool {
        if case .meeting(_, _, let joinURL, _) = kind { return joinURL != nil }
        return false
    }

    @ViewBuilder
    private var content: some View {
        switch kind {
        case .level(let glyph, let level):
            levelContent(glyph: glyph, level: level)
        case .meeting(let title, let lead, let joinURL, let onJoin):
            meetingContent(title: title, lead: lead, joinURL: joinURL, onJoin: onJoin)
        }
    }

    /// The volume/brightness glyph + a neutral (never amber, D-06) level bar whose fill animates
    /// on level change (FEEL-02) — ported in spirit from the retired `HUDPillView.pill`.
    private func levelContent(glyph: HUDGlyph, level: Double) -> some View {
        HStack(spacing: Tokens.Spacing.sm) {
            Image(systemName: glyph.systemName)
                .font(Tokens.Font.data)
                .foregroundStyle(Tokens.Color.text)
            Capsule()
                .fill(Tokens.Color.hairline)
                .frame(width: 44, height: 4)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(Tokens.Color.text)
                        .frame(width: 44 * max(0, min(1, level)))
                        .animation(.easeOut(duration: 0.18), value: level)
                }
        }
    }

    /// The meeting alert: a video glyph, the lead ("60m"/"15m"/"now") in bold, the title in
    /// `textMuted`, wrapping to a second line once `AlertDropLayout.meeting` says so — never
    /// scrolling or marquee (agreement §6) — then Join only when a link exists (PANEL-07 empty).
    private func meetingContent(title: String, lead: String, joinURL: URL?, onJoin: @escaping () -> Void) -> some View {
        let sized = Self.measuredMeetingSize(title: title, lead: lead, hasJoin: joinURL != nil, isPhysical: isPhysical)
        return HStack(alignment: .top, spacing: Tokens.Spacing.sm) {
            Image(systemName: "video.fill")
                .font(.system(size: 13))
                .foregroundStyle(Tokens.Color.text)
            leadTitleText(lead: lead, title: title)
                .lineLimit(sized.twoLines ? 2 : 1)
                .truncationMode(.tail)
            if let joinURL {
                Button {
                    NSWorkspace.shared.open(joinURL)
                    onJoin()
                } label: {
                    Text("Join")
                        .font(Tokens.Font.buttonPrimary)
                        .foregroundStyle(Tokens.Color.accentInk)
                        .padding(.horizontal, Tokens.Spacing.md)
                        .padding(.vertical, Tokens.Spacing.xs)
                        .background(Tokens.Color.accent)
                        .clipShape(Capsule())
                }
                .buttonStyle(GlyphButtonStyle())
            }
        }
    }

    /// Combines the bold lead and the muted title into one `Text` via interpolation (SwiftUI's
    /// replacement for the deprecated `Text + Text` concatenation operator), so `lineLimit`/
    /// `truncationMode` above apply across both pieces as a single wrapping unit.
    private func leadTitleText(lead: String, title: String) -> Text {
        let leadText = Text(lead + " ").font(.system(size: 11, weight: .bold)).foregroundStyle(Tokens.Color.text)
        let titleText = Text(title).font(.system(size: 11, weight: .regular)).foregroundStyle(Tokens.Color.textMuted)
        return Text("\(leadText)\(titleText)")
    }

    /// The meeting drop's size, measured in REAL rendered points (PANEL-07 encoding edge) via
    /// `NSAttributedString` at the system font, 11pt — never character counts. Shared by this
    /// view's own content layout and `NotchPanelController`'s channel/frame driving, so the two
    /// can never disagree about how wide a given title measures.
    static func measuredMeetingSize(title: String, lead: String, hasJoin: Bool, isPhysical: Bool) -> (halfWidth: CGFloat, height: CGFloat, twoLines: Bool) {
        let leadWidth = NSAttributedString(string: lead + " ", attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .bold)]).size().width
        let titleWidth = NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .regular)]).size().width
        return AlertDropLayout.meeting(leadWidth: leadWidth, titleWidth: titleWidth, hasJoin: hasJoin, isPhysical: isPhysical)
    }
}
