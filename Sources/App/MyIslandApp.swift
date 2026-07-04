import SwiftUI
import OSLog
import MyIslandCore

@main
struct MyIslandApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        Logger(subsystem: AppIdentity.bundleID, category: "launch").info("my-island launching")
    }

    var body: some Scene {
        Settings { EmptyView() }
    }
}
