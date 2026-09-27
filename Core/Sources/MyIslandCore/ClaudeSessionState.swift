import Foundation

/// CLAUDE-01/02/03 (pulled forward from v2, 07-14): decodes, sanitises and orders the Claude Code
/// statusbar hook's per-session state files (`~/.claude/statusbar/state.d/<session_id>.json`,
/// written by `session-state.sh`, read-only here — see `ClaudeSessionsProvider` for the directory
/// walk). Also builds the argument arrays for the pane-jump subprocesses (`/bin/ps`,
/// `/usr/bin/osascript`) — the only place any session-supplied value is allowed to influence a
/// process launch, and it never becomes AppleScript source text (T-07-18).
public enum ClaudeSessionStatus: String, Sendable, Equatable {
    case awaitingPermission = "awaiting_permission"
    case waitingInput = "waiting_input"
    case working
    case idle

    /// Any string the writer didn't emit (a future status value, or a typo) degrades to
    /// `.working` — a session is presumed still going rather than silently read as done or
    /// needing attention it doesn't.
    public init(decoding raw: String) {
        self = ClaudeSessionStatus(rawValue: raw) ?? .working
    }

    /// Sort priority (07-DESIGN-AGREEMENT.md §4 ordering): 0 = awaiting permission (shown first)
    /// through 3 = idle (shown last).
    public var priority: Int {
        switch self {
        case .awaitingPermission: return 0
        case .waitingInput: return 1
        case .working: return 2
        case .idle: return 3
        }
    }

    /// True for the two statuses the band's amber badge/glyph react to.
    public var needsYou: Bool {
        self == .awaitingPermission || self == .waitingInput
    }
}

public struct ClaudeSession: Sendable, Identifiable, Equatable {
    public let id: String
    public let repo: String
    public let cwd: String
    public let model: String
    public let status: ClaudeSessionStatus
    public let detail: String?
    public let turnStartedAt: Date?
    public let updatedAt: Date
    public let pid: Int32?

    public init(id: String, repo: String, cwd: String, model: String, status: ClaudeSessionStatus, detail: String?, turnStartedAt: Date?, updatedAt: Date, pid: Int32?) {
        self.id = id
        self.repo = repo
        self.cwd = cwd
        self.model = model
        self.status = status
        self.detail = detail
        self.turnStartedAt = turnStartedAt
        self.updatedAt = updatedAt
        self.pid = pid
    }
}

/// Untrusted-input boundary (T-07-20/T-07-19): every field below is attacker-writable (state.d is
/// world-writable to the user), so decoding never throws past this type and every field has a safe
/// fallback rather than a crash or a force-unwrap.
public enum ClaudeSessionDecoder {
    /// T-07-20: a regular session record is a few hundred bytes; 64 KB is generous headroom
    /// without letting an oversized/forged file grow unboundedly before rejection.
    public static let maxBytes = 65_536
    /// A session file older than this is either stale (the writer crashed before cleanup) or the
    /// process is long gone — dropped from the list rather than shown as a phantom session.
    public static let staleAfter: TimeInterval = 3600

    private struct RawRecord: Decodable {
        let session_id: String?
        let repo: String?
        let cwd: String?
        let model: String?
        let status: String?
        let detail: String?
        let turn_started_at: Double?
        let pid: Int32?
        let updated_at: Double?
    }

    /// `fileName` is the state.d file's own name (used only as the `session_id` fallback);
    /// `now` is injected (not `Date()`) so staleness is deterministic under test.
    public static func decode(data: Data, fileName: String, now: Date) -> ClaudeSession? {
        guard data.count <= maxBytes else { return nil }
        guard let raw = try? JSONDecoder().decode(RawRecord.self, from: data) else { return nil }
        guard let updatedAtEpoch = raw.updated_at else { return nil }
        let updatedAt = Date(timeIntervalSince1970: updatedAtEpoch)
        guard now.timeIntervalSince(updatedAt) <= staleAfter else { return nil }

        let id: String
        if let sessionID = raw.session_id, !sessionID.isEmpty {
            id = sessionID
        } else {
            id = (fileName as NSString).deletingPathExtension
        }

        let repo: String
        if let declaredRepo = raw.repo, !declaredRepo.isEmpty {
            repo = declaredRepo
        } else if let cwd = raw.cwd, !cwd.isEmpty {
            repo = (cwd as NSString).lastPathComponent
        } else {
            repo = "\u{2014}"
        }

        return ClaudeSession(
            id: id,
            repo: repo,
            cwd: raw.cwd ?? "",
            model: raw.model ?? "",
            status: ClaudeSessionStatus(decoding: raw.status ?? ""),
            detail: raw.detail,
            turnStartedAt: raw.turn_started_at.map { Date(timeIntervalSince1970: $0) },
            updatedAt: updatedAt,
            pid: raw.pid
        )
    }
}

