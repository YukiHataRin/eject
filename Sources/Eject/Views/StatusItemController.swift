import AppKit
import Observation
import SwiftUI

/// 自己管理選單列圖示與下拉面板。
///
/// SwiftUI 的 `MenuBarExtra(.window)` 只在第一次顯示時決定視窗大小，內容高度變了
/// （例如拔掉磁碟變成空狀態）視窗不會跟著調整，內容就會被裁掉又無法捲動。
/// 這裡改用 NSPanel，隨 SwiftUI 內容的理想大小即時調整，並限制在螢幕可用高度內。
@MainActor
final class StatusItemController: NSObject, NSWindowDelegate {
    private let model: AppModel
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let layout = PanelLayout()
    private var panel: StatusPanel?
    private var hosting: NSHostingController<AnyView>?
    private var sizeObservation: NSKeyValueObservation?
    private var clickMonitor: Any?
    private var keyMonitor: Any?
    /// 點選單列圖示時面板可能先因失焦而收起，避免緊接著又被打開。
    private var lastHide = Date.distantPast

    private static let cornerRadius: CGFloat = 14

    init(model: AppModel) {
        self.model = model
        super.init()
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(toggle)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        trackIcon()
    }

    // MARK: - 選單列圖示

    /// 跟著 model 狀態更新圖示（withObservationTracking 只觸發一次，所以每次重新註冊）。
    private func trackIcon() {
        let symbol = withObservationTracking {
            Self.symbolName(for: model)
        } onChange: { [weak self] in
            Task { @MainActor in self?.trackIcon() }
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Eject")
        image?.isTemplate = true
        statusItem.button?.image = image
    }

    private static func symbolName(for model: AppModel) -> String {
        if model.volumes.isEmpty { return "externaldrive" }
        if model.phases.values.contains(where: { $0 != .idle }) { return "eject.circle.fill" }
        if model.busyCount > 0 { return "externaldrive.fill.badge.exclamationmark" }
        return "externaldrive.fill"
    }

    // MARK: - 顯示／隱藏

    @objc private func toggle() {
        if panel?.isVisible == true {
            hide()
        } else if Date().timeIntervalSince(lastHide) > 0.25 {
            show()
        }
    }

    private func show() {
        let panel = panel ?? makePanel()
        updateMaxHeight()
        hosting?.view.layoutSubtreeIfNeeded()
        reposition(animated: false)

        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.14
            panel.animator().alphaValue = 1
        }
        statusItem.button?.highlight(true)
        model.panelDidAppear()

        // 點面板外面、按 Esc 就收起來
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53, self?.panel?.isKeyWindow == true else { return event }
            MainActor.assumeIsolated { self?.hide() }
            return nil
        }
    }

    private func hide() {
        guard let panel, panel.isVisible else { return }
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        clickMonitor = nil
        keyMonitor = nil
        statusItem.button?.highlight(false)
        lastHide = Date()
        panel.orderOut(nil)
        model.panelDidDisappear()
    }

    func windowDidResignKey(_ notification: Notification) {
        // 切到其他 App（或點了失敗視窗）就收起，行為跟系統選單一致
        hide()
    }

    // MARK: - 除錯

    /// `--panel-test <資料夾>`：打開面板，每秒記錄一次面板與內容大小並截圖。
    func runPanelTest(dir: String, seconds: Int) {
        show()
        Task { @MainActor in
            for i in 0..<seconds {
                try? await Task.sleep(for: .seconds(1))
                guard let panel, let hosting, let view = panel.contentView else { continue }
                let ideal = hosting.preferredContentSize
                print(String(format: "t=%02d panel=%.0fx%.0f ideal=%.0fx%.0f volumes=%d max=%.0f",
                             i, panel.frame.width, panel.frame.height, ideal.width, ideal.height,
                             model.volumes.count, layout.maxPanelHeight))
                fflush(stdout)
                if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?
                        .write(to: URL(fileURLWithPath: dir).appendingPathComponent(String(format: "t%02d.png", i)))
                }
            }
            NSApp.terminate(nil)
        }
    }

    // MARK: - 面板

    private func makePanel() -> StatusPanel {
        let root = MenuPanel()
            .environment(model)
            .environment(layout)
        let hosting = NSHostingController(rootView: AnyView(root))
        hosting.sizingOptions = [.preferredContentSize]

        // 圓角毛玻璃背景，SwiftUI 內容放在上面
        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = Self.cornerRadius
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 0.5
        effect.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor

        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(hosting.view)
        NSLayoutConstraint.activate([
            hosting.view.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            hosting.view.topAnchor.constraint(equalTo: effect.topAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])

        let panel = StatusPanel(
            contentRect: NSRect(origin: .zero, size: CGSize(width: 360, height: 200)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.contentView = effect
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.delegate = self

        // SwiftUI 內容高度一變就調整面板，頂端固定在選單列下方
        sizeObservation = hosting.observe(\.preferredContentSize, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.reposition(animated: true) }
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(screenChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)

        self.hosting = hosting
        self.panel = panel
        return panel
    }

    @objc private func screenChanged() {
        updateMaxHeight()
        reposition(animated: false)
    }

    /// 選單列下方到螢幕底部可用的高度，交給 SwiftUI 決定列表最多能多高。
    private func updateMaxHeight() {
        let screen = statusItem.button?.window?.screen ?? NSScreen.main
        let visible = screen?.visibleFrame.height ?? 800
        layout.maxPanelHeight = max(visible - 24, 240)
        // 除錯用：模擬較矮的螢幕，驗證列表會捲動而不是被裁掉
        if let raw = ProcessInfo.processInfo.environment["EJECT_DEBUG_MAX_HEIGHT"], let h = Double(raw) {
            layout.maxPanelHeight = h
        }
    }

    private func reposition(animated: Bool) {
        guard let panel, let hosting,
              let buttonWindow = statusItem.button?.window else { return }
        let screen = buttonWindow.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero

        var size = hosting.preferredContentSize
        if size.width < 1 || size.height < 1 { size = hosting.view.fittingSize }
        size.height = min(size.height, layout.maxPanelHeight)

        let anchor = buttonWindow.frame
        var x = anchor.midX - size.width / 2
        x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
        let top = anchor.minY - 6
        let frame = NSRect(x: x, y: top - size.height, width: size.width, height: size.height)

        guard panel.frame != frame else { return }
        panel.setFrame(frame, display: true, animate: animated && panel.isVisible)
    }
}

/// 無邊框面板預設不能成為 key window，按鈕的 hover 與鍵盤就不會動，所以要覆寫。
final class StatusPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// 面板可用的最大高度，由 StatusItemController 依螢幕大小設定。
@MainActor
@Observable
final class PanelLayout {
    var maxPanelHeight: CGFloat = 700
}
