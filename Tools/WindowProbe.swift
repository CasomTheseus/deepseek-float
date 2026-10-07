import CoreGraphics
import Foundation

// 开发期小工具：列出 DeepSeekFloat 的窗口几何。
// 不需要「屏幕录制」权限（只读窗口元数据，不读像素）。
//   swift Tools/WindowProbe.swift DeepSeekFloat
let needle = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "DeepSeek"

guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
    print("无法枚举窗口")
    exit(1)
}

var found = 0
for window in list {
    let owner = window[kCGWindowOwnerName as String] as? String ?? "?"
    guard owner.localizedCaseInsensitiveContains(needle) else { continue }
    found += 1
    let name = window[kCGWindowName as String] as? String ?? "(无名)"
    let layer = window[kCGWindowLayer as String] as? Int ?? -1
    let alpha = window[kCGWindowAlpha as String] as? Double ?? -1
    var frame = "(无 bounds)"
    if let bounds = window[kCGWindowBounds as String] as? [String: CGFloat] {
        frame = String(format: "x=%.0f y=%.0f w=%.0f h=%.0f",
                       bounds["X"] ?? 0, bounds["Y"] ?? 0, bounds["Width"] ?? 0, bounds["Height"] ?? 0)
    }
    print("owner=\(owner)  name=\(name)  layer=\(layer)  alpha=\(alpha)  \(frame)")
}

if found == 0 { print("没有找到匹配 \"\(needle)\" 的可见窗口") }
