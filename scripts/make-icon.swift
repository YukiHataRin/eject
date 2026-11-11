// 產生 App 圖示：漸層圓角方塊 + 白色退出符號。
// 用法：swift scripts/make-icon.swift <輸出的 .iconset 資料夾>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    // macOS 圖示規格：1024 畫布上 824 的圓角方塊
    let inset = s * 100 / 1024
    let rect = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let path = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)

    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowBlurRadius = s * 0.025
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.012)
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    NSColor.black.setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGradient(colors: [
        NSColor(red: 0.30, green: 0.33, blue: 0.98, alpha: 1),
        NSColor(red: 0.42, green: 0.45, blue: 1.00, alpha: 1),
        NSColor(red: 0.20, green: 0.78, blue: 0.98, alpha: 1),
    ])!.draw(in: path, angle: -55)

    // 上方高光
    NSGraphicsContext.saveGraphicsState()
    path.addClip()
    let gloss = NSBezierPath(ovalIn: NSRect(x: rect.minX - rect.width * 0.2, y: rect.midY + rect.height * 0.05,
                                            width: rect.width * 1.4, height: rect.height * 0.9))
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.28), NSColor.white.withAlphaComponent(0.0)])!
        .draw(in: gloss, angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    // 退出符號
    let config = NSImage.SymbolConfiguration(pointSize: s * 0.40, weight: .bold)
    if let symbol = NSImage(systemSymbolName: "eject.fill", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
        let tinted = NSImage(size: symbol.size, flipped: false) { r in
            symbol.draw(in: r)
            NSColor.white.set()
            r.fill(using: .sourceAtop)
            return true
        }
        let sz = symbol.size
        let target = NSRect(x: (s - sz.width) / 2, y: (s - sz.height) / 2 + s * 0.01, width: sz.width, height: sz.height)
        let glyphShadow = NSShadow()
        glyphShadow.shadowColor = NSColor(red: 0.1, green: 0.1, blue: 0.5, alpha: 0.35)
        glyphShadow.shadowBlurRadius = s * 0.02
        glyphShadow.shadowOffset = NSSize(width: 0, height: -s * 0.01)
        NSGraphicsContext.saveGraphicsState()
        glyphShadow.set()
        tinted.draw(in: target)
        NSGraphicsContext.restoreGraphicsState()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! render(base * scale).write(to: out.appendingPathComponent(name))
    }
}
print("ok")
