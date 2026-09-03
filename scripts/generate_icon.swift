import AppKit
import Foundation

guard CommandLine.arguments.count == 3 else {
    fputs("usage: generate_icon.swift <iconset-path> <icns-path>\n", stderr)
    exit(2)
}

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let icnsOutput = URL(fileURLWithPath: CommandLine.arguments[2])
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

let variants: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]

for (name, pixels) in variants {
    let size = NSSize(width: pixels, height: pixels)
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw NSError(domain: "GPTSwitcherIcon", code: 1)
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context

    let rect = NSRect(origin: .zero, size: size).insetBy(dx: CGFloat(pixels) * 0.06, dy: CGFloat(pixels) * 0.06)
    let radius = CGFloat(pixels) * 0.22
    let background = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    NSColor(calibratedRed: 0.08, green: 0.10, blue: 0.13, alpha: 1).setFill()
    background.fill()

    let symbolConfig = NSImage.SymbolConfiguration(pointSize: CGFloat(pixels) * 0.50, weight: .semibold)
    if let symbol = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: "Switch")?
        .withSymbolConfiguration(symbolConfig) {
        let symbolSize = symbol.size
        let target = NSRect(
            x: (CGFloat(pixels) - symbolSize.width) / 2,
            y: (CGFloat(pixels) - symbolSize.height) / 2,
            width: symbolSize.width,
            height: symbolSize.height
        )
        NSColor.white.set()
        symbol.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1)
    }

    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "GPTSwitcherIcon", code: 2)
    }
    try png.write(to: output.appendingPathComponent(name))
}

// A modern ICNS file is a big-endian container of PNG-backed icon chunks.
// Building it directly avoids iconutil differences between Xcode/macOS releases.
let chunks: [(String, String)] = [
    ("icp4", "icon_16x16.png"),
    ("icp5", "icon_32x32.png"),
    ("icp6", "icon_32x32@2x.png"),
    ("ic07", "icon_128x128.png"),
    ("ic08", "icon_256x256.png"),
    ("ic09", "icon_512x512.png"),
    ("ic10", "icon_512x512@2x.png"),
]

func bigEndianData(_ value: UInt32) -> Data {
    var bigEndian = value.bigEndian
    return Data(bytes: &bigEndian, count: MemoryLayout<UInt32>.size)
}

var body = Data()
for (type, filename) in chunks {
    let png = try Data(contentsOf: output.appendingPathComponent(filename))
    body.append(Data(type.utf8))
    body.append(bigEndianData(UInt32(png.count + 8)))
    body.append(png)
}
var icns = Data("icns".utf8)
icns.append(bigEndianData(UInt32(body.count + 8)))
icns.append(body)
try icns.write(to: icnsOutput, options: .atomic)
