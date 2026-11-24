import AppKit
import SwiftUI

@main
enum Main {
    static func main() {
        // 除錯用：`Eject --scan` 在終端機印出掃描結果
        if CommandLine.arguments.contains("--scan") {
            MainActor.assumeIsolated { DebugCLI.run() }
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--eject-test"), i + 1 < CommandLine.arguments.count {
            let name = CommandLine.arguments[i + 1]
            Task { @MainActor in
                await EjectTest.run(name: name)
                exit(0)
            }
            dispatchMain()
        }
        // 純 AppKit 啟動，不使用 SwiftUI 的 App／Scene。
        // SwiftUI App 至少要有一個 scene，先前放的空 Settings 視窗會在顯示器重新配置
        // （例如多螢幕合併成一個）時被系統叫出來，變成一個空白的「Eject 設定」視窗。
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            let delegate = AppDelegate()
            app.delegate = delegate
            app.setActivationPolicy(.accessory)  // 只在選單列，不出現在 Dock
            withExtendedLifetime(delegate) { app.run() }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel?
    private var statusItem: StatusItemController?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // 這個 App 沒有需要恢復的視窗，關掉視窗狀態恢復
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    /// 在 Finder 再次打開 App 時，不要建立任何視窗。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { false }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = AppModel()
        self.model = model
        statusItem = StatusItemController(model: model)
        if CommandLine.arguments.contains("--idle-test") {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                statusItem?.runIdleTest(cycles: 5)
            }
        }
        if let i = CommandLine.arguments.firstIndex(of: "--anim-test"), i + 1 < CommandLine.arguments.count {
            let dir = CommandLine.arguments[i + 1]
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.5))
                statusItem?.runAnimationTest(dir: dir)
            }
        }
        if let i = CommandLine.arguments.firstIndex(of: "--panel-test"), i + 1 < CommandLine.arguments.count {
            let dir = CommandLine.arguments[i + 1]
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                statusItem?.runPanelTest(dir: dir, seconds: 14)
            }
        }
    }
}
