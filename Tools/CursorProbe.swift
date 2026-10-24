import AppKit

// 开发期工具：查询或移动指针位置。
//
//   swift Tools/CursorProbe.swift where
//   swift Tools/CursorProbe.swift warp <x> <y>
//
// 坐标用屏幕坐标（原点在左下，和 `NSEvent.mouseLocation` 一致）。
//
// 为什么需要它：验证「闲置淡出」必须模拟「指针移回面板 / 离开面板」，
// 而这个状态又没法靠抓帧判断——抓帧渲染的是视图层级，不含窗口 alpha
// 和 ignoresMouseEvents。只能真的去动指针，再读 App 自己写出的报告。

let args = CommandLine.arguments
guard args.count >= 2 else {
    print("用法: CursorProbe.swift where | warp <x> <y>")
    exit(2)
}

func describe(_ point: NSPoint) -> String {
    String(format: "(%.0f, %.0f)", point.x, point.y)
}

switch args[1] {
case "where":
    print(describe(NSEvent.mouseLocation))

case "click":
    // 合成一次左键点击，用来验证「淡出后点击是否真的穿透到下层」
    guard args.count == 4, let x = Double(args[2]), let y = Double(args[3]),
          let main = NSScreen.screens.first else {
        print("用法: CursorProbe.swift click <x> <y>")
        exit(2)
    }
    let point = CGPoint(x: x, y: main.frame.height - y)
    CGWarpMouseCursorPosition(point)
    Thread.sleep(forTimeInterval: 0.12)
    for type in [CGEventType.leftMouseDown, .leftMouseUp] {
        if let event = CGEvent(mouseEventSource: nil, mouseType: type,
                               mouseCursorPosition: point, mouseButton: .left) {
            event.post(tap: .cghidEventTap)
        }
        Thread.sleep(forTimeInterval: 0.05)
    }
    print("click → \(describe(NSEvent.mouseLocation))")

case "screens":
    // 换算坐标要用主屏高度：CG 全局坐标原点在左上，NSScreen 在左下
    for (index, screen) in NSScreen.screens.enumerated() {
        print("screen[\(index)] frame=\(screen.frame) visible=\(screen.visibleFrame)")
    }

case "warp":
    guard args.count == 4, let x = Double(args[2]), let y = Double(args[3]) else {
        print("用法: CursorProbe.swift warp <x> <y>")
        exit(2)
    }
    // CGWarpMouseCursorPosition 的全局坐标原点在主屏左上，y 向下；
    // 我们对外用 NSScreen 那套（原点左下，y 向上），这里换算一次。
    guard let main = NSScreen.screens.first else {
        print("没有可用屏幕")
        exit(1)
    }
    let cg = CGPoint(x: x, y: main.frame.height - y)
    CGWarpMouseCursorPosition(cg)
    // 让 App 的轮询跑一轮再读
    Thread.sleep(forTimeInterval: 0.15)
    print("warp → 现在 \(describe(NSEvent.mouseLocation))")

default:
    print("未知命令 \(args[1])")
    exit(2)
}
