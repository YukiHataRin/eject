import AppKit
import SwiftUI

/// 退出失敗時跳出的浮動視窗。用 AppKit 管理，選單列面板關掉也不會跟著消失。
@MainActor
final class BlockerWindowController: NSObject, NSWindowDelegate {
    private unowned let model: AppModel
    private var window: NSWindow?
    private(set) var volumeID: String?

    init(model: AppModel) {
        self.model = model
    }

    func show(volume: VolumeInfo) {
        volumeID = volume.id
        let root = BlockerSheet(volume: volume) { [weak self] in self?.close() }
            .environment(model)

        if let window {
            (window.contentViewController as? NSHostingController<AnyView>)?.rootView = AnyView(root)
        } else {
            let hosting = NSHostingController(rootView: AnyView(root))
            hosting.sizingOptions = [.preferredContentSize]
            let w = NSWindow(contentViewController: hosting)
            w.styleMask = [.titled, .closable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.isOpaque = false
            w.backgroundColor = .clear
            w.level = .floating
            w.isReleasedWhenClosed = false
            w.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            w.standardWindowButton(.miniaturizeButton)?.isHidden = true
            w.standardWindowButton(.zoomButton)?.isHidden = true
            w.delegate = self
            window = w
            model.panelDidAppear()
        }
        window?.title = "無法退出「\(volume.name)」"
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func closeIfShowing(_ id: String) {
        if volumeID == id { close() }
    }

    func close() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        volumeID = nil
        model.panelDidDisappear()
    }
}

// MARK: - 視窗內容

struct BlockerSheet: View {
    @Environment(AppModel.self) private var model
    let volume: VolumeInfo
    let dismiss: () -> Void
    @State private var confirmForce = false
    @State private var shake = false

