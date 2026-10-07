import CoreGraphics
import Foundation

// 开发期小工具：按「从前到后」的顺序列出屏幕上的窗口。
// CGWindowListCopyWindowInfo 返回的顺序就是 z 序，索引越小越靠前。
// 用来回答「这个窗口到底有没有在前面」——只看 kCGWindowLayer 不够，
// 同一层里还分前后，而且应用是否激活也会影响排序。
//
//   swift Tools/ZOrderProbe.swift DeepSeek

let needle = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "DeepSeek"

guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
    print("无法枚举窗口")
    exit(1)
}

var targetIndex: Int?
for (index, window) in list.enumerated() {
    let owner = window[kCGWindowOwnerName as String] as? String ?? "?"
    let layer = window[kCGWindowLayer as String] as? Int ?? -1
    let bounds = window[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
    let width = Int(bounds["Width"] ?? 0)
    let height = Int(bounds["Height"] ?? 0)
    let mark = owner.localizedCaseInsensitiveContains(needle) ? "   ← 本 App" : ""
    print(String(format: "%3d  layer=%-5d %@  %dx%d%@", index, layer, owner, width, height, mark))
    if owner.localizedCaseInsensitiveContains(needle), targetIndex == nil {
        targetIndex = index
    }
}

print("")
if let targetIndex {
    print("本 App 在 z 序中的位置：第 \(targetIndex) 个（共 \(list.count) 个窗口，越小越靠前）")
} else {
    print("没找到匹配 \"\(needle)\" 的窗口")
}
