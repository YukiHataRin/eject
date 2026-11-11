import Foundation

/// 一個掛載在 /Volumes 底下的外接宗卷。
struct VolumeInfo: Identifiable, Hashable, Sendable {
    /// 以掛載路徑當作識別，宗卷改名時會重新產生。
    var id: String { mountPath }

    let name: String
    let mountPath: String
    let bsdName: String?
    /// 實體裝置的 whole disk（例如 APFS 宗卷 disk5s1 → 實體 disk4）。
    let physicalBSDName: String?
    let deviceID: Int32
    let totalBytes: Int64
    let availableBytes: Int64
    let formatName: String
    let connection: String?
    let model: String?
    let isNetwork: Bool
    let isDiskImage: Bool
    let isReadOnly: Bool

    var usedBytes: Int64 { max(totalBytes - availableBytes, 0) }
    var usedFraction: Double {
        totalBytes > 0 ? Double(usedBytes) / Double(totalBytes) : 0
    }

    var mountURL: URL { URL(fileURLWithPath: mountPath, isDirectory: true) }

    /// 「APFS · USB · SanDisk Extreme」這樣的描述。
    var metaLine: String {
        var parts: [String] = [formatName]
        if isNetwork {
            parts.append("網路")
        } else if isDiskImage {
            parts.append("磁碟映像檔")
        } else if let connection, !connection.isEmpty {
            parts.append(connection)
        }
        if let model, !model.isEmpty, !isDiskImage { parts.append(model) }
        if isReadOnly { parts.append("唯讀") }
        return parts.joined(separator: " · ")
    }

    var symbolName: String {
        if isNetwork { return "server.rack" }
        if isDiskImage { return "opticaldiscdrive" }
        return "externaldrive.fill"
    }
}

/// 程序為什麼會擋住退出。
enum UsageReason: Hashable, Sendable {
    case openFile(String)
    case workingDirectory(String)
    case executable(String)

    var path: String {
        switch self {
        case .openFile(let p), .workingDirectory(let p), .executable(let p): p
        }
    }
}

/// 一個擋住退出的程序。
struct BlockingProcess: Identifiable, Hashable, Sendable {
    var id: Int32 { pid }
    let pid: Int32
    let name: String
    let executablePath: String
    let arguments: [String]
    let reasons: [UsageReason]
    /// 屬於哪個 App（主程式或由它啟動的 helper）。命令列程序為 nil。
    let appBundlePath: String?
    /// 若此程序在 Terminal、VS Code 等 App 裡被啟動，記錄那個 App。
    let hostAppName: String?
    let hostAppPath: String?
    let devServer: DevServerInfo?
    let isShell: Bool
}

/// 辨識出來的 dev server／watcher。
struct DevServerInfo: Hashable, Sendable {
    let tool: String
    let project: String?
}

/// 卡片上顯示的一組占用者：同一個 App 的所有子程序合為一組，命令列程序各自一組。
struct BlockerGroup: Identifiable, Hashable, Sendable {
    let id: String
    let displayName: String
    /// App 的 .app 路徑（用來取圖示與正常結束）。
    let appBundlePath: String?
    let bundleIdentifier: String?
    let processes: [BlockingProcess]

    var isApp: Bool { appBundlePath != nil }
    var pids: [Int32] { processes.map(\.pid) }

    var openFiles: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for p in processes {
            for r in p.reasons {
                if case .openFile(let path) = r, seen.insert(path).inserted { result.append(path) }
            }
        }
        return result
    }

    var workingDirectories: [String] {
        Array(Set(processes.flatMap { p in
            p.reasons.compactMap { r -> String? in
                if case .workingDirectory(let path) = r { return path }
                return nil
            }
        })).sorted()
    }

    var runsFromVolume: Bool {
        processes.contains { p in p.reasons.contains { if case .executable = $0 { true } else { false } } }
    }

    var devServer: DevServerInfo? { processes.lazy.compactMap(\.devServer).first }
    var hostAppName: String? { processes.lazy.compactMap(\.hostAppName).first }
    var hostAppPath: String? { processes.lazy.compactMap(\.hostAppPath).first }
    var isShell: Bool { !isApp && processes.allSatisfy(\.isShell) }

    /// 一行摘要：「開啟 4 個檔案 · 工作目錄在此」。
    var summary: String {
        var parts: [String] = []
        if isApp, processes.count > 1 { parts.append("\(processes.count) 個程序") }
        let files = openFiles.count
        if files > 0 { parts.append("開啟 \(files) 個檔案") }
        if !workingDirectories.isEmpty { parts.append("工作目錄在此") }
        if runsFromVolume { parts.append("從此碟執行") }
        if !isApp {
            parts.append("PID \(processes.map { String($0.pid) }.joined(separator: ", "))")
        }
        return parts.joined(separator: " · ")
    }
}

/// 偵測到 git 操作進行中（.git/index.lock 存在）。
struct GitLockWarning: Hashable, Sendable, Identifiable {
    var id: String { lockPath }
    let repoName: String
    let lockPath: String
}

/// 一次掃描的結果，依宗卷分類。
struct ScanResult: Sendable {
    var blockers: [String: [BlockerGroup]] = [:]
    var gitLocks: [String: [GitLockWarning]] = [:]
}
