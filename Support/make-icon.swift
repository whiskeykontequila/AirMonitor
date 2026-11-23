// Renders the app icon (same design the app uses for its Dock icon) into an .iconset folder.
// build.sh turns it into AppIcon.icns with `iconutil`.
//
// Usage: swift Support/make-icon.swift <output.iconset>
import AppKit

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"

func color(_ rgb: Int) -> NSColor {
    NSColor(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1)
}

func drawIcon(size: CGFloat) {
    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    let tile = rect.insetBy(dx: size * 0.1, dy: size * 0.1)
    let path = NSBezierPath(roundedRect: tile, xRadius: size * 0.18, yRadius: size * 0.18)
    NSGradient(colors: [color(0x2E86DE), color(0x50CCAA)])?.draw(in: path, angle: 90)

    let config = NSImage.SymbolConfiguration(pointSize: size * 0.36, weight: .semibold)
        .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
    if let symbol = NSImage(systemSymbolName: "aqi.medium", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let s = symbol.size
        symbol.draw(in: NSRect(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2,
                               width: s.width, height: s.height))
    }
}

func png(pixels: Int) -> Data? {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    drawIcon(size: CGFloat(pixels))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

let variants: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

try MainActor.assumeIsolated {
    try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
    for v in variants {
        guard let data = png(pixels: v.pixels) else {
            FileHandle.standardError.write("Couldn't render \(v.name)\n".data(using: .utf8)!)
            exit(1)
        }
        try data.write(to: URL(fileURLWithPath: output).appendingPathComponent(v.name + ".png"))
    }
}
print("Icon written to \(output)")
