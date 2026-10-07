import AppKit

/// 把窗口内容真实渲染成 PNG。
///
/// **为什么需要它**：本机的终端/DSH 进程没有「屏幕录制」授权，`screencapture` 直接
/// 报 `could not create image from display`；而 `ImageRenderer` 只能渲染静态首帧。
/// 上一轮就是这么漏掉 bug 的——`snapshotMode` 绕开了 `KeyframeAnimator`，
/// 只验证了气泡长什么样，没验证动画会不会跑，结果它在真实窗口里根本不显示。
///
/// 渲染**自己进程的**视图层级不需要任何系统授权，所以这是唯一能抓到动画中间帧的办法。
enum LiveCapture {

    @discardableResult
    @MainActor
    static func write(_ window: NSWindow?, to path: String) -> Bool {
        guard let view = window?.contentView, view.bounds.width > 1, view.bounds.height > 1 else {
            return false
        }

        // SwiftUI 在 macOS 上是 layer-backed，直接渲染 CALayer 树比
        // cacheDisplay 更完整（NSVisualEffectView 的模糊除外，那条走系统合成）
        let representation = renderLayer(view) ?? cacheDisplay(view)
        guard let representation, let data = representation.representation(using: .png, properties: [:]) else {
            return false
        }
        do {
            try data.write(to: URL(fileURLWithPath: path))
            return true
        } catch {
            return false
        }
    }

    private static func renderLayer(_ view: NSView) -> NSBitmapImageRep? {
        guard let layer = view.layer else { return nil }
        let scale = view.window?.backingScaleFactor ?? 2
        let width = Int(view.bounds.width * scale)
        let height = Int(view.bounds.height * scale)
        guard width > 1, height > 1 else { return nil }
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else { return nil }

        context.scaleBy(x: scale, y: scale)
        // CALayer 是左下原点、位图是左上原点，不翻转截出来就是上下颠倒的
        context.translateBy(x: 0, y: view.bounds.height)
        context.scaleBy(x: 1, y: -1)
        layer.render(in: context)
        guard let image = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: image)
    }

    private static func cacheDisplay(_ view: NSView) -> NSBitmapImageRep? {
        guard let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: representation)
        return representation
    }
}
