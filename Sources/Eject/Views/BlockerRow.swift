import SwiftUI

struct BlockerRow: View {
    let group: BlockerGroup
    let volumeRoot: String
    let state: GroupState?
    var detailed: Bool = false
    let onTerminate: (_ force: Bool) -> Void

    @State private var hovering = false
    @State private var showFiles = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                BlockerIcon(group: group, size: detailed ? 34 : 28)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(group.displayName)
                            .font(.system(size: detailed ? 13 : 12.5, weight: .semibold))
                            .lineLimit(1)
                        if let project = group.devServer?.project {
                            Chip(text: project, systemImage: "folder.fill", tint: Palette.accentA)
                        }
                        if group.runsFromVolume {
                            Chip(text: "從此碟執行", tint: Palette.busy)
                        }
                    }
                    Text(subtitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                trailing
            }

            if detailed, !paths.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(paths.prefix(showFiles ? 40 : 3), id: \.self) { item in
                        HStack(spacing: 5) {
                            Image(systemName: item.isDirectory ? "folder" : "doc")
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                                .frame(width: 11)
                            Text(Format.relative(item.path, to: volumeRoot))
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                    }
                    if paths.count > 3 {
                        Button(showFiles ? "收合" : "還有 \(paths.count - 3) 個…") {
                            withAnimation(.snappy) { showFiles.toggle() }
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Palette.accentA)
                    }
                }
                .padding(.leading, 44)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, detailed ? 12 : 8)
        .padding(.vertical, detailed ? 10 : 6)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.primary.opacity(hovering ? 0.05 : 0))
        }
        .opacity(state == .terminated ? 0.5 : 1)
        .onHover { h in withAnimation(.snappy(duration: 0.15)) { hovering = h } }
        .help(helpText)
    }

    private struct PathItem: Hashable {
        let path: String
        let isDirectory: Bool
    }

    private var paths: [PathItem] {
        group.workingDirectories.map { PathItem(path: $0, isDirectory: true) }
            + group.openFiles.map { PathItem(path: $0, isDirectory: false) }
    }

    private var subtitle: String {
        var parts: [String] = []
        if !group.isApp {
            if group.devServer != nil || group.isShell { parts.append(group.processes.first?.name ?? "") }
            if let host = group.hostAppName { parts.append("在 \(host) 中") }
        }
        parts.append(group.summary)
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private var helpText: String {
        let files = group.openFiles.prefix(8).map { Format.relative($0, to: volumeRoot) }
        let dirs = group.workingDirectories.map { "📁 " + Format.relative($0, to: volumeRoot) }
        return (dirs + files).joined(separator: "\n")
    }

    @ViewBuilder
    private var trailing: some View {
        switch state {
        case .terminating:
            ProgressView().controlSize(.small).frame(width: 52)
        case .terminated:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 15))
                .foregroundStyle(Palette.safe)
                .frame(width: 52)
                .transition(.scale.combined(with: .opacity))
        case .notPermitted:
            Label("無權限", systemImage: "lock.fill")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
                .help("這是其他使用者或系統的程序，需要系統管理員權限才能結束")
        case .waitingForApp:
            VStack(alignment: .trailing, spacing: 2) {
                Button("強制結束") { onTerminate(true) }
                    .buttonStyle(PillButtonStyle(tint: Palette.danger, prominent: true, compact: true))
                Text("App 沒有回應").font(.system(size: 9)).foregroundStyle(.secondary)
            }
        case nil:
            Button(group.isApp ? "結束 App" : "結束") { onTerminate(false) }
                .buttonStyle(PillButtonStyle(tint: Palette.danger, prominent: false, compact: true))
                .opacity(hovering || detailed ? 1 : 0.85)
                .help(group.isApp ? "正常結束 \(group.displayName)，有未儲存的文件時 App 會先詢問" : "送出 SIGTERM，3 秒內沒結束就送 SIGKILL")
        }
    }
}
