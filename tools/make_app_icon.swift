// Renders the SideCursor app icon: AppIcon.icns for the Mac app and
// SideCursor.ico for the Windows app.
//
//     swift tools/make_app_icon.swift
//
// The icon shows a Mac screen and a larger Windows screen joined by the
// green shared edge from the Display Layout settings, with the pointer
// crossing it. Everything is drawn from code so it can be tweaked and
// regenerated; the icons are committed so builds do not need to run this.
import AppKit
import Foundation

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let resources = root.appendingPathComponent("apps/macos/Resources")
let windowsAssets = root.appendingPathComponent("apps/windows/SideCursor.Windows/Assets")

/// macOS icons sit inside the standard 824 pt grid with a drop shadow;
/// Windows icons fill more of the square and carry no shadow.
enum IconStyle { case mac, windows }
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

func linearGradient(_ context: CGContext, _ colors: [CGColor], from start: CGPoint, to end: CGPoint) {
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: nil)!
    context.drawLinearGradient(gradient, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

/// A screen with a white bezel. `bar` draws the Mac menu bar (top) or the
/// Windows taskbar (bottom). Coordinates are y-up, on a 1024 canvas.
func drawScreen(_ context: CGContext, _ frame: CGRect, screen: [CGColor], bar: (top: Bool, color: CGColor)) {
    let bezel = CGPath(roundedRect: frame, cornerWidth: 26, cornerHeight: 26, transform: nil)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0x10154A, 0.45))
    context.addPath(bezel)
    context.setFillColor(color(0xF7F8FF))
    context.fillPath()
    context.restoreGState()

    let inner = frame.insetBy(dx: 16, dy: 16)
    let innerPath = CGPath(roundedRect: inner, cornerWidth: 12, cornerHeight: 12, transform: nil)
    context.saveGState()
    context.addPath(innerPath)
    context.clip()
    linearGradient(context, screen, from: CGPoint(x: inner.minX, y: inner.maxY), to: CGPoint(x: inner.maxX, y: inner.minY))
    let barHeight = inner.height * (bar.top ? 0.085 : 0.11)
    let barRect = bar.top
        ? CGRect(x: inner.minX, y: inner.maxY - barHeight, width: inner.width, height: barHeight)
        : CGRect(x: inner.minX, y: inner.minY, width: inner.width, height: barHeight)
    context.setFillColor(bar.color)
    context.fill(barRect)
    context.restoreGState()
}

func drawIcon(size: Int, style: IconStyle = .mac) -> CGImage {
    let pixels = CGFloat(size)
    let context = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.scaleBy(x: pixels / 1024, y: pixels / 1024)
    if style == .windows {
        context.translateBy(x: 512, y: 512)
        context.scaleBy(x: 1.14, y: 1.14)
        context.translateBy(x: -512, y: -512)
    }
    context.setShouldAntialias(true)
    context.interpolationQuality = .high

    // Body: the macOS icon grid's 824 pt rounded square with a soft shadow.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)
    context.saveGState()
    if style == .mac {
        context.setShadow(offset: CGSize(width: 0, height: -14), blur: 34, color: color(0x000000, 0.32))
    }
    context.addPath(bodyPath)
    context.setFillColor(color(0x4B5BE8))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(bodyPath)
    context.clip()
    linearGradient(context, [color(0x4D8DFF), color(0x5A55EE), color(0x7B3FD9)], from: CGPoint(x: body.minX, y: body.maxY), to: CGPoint(x: body.maxX, y: body.minY))
    // Gentle top sheen.
    linearGradient(context, [color(0xFFFFFF, 0.20), color(0xFFFFFF, 0)], from: CGPoint(x: 0, y: body.maxY), to: CGPoint(x: 0, y: body.midY + 40))
    context.restoreGState()

    // Mac screen (smaller) and Windows screen (larger), a small gap apart.
    let mac = CGRect(x: 178, y: 392, width: 300, height: 206)
    let windows = CGRect(x: 500, y: 318, width: 346, height: 326)
    drawScreen(context, mac, screen: [color(0xFFB067), color(0xF2547F)], bar: (top: true, color: color(0xFFFFFF, 0.85)))
    drawScreen(context, windows, screen: [color(0x22B8E0), color(0x1F66D6)], bar: (top: false, color: color(0x0B2A6B, 0.55)))

    // The shared edge, where the pointer crosses: a glowing green bar
    // spanning the stretch both screens share.
    let edgeX = (mac.maxX + windows.minX) / 2
    let edge = CGRect(x: edgeX - 9, y: mac.minY + 10, width: 18, height: mac.height - 20)
    context.saveGState()
    context.setShadow(offset: .zero, blur: 26, color: color(0x3CFF8A, 0.95))
    context.addPath(CGPath(roundedRect: edge, cornerWidth: 9, cornerHeight: 9, transform: nil))
    context.setFillColor(color(0x42E07F))
    context.fillPath()
    context.restoreGState()

    // Motion trail behind the pointer, on the Mac side.
    context.saveGState()
    context.setLineCap(.round)
    for (index, y) in [530.0, 490.0, 450.0].enumerated() {
        let length = 110.0 - Double(index) * 22
        context.setStrokeColor(color(0xFFFFFF, 0.75 - CGFloat(index) * 0.15))
        context.setLineWidth(15)
        context.move(to: CGPoint(x: 470 - length, y: y))
        context.addLine(to: CGPoint(x: 452, y: y))
        context.strokePath()
    }
    context.restoreGState()

    // The pointer, tip just past the shared edge.
    let tip = CGPoint(x: 522, y: 572)
    let arrow: [CGPoint] = [
        CGPoint(x: 0, y: 0), CGPoint(x: 0, y: -196), CGPoint(x: 48, y: -152),
        CGPoint(x: 82, y: -226), CGPoint(x: 116, y: -210), CGPoint(x: 83, y: -138),
        CGPoint(x: 146, y: -138),
    ].map { CGPoint(x: tip.x + $0.x, y: tip.y + $0.y) }
    let pointer = CGMutablePath()
    pointer.addLines(between: arrow)
    pointer.closeSubpath()
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -8), blur: 18, color: color(0x000000, 0.45))
    context.addPath(pointer)
    context.setFillColor(color(0xFFFFFF))
    context.fillPath()
    context.restoreGState()
    context.addPath(pointer)
    context.setStrokeColor(color(0x111111))
    context.setLineWidth(11)
    context.setLineJoin(.round)
    context.strokePath()

    return context.makeImage()!
}

