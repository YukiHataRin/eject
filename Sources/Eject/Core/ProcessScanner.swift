import Darwin
import Foundation

/// 用 libproc 列舉每個程序開啟的檔案、工作目錄與執行檔，找出誰在使用外接宗卷。
/// 只看得到目前使用者自己的程序；root 程序（例如 Spotlight）需要 root 權限才看得到。
enum ProcessScanner {
    static func scan(volumes: [VolumeInfo]) -> ScanResult {
        let targets = volumes.filter { $0.deviceID != -1 }
        guard !targets.isEmpty else { return ScanResult() }

        let byDevice = Dictionary(targets.map { ($0.deviceID, $0) }, uniquingKeysWith: { a, _ in a })
        let myPID = getpid()
        let myUID = getuid()

        var perVolume: [String: [BlockingProcess]] = [:]
        var parentOf: [Int32: Int32] = [:]
        var pathOf: [Int32: String] = [:]

        let pids = listAllPIDs()
        for pid in pids {
            guard pid > 1 else { continue }
            var info = proc_bsdinfo()
            let infoSize = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, infoSize) == infoSize else { continue }
            parentOf[pid] = Int32(info.pbi_ppid)
            let exe = executablePath(pid)
            if let exe { pathOf[pid] = exe }

            guard pid != myPID, info.pbi_uid == myUID else { continue }

            var reasons: [String: [UsageReason]] = [:]  // mountPath -> reasons

            // 1. 開啟中的檔案
            for (dev, path) in openVnodes(pid) {
                if let v = byDevice[dev] { reasons[v.mountPath, default: []].append(.openFile(path)) }
            }
            // 2. 工作目錄
            if let (dev, path) = workingDirectory(pid), let v = byDevice[dev] {
                reasons[v.mountPath, default: []].append(.workingDirectory(path))
            }
            // 3. 執行檔本身就在碟上
            if let exe {
                for v in targets where exe.hasPrefix(v.mountPath + "/") {
                    reasons[v.mountPath, default: []].append(.executable(exe))
                }
            }
            guard !reasons.isEmpty else { continue }

            let name = exe.map { ($0 as NSString).lastPathComponent } ?? processName(pid)
            let args = arguments(pid)
            let isShell = shellNames.contains(name.trimmingCharacters(in: CharacterSet(charactersIn: "-")))

            for (mount, rs) in reasons {
                perVolume[mount, default: []].append(BlockingProcess(
                    pid: pid, name: name, executablePath: exe ?? name, arguments: args,
                    reasons: dedupe(rs), appBundlePath: nil, hostAppName: nil, hostAppPath: nil,
                    devServer: nil, isShell: isShell))
            }
        }

