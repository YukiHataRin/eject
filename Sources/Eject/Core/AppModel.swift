import AppKit
import Observation
import ServiceManagement
import SwiftUI

enum EjectPhase: Equatable {
    case idle
    case checking
    case terminating
    case ejecting
}

enum GroupState: Equatable {
    case terminating
    case waitingForApp
    case notPermitted
    case terminated
}

struct EjectedToast: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let detail: String
}

@MainActor
@Observable
final class AppModel {
    private(set) var volumes: [VolumeInfo] = []
    private(set) var scan = ScanResult()
    private(set) var isScanning = false
    private(set) var lastScan: Date?
    var phases: [String: EjectPhase] = [:]
    var groupStates: [String: GroupState] = [:]
    var failures: [String: EjectFailure] = [:]
    var toast: EjectedToast?
    var expanded: Set<String> = []
    var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled

    @ObservationIgnored private let monitor = DiskMonitor()
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var visibleClients = 0
    @ObservationIgnored private var inflightScan: Task<Void, Never>?
    @ObservationIgnored lazy var blockerWindow = BlockerWindowController(model: self)

    init() {
        monitor.onChange = { [weak self] volumes in self?.apply(volumes) }
        monitor.refreshNow()
        startPolling()
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
            let dir = CommandLine.arguments[i + 1]
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(600))
                Snapshot.run(model: self, dir: dir)
            }
        } else if CommandLine.arguments.contains("--preview") {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(600))
                PreviewWindow.show(model: self)
            }
        }
    }

    // MARK: - 宗卷與掃描

    private func apply(_ allVolumes: [VolumeInfo]) {
        // 除錯／截圖用：`--only <宗卷名稱>` 只顯示指定宗卷
        var newVolumes = allVolumes
        if let i = CommandLine.arguments.firstIndex(of: "--only"), i + 1 < CommandLine.arguments.count {
            newVolumes = allVolumes.filter { $0.name == CommandLine.arguments[i + 1] }
        }
        let gone = Set(volumes.map(\.id)).subtracting(newVolumes.map(\.id))
        withAnimation(.spring(response: 0.4, dampingFraction: 0.86)) {
            volumes = newVolumes
            for id in gone {
                phases[id] = nil
                failures[id] = nil
                scan.blockers[id] = nil
                scan.gitLocks[id] = nil
            }
        }
        Task { await rescan() }
    }

    func blockers(for volume: VolumeInfo) -> [BlockerGroup] { scan.blockers[volume.id] ?? [] }
    func gitLocks(for volume: VolumeInfo) -> [GitLockWarning] { scan.gitLocks[volume.id] ?? [] }
    func phase(for volume: VolumeInfo) -> EjectPhase { phases[volume.id] ?? .idle }

    /// 同一個實體裝置上的其他宗卷（退出時會一起退出）。
    func siblings(of volume: VolumeInfo) -> [VolumeInfo] {
        guard let p = volume.physicalBSDName else { return [] }
        return volumes.filter { $0.physicalBSDName == p && $0.id != volume.id }
    }

    /// 這個 App 本身是不是從這顆碟執行（會擋住自己）。
    func appRunsFrom(_ volume: VolumeInfo) -> Bool {
        Bundle.main.bundlePath.hasPrefix(volume.mountPath + "/")
    }

    var busyCount: Int { volumes.filter { !blockers(for: $0).isEmpty }.count }

    func rescan() async {
        // 已經有掃描在跑就等它完成，不重複掃描
        if let inflightScan { return await inflightScan.value }
        let task = Task { await self.performScan() }
        inflightScan = task
        await task.value
        inflightScan = nil
    }

    private func performScan() async {
        isScanning = true
        let targets = volumes
        let result = await Task.detached(priority: .userInitiated) {
            ProcessScanner.scan(volumes: targets)
        }.value
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            scan = result
            // 已經不存在的程序就移除狀態
            let alive = Set(result.blockers.values.flatMap { $0.map(\.id) })
            groupStates = groupStates.filter { alive.contains($0.key) && $0.value != .terminated }
        }
        lastScan = Date()
        isScanning = false
    }

    /// 面板或視窗開著時每 2.5 秒重新掃描；關著時放慢到 20 秒，只為了更新選單列圖示。
    private func startPolling() {
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                let visible = (self?.visibleClients ?? 0) > 0
                try? await Task.sleep(for: .seconds(visible ? 2.5 : 20))
                guard let self, !Task.isCancelled else { return }
                await self.rescan()
            }
        }
    }

    func panelDidAppear() {
        visibleClients += 1
        monitor.refreshNow()
        // 從慢速切到快速
        pollTask?.cancel()
        startPolling()
    }

    func panelDidDisappear() {
        visibleClients = max(visibleClients - 1, 0)
    }

    // MARK: - 退出

    /// - Parameter precheck: 先掃描占用者，有的話直接跳出視窗，不做注定失敗的卸載。
    func eject(_ volume: VolumeInfo, force: Bool = false, precheck: Bool = true) {
        guard phase(for: volume) == .idle else { return }
        Task { await performEject(volume, force: force, precheck: precheck) }
    }

    func ejectAll() {
        Task {
            // 同一個實體裝置只退出一次
            var seen = Set<String>()
            for v in volumes {
                let key = v.physicalBSDName ?? v.id
                guard seen.insert(key).inserted, phase(for: v) == .idle else { continue }
                await performEject(v, force: false, precheck: true)
            }
        }
    }

    private func performEject(_ volume: VolumeInfo, force: Bool, precheck: Bool) async {
        let related = [volume] + siblings(of: volume)
        setPhase(.checking, related)
        failures[volume.id] = nil

        if precheck && !force {
            await rescan()
            let known = related.flatMap(blockers(for:))
            let locks = related.flatMap(gitLocks(for:))
            if !known.isEmpty || !locks.isEmpty {
                setPhase(.idle, related)
                presentBlockers(for: volume)
                return
            }
        }

        setPhase(.ejecting, related)
        let failure = await Ejector.eject(volume, siblings: siblings(of: volume), force: force)
        setPhase(.idle, related)

        if let failure {
            failures[volume.id] = failure
            await rescan()
            presentBlockers(for: volume)
            NSSound.beep()
        } else {
            blockerWindow.closeIfShowing(volume.id)
            showToast(EjectedToast(
                name: volume.name,
                detail: volume.isNetwork ? "已中斷連線" : (volume.isDiskImage ? "映像檔已卸載" : "現在可以安全拔除")))
            monitor.scheduleRefresh()
        }
    }

    private func setPhase(_ phase: EjectPhase, _ vols: [VolumeInfo]) {
        withAnimation(.snappy) {
            for v in vols { phases[v.id] = phase == .idle ? nil : phase }
        }
    }

    func presentBlockers(for volume: VolumeInfo) {
        blockerWindow.show(volume: volume)
    }

    private func showToast(_ t: EjectedToast) {
        withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) { toast = t }
        Task {
            try? await Task.sleep(for: .seconds(4))
            if toast?.id == t.id { withAnimation(.easeOut(duration: 0.3)) { toast = nil } }
        }
    }

    // MARK: - 結束程序

    func terminate(_ group: BlockerGroup, force: Bool = false) async {
        withAnimation(.snappy) { groupStates[group.id] = .terminating }
        let outcome = await ProcessTerminator.terminate(group, force: force)
        withAnimation(.snappy) {
            switch outcome {
            case .terminated: groupStates[group.id] = .terminated
            case .stillRunning: groupStates[group.id] = .waitingForApp
            case .notPermitted: groupStates[group.id] = .notPermitted
            }
        }
        await rescan()
    }

    /// 結束所有占用者，全部成功後退出。
    func terminateAllAndEject(_ volume: VolumeInfo) async {
        let related = [volume] + siblings(of: volume)
        let groups = related.flatMap(blockers(for:))
        setPhase(.terminating, related)
        await withTaskGroup(of: Void.self) { tg in
            for g in groups where groupStates[g.id] != .notPermitted {
                tg.addTask { await self.terminate(g) }
            }
        }
        setPhase(.idle, related)
        let remaining = related.flatMap(blockers(for:))
        if remaining.isEmpty {
            await performEject(volume, force: false, precheck: false)
        }
    }

    // MARK: - 其他

    func reveal(_ volume: VolumeInfo) {
        NSWorkspace.shared.activateFileViewerSelecting([volume.mountURL])
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("Launch at login failed: \(error)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
