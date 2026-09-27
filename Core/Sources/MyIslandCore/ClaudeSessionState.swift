import Foundation

// RED-phase stub (07-14 Task 1): signatures final, bodies intentionally wrong, so the failing
// test run is a genuine assertion failure, never a compile error — same convention as
// 07-07/07-09's own RED commits.

public enum ClaudeSessionStatus: String, Sendable, Equatable {
    case awaitingPermission = "awaiting_permission"
    case waitingInput = "waiting_input"
    case working
    case idle

    public var priority: Int { 0 }
    public var needsYou: Bool { false }
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

public enum ClaudeSessionDecoder {
    public static let maxBytes = 65_536
    public static let staleAfter: TimeInterval = 3600

    public static func decode(data: Data, fileName: String, now: Date) -> ClaudeSession? {
        nil
    }
}

public enum ClaudeSessions {
    public static func sorted(_ sessions: [ClaudeSession]) -> [ClaudeSession] {
        sessions
    }

    public static func waitingCount(_ sessions: [ClaudeSession]) -> Int {
        0
    }

    public static func displaySafe(_ text: String) -> String {
        text
    }
}

public enum ClaudePaneJump {
    public static func validTTY(fromPSOutput raw: String) -> String? {
        nil
    }

    public static func psArguments(pid: Int32) -> [String]? {
        nil
    }

    public static func osascriptArguments(tty: String) -> [String]? {
        nil
    }
}