        var result = ScanResult()
        for (mount, procs) in perVolume {
            // 補上宿主 App 與 dev server 資訊
            let enriched = procs.map { p -> BlockingProcess in
                let app = owningApp(pid: p.pid, executable: p.executablePath, parentOf: parentOf, pathOf: pathOf)
                let host = app == nil ? hostApp(for: p.pid, parentOf: parentOf, pathOf: pathOf) : nil
                return BlockingProcess(
                    pid: p.pid, name: p.name, executablePath: p.executablePath, arguments: p.arguments,
                    reasons: p.reasons, appBundlePath: app,
                    hostAppName: host.map { displayName(ofBundle: $0) }, hostAppPath: host,
                    devServer: app == nil && !p.isShell ? detectDevServer(p, volumeRoot: mount) : nil,
                    isShell: p.isShell)
            }
            result.blockers[mount] = group(enriched)
            let locks = gitLocks(for: enriched, volumeRoot: mount)
            if !locks.isEmpty { result.gitLocks[mount] = locks }
        }
        return result
    }

    // MARK: - 分組

    private static func group(_ procs: [BlockingProcess]) -> [BlockerGroup] {
        var apps: [String: [BlockingProcess]] = [:]
        var groups: [BlockerGroup] = []
        for p in procs {
            if let bundle = p.appBundlePath {
                apps[bundle, default: []].append(p)
            } else {
                let title: String
                if let dev = p.devServer {
                    title = dev.tool
                } else {
                    title = p.name
                }
                groups.append(BlockerGroup(id: "pid:\(p.pid)", displayName: title, appBundlePath: nil,
                                           bundleIdentifier: nil, processes: [p]))
            }
        }
        for (bundle, ps) in apps {
            groups.append(BlockerGroup(
                id: "app:\(bundle)", displayName: displayName(ofBundle: bundle), appBundlePath: bundle,
                bundleIdentifier: Bundle(path: bundle)?.bundleIdentifier,
                processes: ps.sorted { $0.pid < $1.pid }))
        }
        // App 排前面，接著 dev server，最後其他命令列程序
        return groups.sorted { a, b in
            func rank(_ g: BlockerGroup) -> Int { g.isApp ? 0 : (g.devServer != nil ? 1 : 2) }
            if rank(a) != rank(b) { return rank(a) < rank(b) }
            return a.displayName.localizedStandardCompare(b.displayName) == .orderedAscending
        }
    }

    /// 取最外層的 .app，讓「Code Helper (Plugin).app」歸到「Visual Studio Code.app」。
    static func bundlePath(of executable: String) -> String? {
        guard let range = executable.range(of: ".app/") else { return nil }
        let candidate = String(executable[..<range.lowerBound]) + ".app"
        return candidate.hasPrefix("/") ? candidate : nil
    }

    /// 程序是否屬於某個 App：本身是 App 的主程式，或祖先是那個 App 的主程式（例如 VS Code 的 helper）。
    /// 像 /usr/bin/python3 實際執行 Xcode.app 內的 Python，但不是 Xcode 啟動的，就不算 Xcode。
    private static func owningApp(pid: Int32, executable: String, parentOf: [Int32: Int32], pathOf: [Int32: String]) -> String? {
        guard let outer = bundlePath(of: executable) else { return nil }
        let mainDir = outer + "/Contents/MacOS/"
        if executable.hasPrefix(mainDir) { return outer }
        var current = parentOf[pid]
        var hops = 0
        while let p = current, p > 1, hops < 16 {
            if pathOf[p]?.hasPrefix(mainDir) == true { return outer }
            current = parentOf[p]
            hops += 1
        }
        return nil
    }

    static func displayName(ofBundle path: String) -> String {
        if let b = Bundle(path: path),
           let n = (b.localizedInfoDictionary?["CFBundleDisplayName"] ?? b.infoDictionary?["CFBundleDisplayName"]
                    ?? b.infoDictionary?["CFBundleName"]) as? String, !n.isEmpty {
            return n
        }
        return FileManager.default.displayName(atPath: path).replacingOccurrences(of: ".app", with: "")
    }

    private static func hostApp(for pid: Int32, parentOf: [Int32: Int32], pathOf: [Int32: String]) -> String? {
        var current = parentOf[pid]
        var hops = 0
        while let p = current, p > 1, hops < 16 {
            if let exe = pathOf[p], let bundle = bundlePath(of: exe), exe.hasPrefix(bundle + "/Contents/MacOS/") {
                return bundle
            }
            current = parentOf[p]
            hops += 1
        }
        return nil
    }

    private static func dedupe(_ rs: [UsageReason]) -> [UsageReason] {
        var seen = Set<UsageReason>()
        return rs.filter { seen.insert($0).inserted }
    }

    // MARK: - Dev server 辨識

    static let shellNames: Set<String> = ["zsh", "bash", "fish", "sh", "dash", "tcsh", "csh", "ksh", "nu", "elvish"]

    private static let devTools: [(key: String, label: String)] = [
        ("next", "Next.js"), ("vitest", "Vitest"), ("vite", "Vite"), ("nuxt", "Nuxt"), ("nuxi", "Nuxt"),
        ("astro", "Astro"), ("svelte-kit", "SvelteKit"), ("remix", "Remix"), ("react-scripts", "Create React App"),
        ("webpack-dev-server", "Webpack"), ("webpack", "Webpack"), ("parcel", "Parcel"), ("storybook", "Storybook"),
        ("expo", "Expo"), ("wrangler", "Wrangler"), ("turbo", "Turborepo"), ("nodemon", "nodemon"),
        ("tsserver.js", "TS Server"), ("esbuild", "esbuild"), ("jest", "Jest"), ("tsx", "tsx"),
        ("uvicorn", "Uvicorn"), ("gunicorn", "Gunicorn"), ("flask", "Flask"), ("jupyter-lab", "JupyterLab"),
        ("jupyter-notebook", "Jupyter"), ("jupyter", "Jupyter"), ("streamlit", "Streamlit"),
        ("hugo", "Hugo"), ("jekyll", "Jekyll"), ("rails", "Rails"),
    ]

    private static func detectDevServer(_ p: BlockingProcess, volumeRoot: String) -> DevServerInfo? {
        var components = Set<String>()
        for arg in p.arguments.prefix(12) {
            for c in arg.split(separator: "/") { components.insert(String(c)) }
        }
        let joined = p.arguments.joined(separator: " ")
        var tool: String?
        if joined.contains("manage.py") && joined.contains("runserver") { tool = "Django" }
        if tool == nil, joined.contains("tsc") && (joined.contains("--watch") || joined.contains(" -w")) {
            tool = "TypeScript watch"
        }
        if tool == nil {
            tool = devTools.first { components.contains($0.key) }?.label
        }
        if tool == nil, p.name == "claude" || components.contains("claude-code") || components.contains("@anthropic-ai") {
            tool = "Claude Code"
        }
        guard let tool else { return nil }
        return DevServerInfo(tool: tool, project: projectName(for: p, volumeRoot: volumeRoot))
    }

    private static func projectName(for p: BlockingProcess, volumeRoot: String) -> String? {
        var start: String?
        for r in p.reasons { if case .workingDirectory(let d) = r { start = d } }
        if start == nil {
            start = p.arguments.first { $0.hasPrefix(volumeRoot + "/") }.map { ($0 as NSString).deletingLastPathComponent }
        }
        guard let start, let root = projectRoot(from: start, volumeRoot: volumeRoot) else { return nil }
        let pkg = (root as NSString).appendingPathComponent("package.json")
        if let data = FileManager.default.contents(atPath: pkg),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let name = json["name"] as? String, !name.isEmpty {
            return name
        }
        return (root as NSString).lastPathComponent
    }

    /// 從某個資料夾往上找 package.json／pyproject.toml／.git，最多到宗卷根目錄。
    private static func projectRoot(from dir: String, volumeRoot: String) -> String? {
        let fm = FileManager.default
        var current = dir
        // 若在 node_modules 裡面，先跳出來
        if let r = current.range(of: "/node_modules") { current = String(current[..<r.lowerBound]) }
        while current.hasPrefix(volumeRoot), current.count > volumeRoot.count {
            for marker in ["package.json", "pyproject.toml", "Cargo.toml", "go.mod", ".git"] {
                if fm.fileExists(atPath: (current as NSString).appendingPathComponent(marker)) { return current }
            }
            current = (current as NSString).deletingLastPathComponent
        }
        return nil
    }

    private static func gitLocks(for procs: [BlockingProcess], volumeRoot: String) -> [GitLockWarning] {
        let fm = FileManager.default
        var repos = Set<String>()
        for p in procs {
            for r in p.reasons {
                var dir: String
                switch r {
                case .workingDirectory(let d): dir = d
                case .openFile(let f): dir = (f as NSString).deletingLastPathComponent
                case .executable: continue
                }
                if let gitRange = dir.range(of: "/.git") { dir = String(dir[..<gitRange.lowerBound]) }
                while dir.hasPrefix(volumeRoot), dir.count > volumeRoot.count {
                    if fm.fileExists(atPath: (dir as NSString).appendingPathComponent(".git")) {
                        repos.insert(dir)
                        break
                    }
                    dir = (dir as NSString).deletingLastPathComponent
                }
            }
        }
        return repos.sorted().compactMap { repo in
            let lock = (repo as NSString).appendingPathComponent(".git/index.lock")
            guard fm.fileExists(atPath: lock) else { return nil }
            return GitLockWarning(repoName: (repo as NSString).lastPathComponent, lockPath: lock)
        }
    }

    // MARK: - libproc 包裝

    static func listAllPIDs() -> [Int32] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(estimate) + 128)
        let count = pids.withUnsafeMutableBytes { buf in
            proc_listallpids(buf.baseAddress, Int32(buf.count))
        }
        guard count > 0 else { return [] }
        return Array(pids.prefix(Int(count)))
    }

    static func executablePath(_ pid: Int32) -> String? {
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        guard n > 0 else { return nil }
        return decode(buf)
    }

    static func processName(_ pid: Int32) -> String {
        var buf = [CChar](repeating: 0, count: 256)
        proc_name(pid, &buf, UInt32(buf.count))
        let s = decode(buf)
        return s.isEmpty ? "PID \(pid)" : s
    }

    static func isAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    private static func openVnodes(_ pid: Int32) -> [(Int32, String)] {
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / stride + 32)
        let used = fds.withUnsafeMutableBytes { buf in
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, buf.baseAddress, Int32(buf.count))
        }
        guard used > 0 else { return [] }

        var result: [(Int32, String)] = []
        let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
        for fd in fds.prefix(Int(used) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            var vinfo = vnode_fdinfowithpath()
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &vinfo, size) == size else { continue }
            let path = cString(from: vinfo.pvip.vip_path)
            result.append((Int32(bitPattern: vinfo.pvip.vip_vi.vi_stat.vst_dev), path))
        }
        return result
    }

    private static func workingDirectory(_ pid: Int32) -> (Int32, String)? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = cString(from: info.pvi_cdir.vip_path)
        guard !path.isEmpty else { return nil }
        return (Int32(bitPattern: info.pvi_cdir.vip_vi.vi_stat.vst_dev), path)
    }

    /// 透過 KERN_PROCARGS2 讀取命令列參數。
    static func arguments(_ pid: Int32) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }

        let argc = buf.withUnsafeBytes { $0.load(as: Int32.self) }
        var i = MemoryLayout<Int32>.size
        // 略過執行檔路徑與其後的補零
        while i < size, buf[i] != 0 { i += 1 }
        while i < size, buf[i] == 0 { i += 1 }

        var args: [String] = []
        while i < size, args.count < Int(argc) {
            let start = i
            while i < size, buf[i] != 0 { i += 1 }
            args.append(String(decoding: buf[start..<i], as: UTF8.self))
            i += 1
        }
        return args
    }

    private static func decode(_ buf: [CChar]) -> String {
        String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static func cString<T>(from tuple: T) -> String {
        withUnsafeBytes(of: tuple) { raw in
            let bytes = raw.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
    }
}
