import AppKit
import Foundation

// 开发期小工具：裁剪 PNG 的指定区域，方便把某一小块放大检查。
//
//   swift Tools/CropImage.swift <in.png> <out.png> <x> <y> <w> <h>
//
// 坐标以图片左上角为原点，单位是像素。
// 用途：抓帧得到的整窗图太大，柱状图/构成条这些细节在缩略图里看不出来，
// 先裁出来再读，才能判断动画帧之间到底有没有变化。

let args = CommandLine.arguments
guard args.count == 7 else {
    print("用法: CropImage.swift <in.png> <out.png> <x> <y> <w> <h>")
    exit(2)
}
guard let image = NSImage(contentsOfFile: args[1]),
      let tiff = image.tiffRepresentation,
      let source = NSBitmapImageRep(data: tiff),
      let cgImage = source.cgImage else {
    print("读取失败：\(args[1])")
    exit(1)
}

let x = Int(args[3]) ?? 0
let y = Int(args[4]) ?? 0
let w = Int(args[5]) ?? 0
let h = Int(args[6]) ?? 0
let rect = CGRect(x: x, y: y, width: w, height: h)
    .intersection(CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))

guard rect.width > 0, rect.height > 0, let cropped = cgImage.cropping(to: rect) else {
    print("裁剪区域无效：\(rect)")
    exit(1)
}

let output = NSBitmapImageRep(cgImage: cropped)
guard let data = output.representation(using: .png, properties: [:]) else {
    print("编码失败")
    exit(1)
}
do {
    try data.write(to: URL(fileURLWithPath: args[2]))
    print("已写出 \(args[2])  \(cropped.width)x\(cropped.height)")
} catch {
    print("写入失败：\(error.localizedDescription)")
    exit(1)
}
