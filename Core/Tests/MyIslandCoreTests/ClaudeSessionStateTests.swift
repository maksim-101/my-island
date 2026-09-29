import Foundation
import Testing
@testable import MyIslandCore

/// 07-14-PLAN's `<behavior>` list, one test per literal example — RED phase, written against the
/// plan's own spec before `ClaudeSessionState.swift` exists. Wrapped in a `@Suite` so
/// `swift test --filter ClaudeSessionStateTests` (the plan's own `<verify>` command) can find them
/// by suite name — a free `@Test func` has no "ClaudeSessionStateTests" in its test ID
/// (`ClipboardKindTests.swift` established this convention in 07-09).
@Suite struct ClaudeSessionStateTests {
    private static let epoch1700000000 = Date(timeIntervalSince1970: 1_700_000_000)
    private static let epoch1700000100 = Date(timeIntervalSince1970: 1_700_000_100)

    private func data(_ json: String) -> Data {
        Data(json.utf8)
    }

    // MARK: - decode

    @Test func decodesFullRecord() {
        let json = """
        {
          "session_id": "abc123",
          "repo": "my-island",
          "cwd": "/Users/mo/code/my-island",
          "model": "claude-3.7",
          "status": "awaiting_permission",
          "detail": "Bash",
          "turn_started_at": 1700000000,
          "pid": 4242,
          "updated_at": 1700000100
        }
        """
        let session = ClaudeSessionDecoder.decode(data: data(json), fileName: "abc123.json", now: Self.epoch1700000100)
        #expect(session?.id == "abc123")
        #expect(session?.repo == "my-island")
        #expect(session?.cwd == "/Users/mo/code/my-island")
        #expect(session?.model == "claude-3.7")
        #expect(session?.status == .awaitingPermission)
        #expect(session?.detail == "Bash")
        #expect(session?.turnStartedAt == Self.epoch1700000000)
        #expect(session?.pid == 4242)
        #expect(session?.updatedAt == Self.epoch1700000100)
    }

    @Test func toleratesNullDetailAndTurnStartedAt() {
        let json = """
        {"session_id":"s1","repo":"r","cwd":"/x/r","status":"working","detail":null,"turn_started_at":null,"pid":10,"updated_at":1700000100}
        """
        let session = ClaudeSessionDecoder.decode(data: data(json), fileName: "s1.json", now: Self.epoch1700000100)
        #expect(session?.detail == nil)
        #expect(session?.turnStartedAt == nil)
    }

    @Test func missingRepoFallsBackToLastPathComponentOfCwd() {
        let json = """
        {"session_id":"s1","cwd":"/Users/mo/code/my-island","status":"working","updated_at":1700000100}
        """
        let session = ClaudeSessionDecoder.decode(data: data(json), fileName: "s1.json", now: Self.epoch1700000100)
        #expect(session?.repo == "my-island")
    }

    @Test func missingRepoAndCwdFallsBackToDash() {
        let json = """
        {"session_id":"s1","status":"working","updated_at":1700000100}
        """
        let session = ClaudeSessionDecoder.decode(data: data(json), fileName: "s1.json", now: Self.epoch1700000100)
        #expect(session?.repo == "\u{2014}")
    }

    @Test func missingSessionIdFallsBackToFileNameWithoutExtension() {
        let json = """
        {"repo":"r","status":"working","updated_at":1700000100}
        """
        let session = ClaudeSessionDecoder.decode(data: data(json), fileName: "a1b2c3.json", now: Self.epoch1700000100)
        #expect(session?.id == "a1b2c3")
    }

    @Test func unknownStatusIsWorking() {
        let json = """
        {"session_id":"s1","repo":"r","status":"compacting","updated_at":1700000100}
        """
        let session = ClaudeSessionDecoder.decode(data: data(json), fileName: "s1.json", now: Self.epoch1700000100)
        #expect(session?.status == .working)
    }

    @Test func missingUpdatedAtSkipsRecord() {
        let json = """
        {"session_id":"s1","repo":"r","status":"working"}
        """
        let session = ClaudeSessionDecoder.decode(data: data(json), fileName: "s1.json", now: Self.epoch1700000100)
        #expect(session == nil)
    }

    @Test func staleOverOneHourIsHidden() {
        let json = """
        {"session_id":"s1","repo":"r","status":"working","updated_at":1700000000}
        """
        let now = Date(timeIntervalSince1970: 1_700_000_000 + 3601)
        let session = ClaudeSessionDecoder.decode(data: data(json), fileName: "s1.json", now: now)
        #expect(session == nil)
    }

    @Test func staleExactlyOneHourIsKept() {
        let json = """
        {"session_id":"s1","repo":"r","status":"working","updated_at":1700000000}
        """
        let now = Date(timeIntervalSince1970: 1_700_000_000 + 3600)
        let session = ClaudeSessionDecoder.decode(data: data(json), fileName: "s1.json", now: now)
        #expect(session != nil)
    }

    @Test func oversizedDataIsRejected() {
        let big = Data(repeating: 0x41, count: ClaudeSessionDecoder.maxBytes + 1)
        let session = ClaudeSessionDecoder.decode(data: big, fileName: "s1.json", now: .now)
        #expect(session == nil)
    }

    // MARK: - sort / waitingCount / displaySafe

