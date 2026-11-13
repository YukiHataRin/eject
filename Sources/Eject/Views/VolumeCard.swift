import SwiftUI

struct VolumeCard: View {
    @Environment(AppModel.self) private var model
    let volume: VolumeInfo
    @State private var hovering = false

    private var blockers: [BlockerGroup] { model.blockers(for: volume) }
    private var locks: [GitLockWarning] { model.gitLocks(for: volume) }
    private var phase: EjectPhase { model.phase(for: volume) }
    private var failure: EjectFailure? { model.failures[volume.id] }
    private var isExpanded: Bool { model.expanded.contains(volume.id) }

    private var statusColor: Color {
        if failure != nil { return Palette.danger }
        return blockers.isEmpty ? Palette.safe : Palette.busy
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(12)

            if !blockers.isEmpty && isExpanded {
                Divider().opacity(0.5).padding(.horizontal, 12)
                blockerList
                    .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
            }
        }
        .card(highlighted: hovering, tint: blockers.isEmpty && failure == nil ? nil : statusColor)
        .onHover { h in withAnimation(.snappy(duration: 0.18)) { hovering = h } }
        .contextMenu { contextMenu }
    }

    // MARK: - 上半部

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 11) {
                Image(nsImage: IconCache.icon(forPath: volume.mountPath))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 40, height: 40)
                    .shadow(color: .black.opacity(0.18), radius: 3, y: 1.5)

                VStack(alignment: .leading, spacing: 2) {
                    Text(volume.name)
                        .font(.system(size: 13.5, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(volume.metaLine)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                EjectButton(phase: phase) { model.eject(volume) }
            }

            if volume.totalBytes > 0 {
                VStack(alignment: .leading, spacing: 4) {
                    CapacityBar(fraction: volume.usedFraction)
                    HStack {
                        Text("已用 \(Format.bytes(volume.usedBytes))")
                        Spacer()
                        Text("可用 \(Format.bytes(volume.availableBytes)) / \(Format.bytes(volume.totalBytes))")
                    }
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.tertiary)
                }
            }

            statusRow

            if !locks.isEmpty {
                GitLockBanner(locks: locks)
            }
            if model.appRunsFrom(volume) {
                InlineBanner(symbol: "exclamationmark.triangle.fill", tint: Palette.busy,
                             text: "Eject 本身從這顆碟執行，請先把 App 移到「應用程式」資料夾")
            }
        }
    }

    private var statusRow: some View {
        Button {
            guard !blockers.isEmpty else { return }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                if isExpanded { model.expanded.remove(volume.id) } else { model.expanded.insert(volume.id) }
            }
        } label: {
            HStack(spacing: 7) {
                StatusDot(color: statusColor, pulsing: !blockers.isEmpty || phase != .idle)
                Text(statusText)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(blockers.isEmpty && failure == nil ? Color.secondary : statusColor)
                    .contentTransition(.numericText())
                Spacer()
                if !blockers.isEmpty {
                    HStack(spacing: -6) {
                        ForEach(blockers.prefix(4)) { g in
                            BlockerIcon(group: g, size: 18)
                                .background(Circle().fill(.background).padding(-1).opacity(0))
                        }
                    }
                    .opacity(isExpanded ? 0 : 1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var statusText: String {
        switch phase {
        case .checking: return "檢查中…"
        case .terminating: return "正在結束程序…"
        case .ejecting: return "正在退出…"
        case .idle: break
        }
        if let failure, blockers.isEmpty { return failure.friendlyMessage }
        if blockers.isEmpty { return "可以安全退出" }
        let count = blockers.count
        return count == 1 ? "\(blockers[0].displayName) 正在使用" : "\(count) 個程式正在使用"
    }

    // MARK: - 占用者列表

    private var blockerList: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(blockers) { g in
                BlockerRow(group: g, volumeRoot: volume.mountPath, state: model.groupStates[g.id]) { force in
                    Task { await model.terminate(g, force: force) }
                }
            }
            Button {
                Task { await model.terminateAllAndEject(volume) }
            } label: {
                Label(blockers.count == 1 ? "結束並退出" : "結束全部 \(blockers.count) 個並退出", systemImage: "eject.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(PillButtonStyle(tint: Palette.busy))
            .disabled(phase != .idle)
            .padding(.top, 6)
            .padding(.horizontal, 4)
        }
        .padding(8)
    }

    @ViewBuilder
    private var contextMenu: some View {
        Button("在 Finder 中顯示") { model.reveal(volume) }
        Button("顯示占用詳情…") { model.presentBlockers(for: volume) }
        Divider()
        Button("退出") { model.eject(volume) }
        Button("強制退出") { model.eject(volume, force: true) }
    }
}

// MARK: - 警示橫幅

struct InlineBanner: View {
    let symbol: String
    let tint: Color
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: symbol).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(tint)
            Text(text).font(.system(size: 10.5)).foregroundStyle(.primary.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(tint.opacity(0.12)))
    }
}

struct GitLockBanner: View {
    let locks: [GitLockWarning]

    var body: some View {
        InlineBanner(
            symbol: "arrow.triangle.branch",
            tint: Color.yellow,
            text: "\(locks.map(\.repoName).joined(separator: "、")) 有 git 操作進行中（.git/index.lock），現在退出可能損壞儲存庫")
    }
}
