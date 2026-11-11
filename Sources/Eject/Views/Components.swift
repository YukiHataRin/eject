import AppKit
import SwiftUI

// MARK: - 色彩

enum Palette {
    static let safe = Color(red: 0.20, green: 0.78, blue: 0.53)
    static let busy = Color(red: 1.00, green: 0.62, blue: 0.20)
    static let danger = Color(red: 1.00, green: 0.33, blue: 0.36)
    static let accentA = Color(red: 0.36, green: 0.42, blue: 1.00)
    static let accentB = Color(red: 0.22, green: 0.76, blue: 0.98)

    static let accentGradient = LinearGradient(colors: [accentA, accentB], startPoint: .topLeading, endPoint: .bottomTrailing)

    static func capacityGradient(_ fraction: Double) -> LinearGradient {
        if fraction > 0.9 { return LinearGradient(colors: [busy, danger], startPoint: .leading, endPoint: .trailing) }
        if fraction > 0.75 { return LinearGradient(colors: [Color.yellow, busy], startPoint: .leading, endPoint: .trailing) }
        return LinearGradient(colors: [accentA, accentB], startPoint: .leading, endPoint: .trailing)
    }
}

// MARK: - 圖示快取

@MainActor
enum IconCache {
    private static var cache: [String: NSImage] = [:]

    static func icon(forPath path: String) -> NSImage {
        if let hit = cache[path] { return hit }
        let image = NSWorkspace.shared.icon(forFile: path)
        cache[path] = image
        return image
    }
}

// MARK: - 狀態燈

struct StatusDot: View {
    let color: Color
    var pulsing: Bool = false
    @State private var animate = false

    var body: some View {
        ZStack {
            if pulsing {
                Circle()
                    .stroke(color.opacity(0.55), lineWidth: 1.5)
                    .scaleEffect(animate ? 2.3 : 1)
                    .opacity(animate ? 0 : 1)
            }
            Circle()
                .fill(color.gradient)
                .shadow(color: color.opacity(0.7), radius: 3)
        }
        .frame(width: 7, height: 7)
        .onAppear { startIfNeeded() }
        .onChange(of: pulsing) { _, _ in startIfNeeded() }
    }

    private func startIfNeeded() {
        animate = false
        guard pulsing else { return }
        withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { animate = true }
    }
}

// MARK: - 容量條

struct CapacityBar: View {
    let fraction: Double
    @State private var shown: Double = 0

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(Palette.capacityGradient(fraction))
                    .frame(width: max(geo.size.width * shown, shown > 0 ? 6 : 0))
                    .shadow(color: Palette.accentA.opacity(0.25), radius: 3, y: 1)
            }
        }
        .frame(height: 5)
        .onAppear {
            withAnimation(.spring(response: 0.9, dampingFraction: 0.85).delay(0.05)) { shown = fraction }
        }
        .onChange(of: fraction) { _, new in
            withAnimation(.spring(response: 0.6, dampingFraction: 0.85)) { shown = new }
        }
    }
}

// MARK: - 小標籤

struct Chip: View {
    let text: String
    var systemImage: String? = nil
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 3) {
            if let systemImage { Image(systemName: systemImage).font(.system(size: 8, weight: .bold)) }
            Text(text).lineLimit(1)
        }
        .font(.system(size: 9.5, weight: .semibold))
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .foregroundStyle(tint)
        .background(Capsule().fill(tint.opacity(0.13)))
    }
}

// MARK: - 退出按鈕

struct EjectButton: View {
    let phase: EjectPhase
    let action: () -> Void
    @State private var hovering = false

    private var working: Bool { phase != .idle }

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(hovering && !working ? AnyShapeStyle(Palette.accentGradient) : AnyShapeStyle(Color.primary.opacity(0.07)))
                Circle()
                    .strokeBorder(Color.primary.opacity(hovering ? 0 : 0.08), lineWidth: 0.5)
                if working {
                    ProgressView().controlSize(.small).scaleEffect(0.75)
                } else {
                    Image(systemName: "eject.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(hovering ? Color.white : Color.primary.opacity(0.75))
                        .offset(y: -0.5)
                }
            }
            .frame(width: 30, height: 30)
            .shadow(color: hovering && !working ? Palette.accentA.opacity(0.45) : .clear, radius: 6, y: 2)
            .scaleEffect(hovering && !working ? 1.06 : 1)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(working)
        .onHover { h in withAnimation(.snappy(duration: 0.18)) { hovering = h } }
        .help(working ? "處理中…" : "退出")
    }
}

// MARK: - 按鈕樣式

