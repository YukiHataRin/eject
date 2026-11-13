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
        EjectApp.main()
    }
}

struct EjectApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // 選單列圖示與面板由 StatusItemController 自己管理，這裡不需要任何視窗
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel?
    private var statusItem: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = AppModel()
        self.model = model
        statusItem = StatusItemController(model: model)
        if let i = CommandLine.arguments.firstIndex(of: "--panel-test"), i + 1 < CommandLine.arguments.count {
            let dir = CommandLine.arguments[i + 1]
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                statusItem?.runPanelTest(dir: dir, seconds: 14)
            }
        }
    }
}
