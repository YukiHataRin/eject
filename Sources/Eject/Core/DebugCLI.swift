import AppKit
import DiskArbitration
import SwiftUI
import Foundation

/// `Eject --scan`：不開介面，直接印出外接宗卷與占用者，方便除錯。
@MainActor
enum DebugCLI {
    static func run() {
        let session = DASessionCreate(kCFAllocatorDefault)!
        let volumes = DiskMonitor.currentVolumes(session: session)
        let start = Date()
        let result = ProcessScanner.scan(volumes: volumes)
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        print("掃描 \(ProcessScanner.listAllPIDs().count) 個程序，耗時 \(ms) ms\n")
        for v in volumes {
            print("■ \(v.name)  [\(v.metaLine)]  \(v.bsdName ?? "-") → 實體 \(v.physicalBSDName ?? "-")  dev=\(v.deviceID)")
            for g in result.blockers[v.id] ?? [] {
                let dev = g.devServer.map { " ⚡︎\($0.tool)\($0.project.map { "(\($0))" } ?? "")" } ?? ""
                let host = g.hostAppName.map { " 在 \($0) 中" } ?? ""
                print("   • \(g.displayName)\(dev)\(host) — \(g.summary)")
                for f in (g.workingDirectories + g.openFiles).prefix(3) { print("       \(f)") }
            }
            for l in result.gitLocks[v.id] ?? [] { print("   ⚠︎ git lock: \(l.lockPath)") }
        }
    }
}

/// `Eject --preview`：把選單列面板放進一般視窗，方便截圖檢查介面。
@MainActor
enum PreviewWindow {
    private static var window: NSWindow?

    static func show(model: AppModel) {
        let root = MenuPanel()
            .environment(model)
            .background(VisualEffectBackground(material: .popover).ignoresSafeArea())
        let hosting = NSHostingController(rootView: root)
        hosting.sizingOptions = [.preferredContentSize]
        let w = NSWindow(contentViewController: hosting)
        w.title = "Eject Preview"
        w.setFrameTopLeftPoint(NSPoint(x: 120, y: (NSScreen.main?.frame.maxY ?? 900) - 80))
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = w
    }
}

/// `Eject --snapshot <資料夾> [--dark]`：開預覽視窗與占用視窗，輸出 PNG 後結束。
@MainActor
enum Snapshot {
    static func run(model: AppModel, dir: String) {
        if CommandLine.arguments.contains("--dark") { NSApp.appearance = NSAppearance(named: .darkAqua) }
        else { NSApp.appearance = NSAppearance(named: .aqua) }
        PreviewWindow.show(model: model)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            if let v = model.volumes.first(where: { !model.blockers(for: $0).isEmpty }) {
                model.expanded.insert(v.id)
                model.presentBlockers(for: v)
            }
            try? await Task.sleep(for: .seconds(2))
            let suffix = CommandLine.arguments.contains("--dark") ? "-dark" : ""
            for (i, w) in NSApp.windows.enumerated() where w.isVisible {
                guard let view = w.contentView?.superview ?? w.contentView,
                      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                view.cacheDisplay(in: view.bounds, to: rep)
                let name = w.title.contains("Preview") ? "panel" : "window\(i)"
                try? rep.representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name)\(suffix).png"))
            }
            NSApp.terminate(nil)
        }
    }
}

/// `Eject --eject-test <宗卷名稱>`：先直接退出（預期失敗），再結束占用者後退出。
@MainActor
enum EjectTest {
    static func run(name: String) async {
        let session = DASessionCreate(kCFAllocatorDefault)!
        guard let v = DiskMonitor.currentVolumes(session: session).first(where: { $0.name == name }) else {
            print("找不到 \(name)"); return
        }
        print("1. 直接退出…")
        if let f = await Ejector.eject(v, siblings: [], force: false) {
            print("   失敗（符合預期）：\(f.friendlyMessage) busy=\(f.isBusy) raw=\(f.message)")
        } else { print("   竟然成功了"); return }

        let groups = ProcessScanner.scan(volumes: [v]).blockers[v.id] ?? []
        print("2. 結束 \(groups.count) 個占用者…")
        for g in groups {
            let start = Date()
            let r = await ProcessTerminator.terminate(g)
            print("   \(g.displayName): \(r)（\(String(format: "%.1f", Date().timeIntervalSince(start)))s）")
        }
        print("   剩餘占用者：\((ProcessScanner.scan(volumes: [v]).blockers[v.id] ?? []).count)")
        print("3. 再次退出…")
        if let f = await Ejector.eject(v, siblings: [], force: false) { print("   失敗：\(f.friendlyMessage)") }
        else { print("   ✓ 成功，\(FileManager.default.fileExists(atPath: v.mountPath) ? "但掛載點還在" : "掛載點已移除")") }
    }
}
