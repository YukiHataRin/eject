import AppKit
import DiskArbitration
import IOKit

/// 透過 DiskArbitration 監聽掛載／卸載事件，維護外接宗卷清單。
@MainActor
final class DiskMonitor {
    private let session: DASession
    private var pendingRefresh: DispatchWorkItem?
    var onChange: (([VolumeInfo]) -> Void)?

    init() {
        session = DASessionCreate(kCFAllocatorDefault)!
        DASessionSetDispatchQueue(session, .main)

        let context = Unmanaged.passUnretained(self).toOpaque()
        DARegisterDiskAppearedCallback(session, nil, { _, ctx in
            DiskMonitor.trampoline(ctx)
        }, context)
        DARegisterDiskDisappearedCallback(session, nil, { _, ctx in
            DiskMonitor.trampoline(ctx)
        }, context)
        // 宗卷路徑或名稱改變（掛載完成、改名）時也要更新。
        let watch = [kDADiskDescriptionVolumePathKey, kDADiskDescriptionVolumeNameKey] as CFArray
        DARegisterDiskDescriptionChangedCallback(session, nil, watch, { _, _, ctx in
            DiskMonitor.trampoline(ctx)
        }, context)

        // 網路宗卷不會經過 DiskArbitration 的 appeared 事件，用 NSWorkspace 補上。
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleRefresh() }
            }
        }
    }

    nonisolated private static func trampoline(_ ctx: UnsafeMutableRawPointer?) {
        guard let ctx else { return }
        let address = UInt(bitPattern: ctx)
        MainActor.assumeIsolated {
            guard let raw = UnsafeMutableRawPointer(bitPattern: address) else { return }
            Unmanaged<DiskMonitor>.fromOpaque(raw).takeUnretainedValue().scheduleRefresh()
        }
    }

    /// 事件常常一次來一串，合併成一次更新。
    func scheduleRefresh() {
        pendingRefresh?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.refreshNow() }
        }
        pendingRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    func refreshNow() {
        onChange?(Self.currentVolumes(session: session))
    }

    // MARK: - 列舉宗卷

    private static let resourceKeys: [URLResourceKey] = [
        .volumeNameKey, .volumeLocalizedNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
        .volumeLocalizedFormatDescriptionKey, .volumeIsInternalKey, .volumeIsEjectableKey,
        .volumeIsRemovableKey, .volumeIsLocalKey, .volumeIsReadOnlyKey, .volumeIsRootFileSystemKey,
    ]

    static func currentVolumes(session: DASession) -> [VolumeInfo] {
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: resourceKeys, options: [.skipHiddenVolumes]) ?? []

        var result: [VolumeInfo] = []
        for url in urls {
            let path = url.path
            guard path.hasPrefix("/Volumes/") else { continue }
            guard let values = try? url.resourceValues(forKeys: Set(resourceKeys)) else { continue }
            if values.volumeIsRootFileSystem == true { continue }

            let isLocal = values.volumeIsLocal ?? true
            let isInternal = values.volumeIsInternal ?? false
            let ejectable = values.volumeIsEjectable ?? false
            let removable = values.volumeIsRemovable ?? false
            // 內建碟上的其他宗卷（例如 Recovery）不列出。
            guard !isLocal || !isInternal || ejectable || removable else { continue }

            var description: [String: Any] = [:]
            var physical: String?
            var bsd: String?
            if let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url as CFURL) {
                description = DADiskCopyDescription(disk) as? [String: Any] ?? [:]
                bsd = description[kDADiskDescriptionMediaBSDNameKey as String] as? String
                physical = physicalWholeDiskBSDName(for: disk)
                if (description[kDADiskDescriptionDeviceInternalKey as String] as? Bool) == true,
                   !ejectable, !removable, isLocal {
                    continue
                }
            }

            let proto = description[kDADiskDescriptionDeviceProtocolKey as String] as? String
            let model = (description[kDADiskDescriptionDeviceModelKey as String] as? String)?
                .trimmingCharacters(in: .whitespaces)
            let isDiskImage = proto == "Virtual Interface"
                || model?.localizedCaseInsensitiveContains("Disk Image") == true

            var st = stat()
            let dev: Int32 = stat(path, &st) == 0 ? st.st_dev : -1

            result.append(VolumeInfo(
                name: values.volumeLocalizedName ?? values.volumeName ?? url.lastPathComponent,
                mountPath: path,
                bsdName: bsd,
                physicalBSDName: physical,
                deviceID: dev,
                totalBytes: Int64(values.volumeTotalCapacity ?? 0),
                availableBytes: Int64(values.volumeAvailableCapacity ?? 0),
                formatName: values.volumeLocalizedFormatDescription ?? "未知格式",
                connection: proto.map(prettyProtocol),
                model: model,
                isNetwork: !isLocal,
                isDiskImage: isDiskImage,
                isReadOnly: values.volumeIsReadOnly ?? false
            ))
        }
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func prettyProtocol(_ raw: String) -> String {
        switch raw {
        case "USB": "USB"
        case "Thunderbolt": "Thunderbolt"
        case "PCI-Express": "PCIe"
        case "SATA": "SATA"
        case "Secure Digital": "SD 卡"
        case "FireWire": "FireWire"
        default: raw
        }
    }

    /// 沿著 IORegistry 往上找，最上層的 whole IOMedia 就是實體裝置。
    /// APFS：disk5s1 → disk5（合成）→ disk4s2 → disk4（實體）。
    static func physicalWholeDiskBSDName(for disk: DADisk) -> String? {
        let media = DADiskCopyIOMedia(disk)
        guard media != 0 else { return nil }

        var current: io_registry_entry_t = media
        var topWhole: String?
        var depth = 0
        while current != 0, depth < 64 {
            depth += 1
            if IOObjectConformsTo(current, "IOMedia") != 0 {
                let whole = IORegistryEntryCreateCFProperty(current, "Whole" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? Bool
                if whole == true,
                   let name = IORegistryEntryCreateCFProperty(current, "BSD Name" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? String {
                    topWhole = name
                }
            }
            var parent: io_registry_entry_t = 0
            let kr = IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent)
            IOObjectRelease(current)
            current = kr == KERN_SUCCESS ? parent : 0
        }
        if current != 0 { IOObjectRelease(current) }
        return topWhole
    }
}