struct PillButtonStyle: ButtonStyle {
    var tint: Color = Palette.accentA
    var prominent: Bool = true
    var compact: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        PillBody(configuration: configuration, tint: tint, prominent: prominent, compact: compact)
    }

    private struct PillBody: View {
        let configuration: Configuration
        let tint: Color
        let prominent: Bool
        let compact: Bool
        @Environment(\.isEnabled) private var enabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: compact ? 11 : 12, weight: .semibold))
                .padding(.horizontal, compact ? 9 : 14)
                .padding(.vertical, compact ? 4 : 7)
                .foregroundStyle(prominent ? Color.white : tint)
                .background {
                    Capsule().fill(prominent
                        ? AnyShapeStyle(tint.gradient)
                        : AnyShapeStyle(tint.opacity(hovering ? 0.2 : 0.12)))
                }
                .overlay { Capsule().strokeBorder(Color.white.opacity(prominent ? 0.18 : 0), lineWidth: 0.5) }
                .shadow(color: prominent ? tint.opacity(hovering ? 0.45 : 0.25) : .clear, radius: hovering ? 7 : 4, y: 2)
                .opacity(enabled ? 1 : 0.45)
                .scaleEffect(configuration.isPressed ? 0.96 : 1)
                .brightness(hovering && prominent ? 0.04 : 0)
                .onHover { h in withAnimation(.snappy(duration: 0.15)) { hovering = h } }
                .animation(.snappy(duration: 0.12), value: configuration.isPressed)
        }
    }
}

struct IconButton: View {
    let systemImage: String
    let help: String
    var spinning: Bool = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(spinning ? 360 : 0))
                .animation(spinning ? .linear(duration: 0.9).repeatForever(autoreverses: false) : .default, value: spinning)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.primary.opacity(hovering ? 0.09 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

// MARK: - 程序圖示

struct BlockerIcon: View {
    let group: BlockerGroup
    var size: CGFloat = 28

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if let bundle = group.appBundlePath {
                Image(nsImage: IconCache.icon(forPath: bundle))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: size, height: size)
            } else {
                RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                    .fill(LinearGradient(colors: style.colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay {
                        Image(systemName: style.symbol)
                            .font(.system(size: size * 0.44, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.15), lineWidth: 0.5)
                    }
                    .frame(width: size * 0.86, height: size * 0.86)
                    .frame(width: size, height: size)

                if let host = group.hostAppPath {
                    Image(nsImage: IconCache.icon(forPath: host))
                        .resizable()
                        .frame(width: size * 0.5, height: size * 0.5)
                        .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
                        .offset(x: size * 0.1, y: size * 0.08)
                }
            }
        }
    }

    private var style: (symbol: String, colors: [Color]) {
        if group.isShell {
            return ("terminal.fill", [Color(white: 0.32), Color(white: 0.12)])
        }
        if let dev = group.devServer {
            switch dev.tool {
            case "Claude Code": return ("sparkle", [Color(red: 0.85, green: 0.47, blue: 0.34), Color(red: 0.72, green: 0.33, blue: 0.22)])
            case "Vite", "Vitest": return ("bolt.fill", [Color(red: 0.55, green: 0.38, blue: 1.0), Color(red: 1.0, green: 0.75, blue: 0.2)])
            case "Next.js": return ("n.square.fill", [Color(white: 0.25), Color.black])
            case "TS Server", "TypeScript watch": return ("chevron.left.forwardslash.chevron.right", [Color(red: 0.2, green: 0.47, blue: 0.85), Color(red: 0.1, green: 0.32, blue: 0.7)])
            case "Uvicorn", "Gunicorn", "Flask", "Django", "Jupyter", "JupyterLab", "Streamlit":
                return ("server.rack", [Color(red: 0.22, green: 0.6, blue: 0.5), Color(red: 0.1, green: 0.4, blue: 0.4)])
            default: return ("bolt.horizontal.fill", [Palette.accentA, Palette.accentB])
            }
        }
        return ("gearshape.2.fill", [Color(white: 0.55), Color(white: 0.35)])
    }
}

// MARK: - 卡片背景

struct CardBackground: ViewModifier {
    var highlighted: Bool = false
    var tint: Color? = nil

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.primary.opacity(highlighted ? 0.065 : 0.04))
                    .overlay {
                        if let tint {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(LinearGradient(colors: [tint.opacity(0.10), .clear], startPoint: .top, endPoint: .bottom))
                        }
                    }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(tint?.opacity(0.28) ?? Color.primary.opacity(0.07), lineWidth: 0.6)
            }
    }
}

extension View {
    func card(highlighted: Bool = false, tint: Color? = nil) -> some View {
        modifier(CardBackground(highlighted: highlighted, tint: tint))
    }
}

// MARK: - 視覺特效背景

struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .popover

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
    }
}

// MARK: - 格式化

enum Format {
    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    /// 把 /Volumes/X/a/b/c.txt 顯示成 a/b/c.txt
    static func relative(_ path: String, to root: String) -> String {
        guard path.hasPrefix(root) else { return path }
        let rest = path.dropFirst(root.count).drop { $0 == "/" }
        return rest.isEmpty ? "（根目錄）" : String(rest)
    }
}
