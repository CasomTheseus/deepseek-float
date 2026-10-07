import AppKit
import Foundation

// 生成 AppIcon.iconset（交给 build.sh 里的 iconutil 打成 .icns）。
// 纯代码绘制，不引入任何设计资源：
//   DeepSeek 品牌蓝渐变圆角方块 + 三道水波，呼应菜单栏的 water.waves。
//
//   swiftc -o icon-gen Tools/IconGen.swift -framework AppKit && ./icon-gen <输出目录>

let brandTop = NSColor(srgbRed: 0.38, green: 0.50, blue: 1.00, alpha: 1)
let brandBottom = NSColor(srgbRed: 0.20, green: 0.28, blue: 0.86, alpha: 1)

/// macOS iconset 需要的尺寸与文件名
let variants: [(name: String, pixels: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

func renderIcon(pixels: Int) -> Data? {
    guard let rep = NSBitmapImageRep(
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
    ) else { return nil }

    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high

    let size = CGFloat(pixels)
    let inset = size * 0.055
    let body = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let radius = body.width * 0.225

    // 底板
    let plate = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)
    NSGradient(starting: brandTop, ending: brandBottom)?.draw(in: plate, angle: -75)

    // 顶部高光，避免大尺寸下显得太平
    let gloss = NSBezierPath(
        roundedRect: NSRect(x: body.minX, y: body.midY, width: body.width, height: body.height / 2),
        xRadius: radius, yRadius: radius
    )
    NSColor.white.withAlphaComponent(0.10).setFill()
    gloss.fill()

    // 三道水波
    let lineWidth = max(1.0, size * 0.055)
    let amplitude = size * 0.052
    let startX = body.minX + body.width * 0.22
    let endX = body.maxX - body.width * 0.22
    let centers: [CGFloat] = [0.615, 0.500, 0.385]

    for (index, ratio) in centers.enumerated() {
        let y = body.minY + body.height * ratio
        let path = NSBezierPath()
        path.lineWidth = lineWidth
        path.lineCapStyle = .round
        let half = (endX - startX) / 2
        path.move(to: NSPoint(x: startX, y: y))
        path.curve(
            to: NSPoint(x: startX + half, y: y),
            controlPoint1: NSPoint(x: startX + half * 0.35, y: y + amplitude),
            controlPoint2: NSPoint(x: startX + half * 0.65, y: y - amplitude)
        )
        path.curve(
            to: NSPoint(x: endX, y: y),
            controlPoint1: NSPoint(x: startX + half * 1.35, y: y + amplitude),
            controlPoint2: NSPoint(x: startX + half * 1.65, y: y - amplitude)
        )
        NSColor.white.withAlphaComponent(index == 1 ? 0.98 : 0.72).setStroke()
        path.stroke()
    }

    return rep.representation(using: .png, properties: [:])
}

let outputDirectory = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: outputDirectory, withIntermediateDirectories: true)

// 同一像素尺寸只画一次，@1x/@2x 复用
var cache: [Int: Data] = [:]
for variant in variants {
    let data: Data?
    if let cached = cache[variant.pixels] {
        data = cached
    } else {
        data = renderIcon(pixels: variant.pixels)
        cache[variant.pixels] = data
    }
    guard let data else {
        FileHandle.standardError.write(Data("绘制 \(variant.name) 失败\n".utf8))
        exit(1)
    }
    let url = URL(fileURLWithPath: outputDirectory).appendingPathComponent(variant.name)
    do {
        try data.write(to: url)
    } catch {
        FileHandle.standardError.write(Data("写入 \(variant.name) 失败：\(error.localizedDescription)\n".utf8))
        exit(1)
    }
}

print("已生成 \(variants.count) 个尺寸 → \(outputDirectory)")
