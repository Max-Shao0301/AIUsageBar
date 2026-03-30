import SwiftUI

@main
struct AIUsageBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // 不需要主視窗，只有 Menu Bar
        Settings { EmptyView() }
    }
}