func png(_ image: CGImage) -> Data {
    NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
}

/// Straight (non-premultiplied) BGRA rows, bottom-up, as a Windows DIB wants.
func bgraBottomUp(_ image: CGImage) -> Data {
    let width = image.width
    let height = image.height
    var rgba = [UInt8](repeating: 0, count: width * height * 4)
    let context = CGContext(
        data: &rgba,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    var out = Data(capacity: width * height * 4)
    // CGContext memory is top row first; a DIB is bottom row first.
    for row in (0..<height).reversed() {
        for column in 0..<width {
            let i = (row * width + column) * 4
            let alpha = rgba[i + 3]
            func straight(_ value: UInt8) -> UInt8 {
                alpha == 0 ? 0 : UInt8(min(255, (Int(value) * 255 + Int(alpha) / 2) / Int(alpha)))
            }
            out.append(contentsOf: [straight(rgba[i + 2]), straight(rgba[i + 1]), straight(rgba[i]), alpha])
        }
    }
    return out
}

func littleEndian<T: FixedWidthInteger>(_ value: T) -> Data {
    withUnsafeBytes(of: value.littleEndian) { Data($0) }
}

/// Classic 32-bit DIB frames up to 64 px (read by every Windows API, including
/// the tray), and a PNG frame at 256 px.
func ico(sizes: [Int]) -> Data {
    var frames: [(size: Int, data: Data)] = []
    for size in sizes {
        let image = drawIcon(size: size, style: .windows)
        if size >= 256 {
            frames.append((size, png(image)))
            continue
        }
        var dib = Data()
        dib += littleEndian(UInt32(40))
        dib += littleEndian(Int32(size))
        dib += littleEndian(Int32(size * 2))
        dib += littleEndian(UInt16(1))
        dib += littleEndian(UInt16(32))
        dib += littleEndian(UInt32(0))
        let maskStride = ((size + 31) / 32) * 4
        dib += littleEndian(UInt32(size * size * 4 + maskStride * size))
        dib += Data(count: 16)
        dib += bgraBottomUp(image)
        dib += Data(count: maskStride * size)
        frames.append((size, dib))
    }
    var file = Data()
    file += littleEndian(UInt16(0))
    file += littleEndian(UInt16(1))
    file += littleEndian(UInt16(frames.count))
    var offset = 6 + 16 * frames.count
    for frame in frames {
        file.append(UInt8(frame.size >= 256 ? 0 : frame.size))
        file.append(UInt8(frame.size >= 256 ? 0 : frame.size))
        file.append(0)
        file.append(0)
        file += littleEndian(UInt16(1))
        file += littleEndian(UInt16(32))
        file += littleEndian(UInt32(frame.data.count))
        file += littleEndian(UInt32(offset))
        offset += frame.data.count
    }
    for frame in frames {
        file += frame.data
    }
    return file
}

try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    try png(drawIcon(size: points)).write(to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try png(drawIcon(size: points * 2)).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
let preview = FileManager.default.temporaryDirectory.appendingPathComponent("SideCursorAppIcon-1024.png")
try png(drawIcon(size: 1024)).write(to: preview)
print("Preview: \(preview.path)")

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", resources.appendingPathComponent("AppIcon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    FileHandle.standardError.write("iconutil failed\n".data(using: .utf8)!)
    exit(1)
}
print("Wrote \(resources.appendingPathComponent("AppIcon.icns").path)")

try FileManager.default.createDirectory(at: windowsAssets, withIntermediateDirectories: true)
try ico(sizes: [16, 20, 24, 32, 40, 48, 64, 256]).write(to: windowsAssets.appendingPathComponent("SideCursor.ico"))
let windowsPreview = FileManager.default.temporaryDirectory.appendingPathComponent("SideCursorWindowsIcon-256.png")
try png(drawIcon(size: 256, style: .windows)).write(to: windowsPreview)
print("Wrote \(windowsAssets.appendingPathComponent("SideCursor.ico").path) (preview: \(windowsPreview.path))")
