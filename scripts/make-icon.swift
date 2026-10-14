// Renders the app icon at every size macOS wants. Run via scripts/make-icon.sh.
import AppKit

func render(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let s = size / 1024
    // Standard macOS icon grid: 824pt tile centred in 1024.
    let tile = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let shape = NSBezierPath(roundedRect: tile, xRadius: 185 * s, yRadius: 185 * s)
    NSGradient(colors: [NSColor(white: 0.16, alpha: 1), NSColor(white: 0.02, alpha: 1)])!
        .draw(in: shape, angle: -90)

    // Tick slider.
    let tickTop = tile.maxY - 190 * s
    let tickHeight = 110 * s
    var x = tile.minX + 90 * s
    NSColor(white: 1, alpha: 0.28).setFill()
    while x < tile.maxX - 90 * s {
        NSRect(x: x, y: tickTop - tickHeight, width: 6 * s, height: tickHeight).fill()
        x += 18 * s
    }
    NSColor.white.setFill()
    NSBezierPath(
        roundedRect: NSRect(x: tile.minX + 330 * s, y: tickTop - tickHeight - 14 * s, width: 14 * s, height: tickHeight + 28 * s),
        xRadius: 7 * s, yRadius: 7 * s
    ).fill()

    // Big clock.
    let text = "25:00" as NSString
    let font = NSFont.monospacedDigitSystemFont(ofSize: 250 * s, weight: .light)
    let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
    let textSize = text.size(withAttributes: attributes)
    text.draw(at: NSPoint(x: tile.midX - textSize.width / 2, y: tile.minY + 120 * s), withAttributes: attributes)

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        let png = render(size: CGFloat(base * scale)).representation(using: .png, properties: [:])!
        try! png.write(to: URL(fileURLWithPath: out).appendingPathComponent(name))
    }
}
