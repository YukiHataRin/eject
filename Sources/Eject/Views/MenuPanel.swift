import SwiftUI

struct MenuPanel: View {
    @Environment(AppModel.self) private var model
    /// 由 StatusItemController 提供；預覽視窗裡沒有時用預設值。
    @Environment(PanelLayout.self) private var layout: PanelLayout?
    @State private var listHeight: CGFloat = 0

    /// 標題、底部列與提示以外，留給磁碟列表的最大高度。
    private var maxListHeight: CGFloat {
        let chrome: CGFloat = 140 + (model.toast == nil ? 0 : 64)
        return max((layout?.maxPanelHeight ?? 700) - chrome, 160)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 14)
                .padding(.top, 13)
                .padding(.bottom, 10)

            if let toast = model.toast {
                ToastView(toast: toast)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                    .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity),
                                            removal: .opacity.combined(with: .scale(scale: 0.96))))
            }

            if model.volumes.isEmpty {
                EmptyState()
                    .padding(.vertical, 26)
                    .transition(.opacity)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(model.volumes) { v in
                            VolumeCard(volume: v)
                                .transition(.asymmetric(insertion: .scale(scale: 0.95).combined(with: .opacity),
                                                        removal: .move(edge: .trailing).combined(with: .opacity)))
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 2)
                    .background {
                        GeometryReader { geo in
                            Color.clear.preference(key: ContentHeightKey.self, value: geo.size.height)
                        }
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
                .scrollIndicators(listHeight > maxListHeight ? .automatic : .never)
                // 用量到的內容高度決定 ScrollView 高度：內容少時剛好包住，超過螢幕時才捲動
                .frame(height: min(max(listHeight, 1), maxListHeight))
                .onPreferenceChange(ContentHeightKey.self) { h in
                    MainActor.assumeIsolated { listHeight = h }
                }
            }

            footer
        }
        .frame(width: 360)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Palette.accentGradient)
                    .shadow(color: Palette.accentA.opacity(0.4), radius: 5, y: 2)
                Image(systemName: "eject.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 1) {
                Text("外接磁碟")
                    .font(.system(size: 14, weight: .bold))
                Text(subtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }

            Spacer()

            IconButton(systemImage: "arrow.clockwise", help: "重新掃描", spinning: model.isScanning) {
                Task { await model.rescan() }
            }
            if model.volumes.count > 1 {
                Button {
                    model.ejectAll()
                } label: {
                    Label("全部退出", systemImage: "eject.fill")
                }
                .buttonStyle(PillButtonStyle(tint: Palette.accentA, prominent: true, compact: true))
            }
        }
    }

    private var subtitle: String {
        let n = model.volumes.count
        guard n > 0 else { return "沒有連接任何外接磁碟" }
        let busy = model.busyCount
        if busy == 0 { return "\(n) 個宗卷 · 全部可以安全退出" }
        return "\(n) 個宗卷 · \(busy) 個正在使用中"
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Toggle(isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) })) {
                Text("登入時啟動").font(.system(size: 11))
            }
            .toggleStyle(.switch)
            .controlSize(.mini)

            Spacer()

            if let last = model.lastScan {
                TimelineView(.periodic(from: .now, by: 5)) { _ in
                    Text(last, format: .relative(presentation: .named))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }

            Button("結束") { NSApp.terminate(nil) }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .keyboardShortcut("q")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.primary.opacity(0.03))
        .overlay(alignment: .top) { Divider().opacity(0.6) }
        .padding(.top, 10)
    }
}

// MARK: - 空狀態

private struct EmptyState: View {
    @State private var float = false

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(Palette.accentGradient.opacity(0.14))
                    .frame(width: 74, height: 74)
                    .scaleEffect(float ? 1.06 : 0.96)
                Image(systemName: "externaldrive.badge.checkmark")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(Palette.accentGradient)
                    .symbolRenderingMode(.hierarchical)
                    .offset(y: float ? -2 : 2)
            }
            .onAppear {
                withAnimation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true)) { float = true }
            }
            Text("沒有外接磁碟")
                .font(.system(size: 13, weight: .semibold))
            Text("接上隨身碟、外接硬碟或掛載映像檔後，會出現在這裡。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 240)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - 成功提示

private struct ToastView: View {
    let toast: EjectedToast
    @State private var pop = false

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 18))
                .foregroundStyle(.white, Palette.safe)
                .scaleEffect(pop ? 1 : 0.4)
                .onAppear { withAnimation(.spring(response: 0.4, dampingFraction: 0.5)) { pop = true } }
            VStack(alignment: .leading, spacing: 1) {
                Text("已退出「\(toast.name)」").font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Text(toast.detail).font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(LinearGradient(colors: [Palette.safe.opacity(0.22), Palette.safe.opacity(0.08)],
                                     startPoint: .leading, endPoint: .trailing))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.safe.opacity(0.35), lineWidth: 0.6)
        }
    }
}

private struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
