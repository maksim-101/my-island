import AppKit
import Observation

/// HUD-05: read-only view of whether FineTune is running. It never quits, hides, activates or
/// signals FineTune — `scripts/assert-hud-ownership.sh` fails if that changes (T-08-14).
@MainActor
@Observable
final class FineTuneMonitor {
    static let bundleID = "com.finetuneapp.FineTune"

    private(set) var isRunning: Bool
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private var launchObserver: NSObjectProtocol?
    @ObservationIgnored private var terminateObserver: NSObjectProtocol?

    init() {
        isRunning = Self.scan()
        let center = NSWorkspace.shared.notificationCenter
        launchObserver = center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.rescan() }
        }
        terminateObserver = center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.rescan() }
        }
    }

    func rescan() {
        let running = Self.scan()
        guard running != isRunning else { return }
        isRunning = running
        onChange?()
    }

    private static func scan() -> Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).contains { !$0.isTerminated }
    }
}
