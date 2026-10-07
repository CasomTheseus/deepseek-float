import AppKit
import SwiftUI
import Combine

/// 无边框悬浮面板。
/// - `.nonactivatingPanel`：点它不会把当前前台 App 顶掉，这对桌面小挂件很关键
/// - `canBecomeKey`：非激活面板默认不能成为 key window，那样设置页里的输入框没法打字
final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// 头部拖拽热区。SwiftUI 内容会吃掉 mouseDown，
/// 只靠 `isMovableByWindowBackground` 在纯 SwiftUI 窗口里并不可靠，
/// 所以显式放一个 AppKit 视图调 `performDrag`。
struct WindowDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { HandleView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class HandleView: NSView {
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .openHand)
        }
    }
}

@MainActor
final class FloatingPanelController {

    private let panel: FloatingPanel
    private let model: AppModel
    private var cancellables = Set<AnyCancellable>()

    init(model: AppModel) {
        self.model = model
        self.panel = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: Metrics.width, height: 330),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        configure()
        installContent()
        observe()
        restorePosition()
        applyLevel(model.alwaysOnTop)
    }

    // MARK: - 装配

    private func configure() {
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovable = true
        panel.animationBehavior = .utilityWindow
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false
        panel.worksWhenModal = true
        // 显式拖拽热区已覆盖头部，这里关掉以免和 SwiftUI 按钮抢事件
        panel.isMovableByWindowBackground = false
    }

    private func installContent() {
        let root = WidgetView().environmentObject(model)
        let hosting = NSHostingView(rootView: root)
        hosting.translatesAutoresizingMaskIntoConstraints = true
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
    }

    private func observe() {
        // 内容高度变化 → 面板自适应（保持顶边不动）
        model.$contentHeight
            .removeDuplicates()
            .sink { [weak self] height in self?.applySize(height) }
            .store(in: &cancellables)

        // ⚠️ 必须用 publisher 发出来的值，不能在闭包里回头读 `model.alwaysOnTop`。
        // `@Published` 是在 **willSet** 阶段发布事件的：闭包执行时属性仍是旧值，
        // 于是 applyLevel() 每次都设成相反的层级 —— 这就是「置顶开关效果相反」的根因。
        // 之前静态启动时看不出来（初始化时旧值恰好等于新值），只有运行中切换才会暴露。
        model.$alwaysOnTop
            .removeDuplicates()
            .sink { [weak self] enabled in self?.applyLevel(enabled) }
            .store(in: &cancellables)

        model.$showSettings
            .removeDuplicates()
            .sink { [weak self] showing in
                guard let self, showing else { return }
                self.panel.makeKeyAndOrderFront(nil)
            }
            .store(in: &cancellables)

        NotificationCenter.default
            .publisher(for: NSWindow.didMoveNotification, object: panel)
            .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.model.savedFrame = self.panel.frame
            }
            .store(in: &cancellables)
    }

    // MARK: - 尺寸

    private func applySize(_ height: CGFloat) {
        guard height > 1 else { return }
        let screen = panel.screen ?? NSScreen.main
        let maxHeight = max(160, (screen?.visibleFrame.height ?? 800) - 60)
        let target = min(height, maxHeight)
        var frame = panel.frame
        guard abs(frame.height - target) > 0.5 else { return }
        let top = frame.maxY
        frame.size = NSSize(width: Metrics.width, height: target)
        frame.origin.y = top - target
        panel.setFrame(frame, display: true, animate: false)
        clampOnScreen()
    }

    private func applyLevel(_ enabled: Bool) {
        panel.level = enabled ? .floating : .normal

        // level 只决定「层级」，并不会重排窗口。而且这是个 accessory app 的非激活面板，
        // 别的 App 被激活时它也不会自动落到后面——实测：level=0 时它仍然压在
        // 整屏 Safari（1680×1020，完全覆盖本窗口）之上，z 序还排在 Safari 前面。
        // 所以关掉置顶必须主动把它送到同层末尾，否则这个开关等于没有效果。
        if enabled {
            panel.orderFrontRegardless()
        } else {
            panel.orderBack(nil)
        }
    }

    // MARK: - 位置

    private func restorePosition() {
        if let saved = model.savedFrame {
            var frame = saved
            frame.size.width = Metrics.width
            panel.setFrame(frame, display: false)
            if !isOnAnyScreen(panel.frame) { moveToDefaultCorner() }
        } else {
            moveToDefaultCorner()
        }
    }

    private func moveToDefaultCorner() {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let margin: CGFloat = 18
        let size = panel.frame.size
        let origin = NSPoint(
            x: visible.maxX - size.width - margin,
            y: visible.maxY - size.height - margin
        )
        panel.setFrameOrigin(origin)
    }

    private func isOnAnyScreen(_ frame: NSRect) -> Bool {
        NSScreen.screens.contains { $0.visibleFrame.intersects(frame) }
    }

    /// 换显示器 / 分辨率变化后把窗口拉回可见区域
    private func clampOnScreen() {
        guard let screen = panel.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        var frame = panel.frame
        if frame.maxX > visible.maxX { frame.origin.x = visible.maxX - frame.width }
        if frame.minX < visible.minX { frame.origin.x = visible.minX }
        if frame.maxY > visible.maxY { frame.origin.y = visible.maxY - frame.height }
        if frame.minY < visible.minY { frame.origin.y = visible.minY }
        if frame.origin != panel.frame.origin {
            panel.setFrameOrigin(frame.origin)
        }
    }

    // MARK: - 显隐

    /// 供调试抓帧使用
    var window: NSWindow { panel }

    var isVisible: Bool { panel.isVisible }

    func show() {
        panel.orderFrontRegardless()
        model.panelVisibilityChanged(true)
    }

    func hide() {
        model.panelVisibilityChanged(false)
        panel.orderOut(nil)
    }

    func toggle() {
        isVisible ? hide() : show()
    }

    func showSettings() {
        model.showSettings = true
        show()
        panel.makeKeyAndOrderFront(nil)
    }
}
