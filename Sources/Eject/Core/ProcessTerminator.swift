import AppKit
import Darwin

enum TerminationOutcome: Sendable, Equatable {
    case terminated
    /// App 還開著（多半是在問要不要儲存），需要使用者決定要不要強制結束。
    case stillRunning
    case notPermitted
}

/// 結束占用磁碟的程序：GUI App 走正常的「結束」，命令列程序送 SIGTERM，等不到再 SIGKILL。
@MainActor
enum ProcessTerminator {
    static func terminate(_ group: BlockerGroup, force: Bool = false) async -> TerminationOutcome {
        if let bundle = group.appBundlePath,
           let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleURL?.path == bundle }) {
            let ok = force ? app.forceTerminate() : app.terminate()
            if !ok && !force {
                // App 不接受 Apple Event 時，退回訊號
                return await signalAll(group.pids, shells: false)
            }
            let gone = await waitUntilGone([app.processIdentifier], timeout: force ? 3 : 8)
            if gone {
                // 主程式結束後，殘留的 helper 也收拾掉
                let leftovers = group.pids.filter(ProcessScanner.isAlive)
                if !leftovers.isEmpty { _ = await signalAll(leftovers, shells: false) }
                return .terminated
            }
            return .stillRunning
        }
        return await signalAll(group.pids, shells: group.isShell, force: force)
    }

    private static func signalAll(_ pids: [Int32], shells: Bool, force: Bool = false) async -> TerminationOutcome {
        // 互動式 shell 會忽略 SIGTERM，用 SIGHUP（等同關閉終端機分頁）
        let first = force ? SIGKILL : (shells ? SIGHUP : SIGTERM)
        var denied = false
        for pid in pids where kill(pid, first) != 0 && errno == EPERM { denied = true }
        if denied { return .notPermitted }

        if await waitUntilGone(pids, timeout: 3) { return .terminated }
        for pid in pids where ProcessScanner.isAlive(pid) { kill(pid, SIGKILL) }
        return await waitUntilGone(pids, timeout: 2) ? .terminated : .stillRunning
    }

    private static func waitUntilGone(_ pids: [Int32], timeout: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if pids.allSatisfy({ !ProcessScanner.isAlive($0) }) { return true }
            try? await Task.sleep(for: .milliseconds(120))
        }
        return pids.allSatisfy { !ProcessScanner.isAlive($0) }
    }
}
