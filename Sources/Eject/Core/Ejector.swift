import DiskArbitration
import Foundation

/// DAReturn 常數在 Swift 裡可能是 Int 或負的 Int32，統一轉成 Int32 比較。
func da<T: BinaryInteger>(_ value: T) -> Int32 { Int32(truncatingIfNeeded: value) }

/// 退出失敗時 DiskArbitration 回報的原因。
struct EjectFailure: Error, Sendable, Equatable {
    let status: Int32
    let message: String
    let volumeName: String?

    /// DiskArbitration 會把 unmount(2) 的 errno 包成 0xC000 | errno（例如 EBUSY → 0xC010）。
    private var unixErrno: Int32? { (status & ~0x3FFF) == 0xC000 ? status & 0x3FFF : nil }

    var isBusy: Bool { status == da(kDAReturnBusy) || unixErrno == EBUSY }

    var friendlyMessage: String {
        if let e = unixErrno {
            switch e {
            case EBUSY: return "磁碟正在使用中"
            case EPERM, EACCES: return "沒有權限退出這顆磁碟"
            default: return "退出失敗：\(String(decoding: strerror(e).map { UnsafeRawBufferPointer(start: $0, count: strlen($0)) }.map(Array.init) ?? [], as: UTF8.self))"
            }
        }
        return switch status {
        case da(kDAReturnBusy): "磁碟正在使用中"
        case da(kDAReturnNotPermitted), da(kDAReturnNotPrivileged): "沒有權限退出這顆磁碟"
        case da(kDAReturnExclusiveAccess): "其他程式正獨占這顆磁碟"
        case da(kDAReturnNotFound): "找不到這顆磁碟，可能已經拔除"
        case da(kDAReturnUnsupported): "這顆磁碟不支援退出"
        default: message.isEmpty ? "退出失敗（錯誤碼 \(String(format: "0x%08X", UInt32(bitPattern: status)))）" : message
        }
    }
}

/// 用 DiskArbitration 卸載並退出整個實體裝置。
enum Ejector {
    private static let queue = DispatchQueue(label: "eject.diskarbitration")
    nonisolated(unsafe) private static let session: DASession = {
        let s = DASessionCreate(kCFAllocatorDefault)!
        DASessionSetDispatchQueue(s, queue)
        return s
    }()

    /// 卸載這個宗卷所在實體裝置上的所有宗卷，再退出裝置。
    static func eject(_ volume: VolumeInfo, siblings: [VolumeInfo], force: Bool) async -> EjectFailure? {
        let options = DADiskUnmountOptions(force ? kDADiskUnmountOptionForce : kDADiskUnmountOptionDefault)

        // 1. 逐一卸載宗卷，失敗時可以知道是哪一個
        for v in [volume] + siblings.filter({ $0.id != volume.id }) {
            guard let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, v.mountURL as CFURL) else { continue }
            if var failure = await unmount(disk, options: options) {
                failure = EjectFailure(status: failure.status, message: failure.message, volumeName: v.name)
                return failure
            }
        }

        guard let physical = volume.physicalBSDName,
              let whole = physical.withCString({ DADiskCreateFromBSDName(kCFAllocatorDefault, session, $0) })
        else { return nil }  // 網路宗卷等：卸載即完成

        // 2. 卸載同一裝置上其他沒被列出的宗卷
        if let failure = await unmount(whole, options: options | DADiskUnmountOptions(kDADiskUnmountOptionWhole)),
           failure.isBusy {
            return failure
        }

        // 3. 退出實體裝置。不支援退出的裝置在卸載後就算成功。
        if let failure = await ejectDisk(whole),
           failure.status != da(kDAReturnUnsupported) {
            return failure
        }
        return nil
    }

    private final class Box: @unchecked Sendable {
        let continuation: CheckedContinuation<EjectFailure?, Never>
        init(_ c: CheckedContinuation<EjectFailure?, Never>) { continuation = c }
    }

    nonisolated private static func failure(from dissenter: DADissenter?) -> EjectFailure? {
        guard let dissenter else { return nil }
        let message = DADissenterGetStatusString(dissenter) as String? ?? ""
        return EjectFailure(status: DADissenterGetStatus(dissenter), message: message, volumeName: nil)
    }

    private static func unmount(_ disk: DADisk, options: DADiskUnmountOptions) async -> EjectFailure? {
        await withCheckedContinuation { continuation in
            let box = Unmanaged.passRetained(Box(continuation)).toOpaque()
            DADiskUnmount(disk, options, { _, dissenter, ctx in
                let box = Unmanaged<Box>.fromOpaque(ctx!).takeRetainedValue()
                box.continuation.resume(returning: Ejector.failure(from: dissenter))
            }, box)
        }
    }

    private static func ejectDisk(_ disk: DADisk) async -> EjectFailure? {
        await withCheckedContinuation { continuation in
            let box = Unmanaged.passRetained(Box(continuation)).toOpaque()
            DADiskEject(disk, DADiskEjectOptions(kDADiskEjectOptionDefault), { _, dissenter, ctx in
                let box = Unmanaged<Box>.fromOpaque(ctx!).takeRetainedValue()
                box.continuation.resume(returning: Ejector.failure(from: dissenter))
            }, box)
        }
    }
}