    private func session(id: String, status: ClaudeSessionStatus, turnStartedAt: Date? = nil, updatedAt: Date = .now) -> ClaudeSession {
        ClaudeSession(id: id, repo: id, cwd: "/x/\(id)", model: "m", status: status, detail: nil, turnStartedAt: turnStartedAt, updatedAt: updatedAt, pid: nil)
    }

    @Test func sortOrderByStatusPriority() {
        let sessions = [
            session(id: "idle", status: .idle),
            session(id: "working", status: .working),
            session(id: "waitingInput", status: .waitingInput),
            session(id: "awaitingPermission", status: .awaitingPermission),
        ]
        let sorted = ClaudeSessions.sorted(sessions).map(\.id)
        #expect(sorted == ["awaitingPermission", "waitingInput", "working", "idle"])
    }

    @Test func sortOrderTiesBreakByTurnStartedAtOldestFirst() {
        let older = session(id: "older", status: .awaitingPermission, turnStartedAt: Self.epoch1700000000)
        let newer = session(id: "newer", status: .awaitingPermission, turnStartedAt: Self.epoch1700000100)
        let sorted = ClaudeSessions.sorted([newer, older]).map(\.id)
        #expect(sorted == ["older", "newer"])
    }

    @Test func sortOrderTiesFallBackToUpdatedAtWhenNoTurnStartedAt() {
        let older = session(id: "older", status: .awaitingPermission, updatedAt: Self.epoch1700000000)
        let newer = session(id: "newer", status: .awaitingPermission, updatedAt: Self.epoch1700000100)
        let sorted = ClaudeSessions.sorted([newer, older]).map(\.id)
        #expect(sorted == ["older", "newer"])
    }

    @Test func waitingCountCountsOnlyAwaitingPermissionAndWaitingInput() {
        let sessions = [
            session(id: "a", status: .awaitingPermission),
            session(id: "b", status: .waitingInput),
            session(id: "c", status: .working),
            session(id: "d", status: .idle),
        ]
        #expect(ClaudeSessions.waitingCount(sessions) == 2)
    }

    @Test func displaySafeReplacesControlCharactersAndCollapsesRuns() {
        let result = ClaudeSessions.displaySafe("hello\n\n\tworld  \r\nfoo")
        #expect(result == "hello world foo")
    }

    @Test func displaySafeCapsAt200Characters() {
        let result = ClaudeSessions.displaySafe(String(repeating: "x", count: 500))
        #expect(result.count == 200)
    }

    // MARK: - ClaudePaneJump

    @Test func validTTYAcceptsBareForm() {
        #expect(ClaudePaneJump.validTTY(fromPSOutput: "ttys003\n") == "/dev/ttys003")
    }

    @Test func validTTYAcceptsDevPrefixedForm() {
        #expect(ClaudePaneJump.validTTY(fromPSOutput: "/dev/ttys012") == "/dev/ttys012")
    }

    @Test func validTTYRejectsDoubleQuestionMark() {
        #expect(ClaudePaneJump.validTTY(fromPSOutput: "??") == nil)
    }

    @Test func validTTYRejectsEmptyString() {
        #expect(ClaudePaneJump.validTTY(fromPSOutput: "") == nil)
    }

    @Test func validTTYRejectsInjectionAttempt() {
        #expect(ClaudePaneJump.validTTY(fromPSOutput: "ttys003; do shell script") == nil)
    }

    @Test func validTTYRejectsConsole() {
        #expect(ClaudePaneJump.validTTY(fromPSOutput: "console") == nil)
    }

    @Test func validTTYRejectsTooManyDigits() {
        #expect(ClaudePaneJump.validTTY(fromPSOutput: "ttys12345") == nil)
    }

    @Test func psArgumentsForValidPid() {
        #expect(ClaudePaneJump.psArguments(pid: 4242) == ["-o", "tty=", "-p", "4242"])
    }

    @Test func psArgumentsRejectsPid1() {
        #expect(ClaudePaneJump.psArguments(pid: 1) == nil)
    }

    @Test func psArgumentsRejectsPid0() {
        #expect(ClaudePaneJump.psArguments(pid: 0) == nil)
    }

    @Test func psArgumentsRejectsNegativePid() {
        #expect(ClaudePaneJump.psArguments(pid: -5) == nil)
    }

    @Test func osascriptArgumentsEndsWithTheTTYOnly() {
        guard let args = ClaudePaneJump.osascriptArguments(tty: "/dev/ttys003") else {
            Issue.record("expected non-nil arguments")
            return
        }
        #expect(args.last == "/dev/ttys003")
        let earlier = args.dropLast()
        #expect(earlier.allSatisfy { !$0.contains("ttys003") })
    }

    @Test func osascriptArgumentsRejectsInvalidTTY() {
        #expect(ClaudePaneJump.osascriptArguments(tty: "??") == nil)
    }

    @Test func claudeProcessNameAcceptsBinaryNameAndVersionForm() {
        #expect(ClaudePaneJump.isClaudeProcessName("claude"))
        #expect(ClaudePaneJump.isClaudeProcessName("2.1.284"))
        #expect(!ClaudePaneJump.isClaudeProcessName("zsh"))
        #expect(!ClaudePaneJump.isClaudeProcessName("2.1"))
        #expect(!ClaudePaneJump.isClaudeProcessName("2.1.x"))
    }
}