    private var related: [VolumeInfo] { [volume] + model.siblings(of: volume) }
    private var blockers: [BlockerGroup] { related.flatMap(model.blockers(for:)) }
    private var locks: [GitLockWarning] { related.flatMap(model.gitLocks(for:)) }
    private var failure: EjectFailure? { model.failures[volume.id] }
    private var phase: EjectPhase { model.phase(for: volume) }
    private var stillMounted: Bool { model.volumes.contains { $0.id == volume.id } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            hero

            if !locks.isEmpty { GitLockBanner(locks: locks) }

            if blockers.isEmpty {
                nothingVisible
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            } else {
                list
            }

            if !model.siblings(of: volume).isEmpty {
                InlineBanner(symbol: "square.stack.3d.up.fill", tint: Palette.accentA,
                             text: "同一個裝置上的「\(model.siblings(of: volume).map(\.name).joined(separator: "」「"))」也會一起退出")
            }

            footer
        }
        .padding(.horizontal, 22)
        .padding(.top, 34)
        .padding(.bottom, 20)
        .frame(width: 470)
        .background(VisualEffectBackground(material: .hudWindow).ignoresSafeArea())
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.55).ignoresSafeArea())
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: blockers)
        .onChange(of: stillMounted) { _, mounted in if !mounted { dismiss() } }
    }

    // MARK: - 標題

    private var hero: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack(alignment: .bottomTrailing) {
                Image(nsImage: IconCache.icon(forPath: volume.mountPath))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 58, height: 58)
                    .shadow(color: .black.opacity(0.2), radius: 5, y: 2)
                Image(systemName: blockers.isEmpty && failure == nil ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(.system(size: 21))
                    .foregroundStyle(.white, blockers.isEmpty && failure == nil ? Palette.safe : Palette.danger)
                    .background(Circle().fill(.background).padding(2))
                    .offset(x: 4, y: 4)
                    .contentTransition(.symbolEffect(.replace))
            }
            .modifier(Shake(animatableData: shake ? 1 : 0))

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 17, weight: .bold))
                    .lineLimit(2)
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear {
            if failure != nil { withAnimation(.linear(duration: 0.45)) { shake = true } }
        }
    }

    private var title: String {
        if blockers.isEmpty && locks.isEmpty && failure == nil { return "「\(volume.name)」可以退出了" }
        return "「\(volume.name)」正在使用中"
    }

    private var message: String {
        if !blockers.isEmpty {
            return "結束下列 \(blockers.count) 個程式後就能安全退出。尚未儲存的工作可能會遺失。"
        }
        if !locks.isEmpty { return "沒有程式占用，但有 git 操作還沒結束。" }
        if failure != nil { return failure!.friendlyMessage + "，但找不到是哪個程式。" }
        return "已經沒有程式在使用這顆磁碟。"
    }

    // MARK: - 列表

    private var list: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(Array(blockers.enumerated()), id: \.element.id) { index, g in
                    if index > 0 { Divider().opacity(0.5).padding(.leading, 56) }
                    BlockerRow(group: g, volumeRoot: volume.mountPath, state: model.groupStates[g.id], detailed: true) { force in
                        Task { await model.terminate(g, force: force) }
                    }
                    .transition(.asymmetric(insertion: .opacity, removal: .move(edge: .leading).combined(with: .opacity)))
                }
            }
            .padding(4)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxHeight: 340)
        .fixedSize(horizontal: false, vertical: true)
        .card()
    }

    private var nothingVisible: some View {
        Group {
            if failure != nil {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "eye.slash.circle.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(.secondary)
                        .symbolRenderingMode(.hierarchical)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("看不到占用的程式").font(.system(size: 12.5, weight: .semibold))
                        Text("可能是系統程序，例如 Spotlight 正在建立索引、Time Machine 正在備份，或 Finder 正在複製檔案。稍候幾秒再試，或使用強制退出。")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let raw = failure?.message, !raw.isEmpty {
                            Text(raw).font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                        }
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .card()
            }
        }
    }

    // MARK: - 按鈕

    private var footer: some View {
        HStack(spacing: 10) {
            if confirmForce {
                Text("強制退出可能讓寫入中的檔案損壞，確定嗎？")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.danger)
                    .transition(.opacity.combined(with: .move(edge: .leading)))
                Spacer()
                Button("取消") { withAnimation(.snappy) { confirmForce = false } }
                    .buttonStyle(PillButtonStyle(tint: .secondary, prominent: false))
                Button("強制退出") {
                    model.eject(volume, force: true)
                }
                .buttonStyle(PillButtonStyle(tint: Palette.danger))
            } else {
                Button("強制退出…") { withAnimation(.snappy) { confirmForce = true } }
                    .buttonStyle(PillButtonStyle(tint: Palette.danger, prominent: false))
                    .disabled(phase != .idle)
                Spacer()
                Button("取消") { dismiss() }
                    .buttonStyle(PillButtonStyle(tint: .secondary, prominent: false))
                    .keyboardShortcut(.cancelAction)
                primary
            }
        }
        .animation(.snappy, value: confirmForce)
    }

    @ViewBuilder
    private var primary: some View {
        let working = phase != .idle
        Button {
            if blockers.isEmpty {
                model.failures[volume.id] = nil
                model.eject(volume, precheck: false)
            } else {
                Task { await model.terminateAllAndEject(volume) }
            }
        } label: {
            HStack(spacing: 6) {
                if working {
                    ProgressView().controlSize(.small).scaleEffect(0.7).tint(.white)
                } else {
                    Image(systemName: "eject.fill")
                }
                Text(primaryTitle).contentTransition(.numericText())
            }
        }
        .buttonStyle(PillButtonStyle(tint: blockers.isEmpty ? Palette.accentA : Palette.busy))
        .keyboardShortcut(.defaultAction)
        .disabled(working)
    }

    private var primaryTitle: String {
        switch phase {
        case .checking: return "檢查中…"
        case .terminating: return "正在結束…"
        case .ejecting: return "正在退出…"
        case .idle: break
        }
        if blockers.isEmpty { return locks.isEmpty ? (failure == nil ? "退出" : "再試一次") : "仍要退出" }
        return blockers.count == 1 ? "結束並退出" : "結束全部並退出"
    }
}

/// 退出失敗時讓圖示左右晃一下。
private struct Shake: GeometryEffect {
    var animatableData: CGFloat
    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 6 * sin(animatableData * .pi * 6), y: 0))
    }
}