public enum ClaudeSessions {
    /// 07-DESIGN-AGREEMENT.md §4 ordering: awaiting permission, waiting for input, working, idle;
    /// ties break by `turnStartedAt` (else `updatedAt`), oldest first — the longest-waiting session
    /// surfaces first.
    public static func sorted(_ sessions: [ClaudeSession]) -> [ClaudeSession] {
        sessions.sorted { lhs, rhs in
            if lhs.status.priority != rhs.status.priority {
                return lhs.status.priority < rhs.status.priority
            }
            let lhsTime = lhs.turnStartedAt ?? lhs.updatedAt
            let rhsTime = rhs.turnStartedAt ?? rhs.updatedAt
            return lhsTime < rhsTime
        }
    }

    /// The band cell's badge count — awaiting-permission and waiting-input only (`needsYou`).
    public static func waitingCount(_ sessions: [ClaudeSession]) -> Int {
        sessions.reduce(0) { $0 + ($1.status.needsYou ? 1 : 0) }
    }

    /// T-07-21 / V5: every session-supplied string shown anywhere in the UI passes through here
    /// first — control characters and newlines collapse to a single space (runs never produce
    /// multiple spaces in a row), and the result is capped at 200 characters so a hostile `detail`
    /// field can't corrupt panel layout.
    public static func displaySafe(_ text: String) -> String {
        var collapsed = ""
        var lastWasSpace = false
        for scalar in text.unicodeScalars {
            let isControlLike = scalar.properties.generalCategory == .control
            if isControlLike || scalar == " " {
                if !lastWasSpace {
                    collapsed.unicodeScalars.append(" ")
                }
                lastWasSpace = true
            } else {
                collapsed.unicodeScalars.append(scalar)
                lastWasSpace = false
            }
        }
        if collapsed.count > 200 {
            collapsed = String(collapsed.prefix(200))
        }
        return collapsed
    }
}

/// T-07-18 (the plan's own hardened `SessionFocuser` port): every process argument built here is
/// either a compile-time constant AppleScript line or a value that has passed `validTTY`'s
/// allow-list — no session-supplied string (repo, cwd, detail, session id, model) ever reaches
/// this type.
public enum ClaudePaneJump {
    /// Accepts `ttysNNN` or `/dev/ttysNNN` (1-4 digits, matching `/bin/ps -o tty=`'s own output
    /// shape), trimmed of surrounding whitespace/newlines; anything else — `??`, empty, a shell
    /// metacharacter tail, `console`, more than 4 digits — is rejected. Returns the normalized
    /// `/dev/ttysNNN` form, never the raw input.
    public static func validTTY(fromPSOutput raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutPrefix = trimmed.hasPrefix("/dev/") ? String(trimmed.dropFirst(5)) : trimmed
        guard withoutPrefix.hasPrefix("ttys") else { return nil }
        let digits = withoutPrefix.dropFirst(4)
        guard !digits.isEmpty, digits.count <= 4, digits.allSatisfy(\.isNumber) else { return nil }
        return "/dev/" + withoutPrefix
    }

    /// `/bin/ps -o tty= -p <pid>` — `pid` must be a real, non-init process (>1); the forged-pid
    /// case (T-07-19) is caught downstream by `ClaudePaneJumper`'s own `proc_name(pid) == "claude"`
    /// check, not here.
    public static func psArguments(pid: Int32) -> [String]? {
        guard pid > 1 else { return nil }
        return ["-o", "tty=", "-p", String(pid)]
    }

    /// Every `-e` line below is a compile-time string literal — no interpolation of any kind. The
    /// tty is the ONLY dynamic value, validated by `validTTY` and appended as the script's own
    /// `argv` (read inside the script via `item 1 of argv`), never spliced into the script text
    /// itself. Ports the recovered CCMetrics `SessionFocuser` walk (windows → tabs → sessions,
    /// matching `tty of s`), with the session `select` in its own `try` (a session can vanish
    /// between enumeration and select).
    public static func osascriptArguments(tty: String) -> [String]? {
        guard let validatedTTY = validTTY(fromPSOutput: tty) else { return nil }
        return [
            "-e", "on run argv",
            "-e", "set targetTTY to item 1 of argv",
            "-e", "tell application \"iTerm\"",
            "-e", "repeat with w in windows",
            "-e", "repeat with t in tabs of w",
            "-e", "repeat with s in sessions of t",
            "-e", "if tty of s is targetTTY then",
            "-e", "tell w to select",
            "-e", "tell t to select",
            "-e", "try",
            "-e", "tell s to select",
            "-e", "end try",
            "-e", "activate",
            "-e", "end if",
            "-e", "end repeat",
            "-e", "end repeat",
            "-e", "end repeat",
            "-e", "end run",
            validatedTTY,
        ]
    }
}
