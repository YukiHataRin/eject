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
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuPanel()
                .environment(model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}

/// 選單列圖示：有磁碟被占用時換成帶驚嘆號的版本。
private struct MenuBarLabel: View {
    let model: AppModel

    var body: some View {
        let symbol: String = {
            if model.volumes.isEmpty { return "externaldrive" }
            if model.phases.values.contains(where: { $0 != .idle }) { return "eject.circle.fill" }
            if model.busyCount > 0 { return "externaldrive.fill.badge.exclamationmark" }
            return "externaldrive.fill"
        }()
        Image(systemName: symbol)
    }
}
