import AppKit
import Darwin
import Foundation
import OSLog
import MyIslandCore

/// CLAUDE-02 (pulled forward from v2, 07-14): reveals a waiting Claude Code session's exact
/// iTerm2 pane — the hardened, argv-only port of CCMetrics' former `SessionFocuser`
/// (07-14-PLAN's own `<interfaces>` recovery of commit 918689c). Never launches iTerm2 (a jump
/// only ever brings an ALREADY-RUNNING iTerm2 to the front — T-07-23: no Automation prompt at
/// launch, only on a user click); validates the session's own `pid` actually names a `claude`
/// process before trusting it at all (T-07-19: a forged state file can at worst point at another
/// of the user's own `claude` sessions, never an arbitrary process); resolves the pid's
/// controlling tty via `/bin/ps` (never any state-file field); and runs `/usr/bin/osascript` with
/// exactly `ClaudePaneJump.osascriptArguments(tty:)` — the AppleScript source is a fixed set of
/// compile-time constant lines, the tty is the only dynamic value and travels as `argv`
/// (T-07-18).
enum ClaudePaneJumper {
    private static let logger = AppLog.make("ClaudePaneJumper")
    private static let iTermBundleID = "com.googlecode.iterm2"

    /// Logged verbatim (`claudeJump result=<value>`) — never the session's own repo/cwd/detail
    /// (T-07-21: logs carry counts and result codes only).
    private enum JumpResult: String {
        case ok, noITerm, noTTY, notClaude, failed
    }

    /// Returns whether the jump succeeded (`osascript` exited 0). Runs entirely off the main
    /// actor — every step here is a subprocess launch or a synchronous libproc call, none of
    /// which should block the UI thread.
    @discardableResult
    static func jump(to session: ClaudeSession) async -> Bool {
        let result = await resolve(session)
        logger.notice("claudeJump result=\(result.rawValue, privacy: .public)")
        return result == .ok
    }

    private static func resolve(_ session: ClaudeSession) async -> JumpResult {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: iTermBundleID).isEmpty else {
            return .noITerm
        }
        guard let pid = session.pid, processName(of: pid) == "claude" else {
            return .notClaude
        }
        guard let psArguments = ClaudePaneJump.psArguments(pid: pid) else {
            return .notClaude
        }
        guard let psOutput = await run(executablePath: "/bin/ps", arguments: psArguments),
              let tty = ClaudePaneJump.validTTY(fromPSOutput: psOutput) else {
            return .noTTY
        }
        guard let scriptArguments = ClaudePaneJump.osascriptArguments(tty: tty) else {
            return .noTTY
        }
        let succeeded = await runVoid(executablePath: "/usr/bin/osascript", arguments: scriptArguments)
        return succeeded ? .ok : .failed
    }

    /// `proc_name` (libproc) rather than trusting the state file's own `model`/`repo` fields — the
    /// pid could have been recycled since the hook wrote it (T-07-19), so this is the one live,
    /// unforgeable fact checked before any subprocess is launched against that pid.
    private static func processName(of pid: Int32) -> String? {
        let bufferSize = 4 * 1024
        var buffer = [Int8](repeating: 0, count: bufferSize)
        let length = buffer.withUnsafeMutableBufferPointer { pointer -> Int32 in
            guard let base = pointer.baseAddress else { return 0 }
            return proc_name(pid, UnsafeMutableRawPointer(base), UInt32(bufferSize))
        }
        guard length > 0 else { return nil }
        let bytes = buffer[..<Int(length)].map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Runs a subprocess and returns its stdout as a string only on a clean exit — used for
    /// `/bin/ps`'s tty read.
    private static func run(executablePath: String, arguments: [String]) async -> String? {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { finished in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = finished.terminationStatus == 0 ? String(data: data, encoding: .utf8) : nil
                continuation.resume(returning: output)
            }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: nil)
            }
        }
    }

    /// Runs a subprocess with stdout/stderr discarded and returns only whether it exited 0 — used
    /// for the `/usr/bin/osascript` jump itself (no output is ever read back from it).
    private static func runVoid(executablePath: String, arguments: [String]) async -> Bool {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { finished in
                continuation.resume(returning: finished.terminationStatus == 0)
            }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: false)
            }
        }
    }
}
