import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusBarController: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 不顯示在 Dock 與 Cmd+Tab（純 Menu Bar App）
        NSApp.setActivationPolicy(.accessory)

        // 啟動 Status Bar
        statusBarController = StatusBarController()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false  // 關閉視窗不結束 App
    }
}
