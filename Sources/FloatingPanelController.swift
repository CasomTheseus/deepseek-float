import AppKit
import SwiftUI
import Combine
import QuartzCore

/// 无边框悬浮面板。
/// - `.nonactivatingPanel`：点它不会把当前前台 App 顶掉，这对桌面小挂件很关键
/// - `canBecomeKey`：非激活面板默认不能成为 key window，那样设置页里的输入框没法打字
final class FloatingPanel: NSPanel {
    /// 验收用：数一下窗口到底有没有收到 mouseDown。
    /// ignoresMouseEvents 为真只是「声明」，这个计数才是事件真的没进来的证据。
    var mouseDownCount = 0

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown { mouseDownCount += 1 }
        super.sendEvent(event)
    }

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

/// 闲置淡出的状态机。
///
/// 抽成纯函数，是因为难的从来不是把窗口调淡，而是判定「什么时候淡、什么时候恢复」。
///
/// 这里有过一个严重错误：把「悬停」也当成恢复条件。结果是为了点下面的窗口，
/// 指针必须先经过面板 —— 可一经过就恢复，点击又被面板抢走，穿透等于没做。
/// 现在的规则是：**一旦淡出，悬停不再恢复**，只有点波浪图标或显式操作才恢复。
enum IdleFadePolicy {
    enum Phase: Equatable { case awake, faded }
    enum Action: Equatable { case fade, restore, stay }

    static func action(phase: Phase,
                       hovering: Bool,
                       idleFor: TimeInterval,
                       delay: TimeInterval,
                       enabled: Bool,
                       settingsOpen: Bool,
                       lowBalance: Bool) -> Action {
        // 关掉开关、开着设置页、正在低余额告警：都不该淡，已经淡了就恢复
        if !enabled || settingsOpen || lowBalance {
            return phase == .faded ? .restore : .stay
        }
        if phase == .faded {
            // 已经淡出：悬停不恢复。图标点击由上层单独处理
            return .stay
        }
        guard !hovering else { return .stay }
        return idleFor >= delay ? .fade : .stay
    }

    /// 淡出期间窗口是否该接收鼠标事件。只有指针在波浪图标上时放行，
    /// 其余位置一律穿透——否则又变成「整块面板挡着」。
    static func acceptsMouseWhileFaded(cursorOverIcon: Bool) -> Bool { cursorOverIcon }
}

@MainActor
final class FloatingPanelController {

    private let panel: FloatingPanel
    private let model: AppModel
    private var cancellables = Set<AnyCancellable>()

    /// 闲置淡出用的轮询。不用 tracking area 是因为淡出后窗口
    /// `ignoresMouseEvents = true`，压根收不到 mouseEntered；
    /// `NSEvent.mouseLocation` 是全局属性，不需要任何权限。
    private var idleTimer: Timer?
    /// 最后一次「指针在面板上」或「被抑制」的时刻，闲置时长从这里算起
    private var fadeAnchor = Date()
    private var isFaded = false

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
        startIdleWatch()
    }

    deinit {
        idleTimer?.invalidate()
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

        // 点波浪图标 → 恢复。这是淡出状态下唯一的恢复入口，
        // 所以不受「什么时候该淡」的判定影响，直接放行。
        model.restoreRequests
            .sink { [weak self] in
                guard let self else { return }
                self.fadeAnchor = Date()
                self.setFaded(false)
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

    // MARK: - 闲置淡出

    private func startIdleWatch() {
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickIdle() }
        }
        // 用 .common 模式，否则拖动窗口时进入 eventTracking，轮询会停
        RunLoop.main.add(timer, forMode: .common)
        idleTimer = timer
    }

    /// 波浪图标的屏幕矩形。SwiftUI 全局坐标原点在宿主视图左上、y 向下，
    /// 窗口坐标在左下、y 向上，这里换算一次。
    private var iconScreenRect: NSRect {
        // 布局还没报上来时兜底到左上角一小块，否则淡出后就没有恢复入口了
        let frame = model.iconFrame.width > 1
            ? model.iconFrame
            : CGRect(x: 0, y: 0, width: 26, height: 26)
        return NSRect(x: panel.frame.minX + frame.minX,
                      y: panel.frame.maxY - frame.maxY,
                      width: frame.width,
                      height: frame.height)
    }

    private func tickIdle() {
        guard panel.isVisible else { return }

        let cursor = NSEvent.mouseLocation
        let hovering = panel.frame.contains(cursor)
        let overIcon = iconScreenRect.contains(cursor)
        let idleFor = Date().timeIntervalSince(fadeAnchor)

        let action = IdleFadePolicy.action(
            phase: isFaded ? .faded : .awake,
            hovering: hovering,
            idleFor: idleFor,
            delay: model.idleFadeDelay,
            enabled: model.fadeWhenIdle,
            settingsOpen: model.showSettings,
            lowBalance: model.isLowBalance
        )

        if hovering || model.showSettings || model.isLowBalance || !model.fadeWhenIdle {
            fadeAnchor = Date()
        }

        switch action {
        case .fade: setFaded(true)
        case .restore: setFaded(false)
        case .stay: break
        }

        // 淡出期间只放行图标那一小块，其余位置保持穿透
        if isFaded {
            let accept = IdleFadePolicy.acceptsMouseWhileFaded(cursorOverIcon: overIcon)
            if panel.ignoresMouseEvents == accept {
                panel.ignoresMouseEvents = !accept
                writeIdleReport(stage: accept ? "iconHover" : "iconLeave",
                                target: CGFloat(model.idleOpacity))
            }
        }
    }

    private func setFaded(_ faded: Bool) {
        guard faded != isFaded else { return }
        isFaded = faded
        // 注意：这里**不能**重置 fadeAnchor。淡出的条件正是「闲置超过延迟」，
        // 一重置就立刻不成立，下一轮轮询马上撤回，于是来回震荡。
        // 锚点只该在「被抑制」或「被重新显示」时重置。

        model.setIdleFaded(faded)

        // 这一行就是「鼠标穿透」：事件不再进这个窗口，直接落到底下的 App
        panel.ignoresMouseEvents = faded

        let target = faded ? CGFloat(model.idleOpacity) : 1.0
        let duration: TimeInterval = faded ? 0.5 : 0.16
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: faded ? .easeInEaseOut : .easeOut)
            panel.animator().alphaValue = target
        }

        // 动画开始那一瞬间读到的 alpha 还是旧值，不能当证据，
        // 所以等动画跑完再记一条 settled。
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.08) { [weak self] in
            self?.writeIdleReport(stage: "settled", target: target)
        }
    }

    /// 供动态验收：淡出状态没法靠抓帧判断——抓帧渲染的是视图层级，
    /// 不含窗口 alphaValue 和 ignoresMouseEvents，只能让 App 自己报。
    private func writeIdleReport(stage: String, target: CGFloat) {
        let hovering = panel.frame.contains(NSEvent.mouseLocation)
        let center = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        // 拆成数组再 join：这串拼接用 `+` 写会让类型检查器爆掉
        // （"unable to type-check this expression in reasonable time"）
        let parts: [String] = [
            stage,
            "faded=\(isFaded)",
            "alpha=\(String(format: "%.2f", panel.alphaValue))",
            "target=\(String(format: "%.2f", target))",
            "ignoresMouse=\(panel.ignoresMouseEvents)",
            "hovering=\(hovering)",
            "delay=\(Int(model.idleFadeDelay))s",
            "mouseDowns=\(panel.mouseDownCount)",
            // 直接问窗口服务器：面板中心那个点上、最上层「可接收鼠标事件」的窗口是谁。
            // 淡出后应当不再是本窗口。这个查询不需要任何系统授权。
            "hitAtCenter=\(NSWindow.windowNumber(at: center, belowWindowWithWindowNumber: 0))",
            "self=\(panel.windowNumber)",
            "overIcon=\(iconScreenRect.contains(NSEvent.mouseLocation))",
            "iconRect=\(Int(iconScreenRect.minX)),\(Int(iconScreenRect.minY)),"
                + "\(Int(iconScreenRect.width)),\(Int(iconScreenRect.height))",
            // 面板中心那个点上命中哪个 NSView：用来确认波浪图标没有被拖拽热区盖住
            "hitView=\(Self.hitViewName(panel: panel, at: iconScreenRect))",
        ]
        let line = parts.joined(separator: " ") + "\n"
        let url = URL(fileURLWithPath: "/tmp/dsf-idle-report.txt")
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        try? (existing + line).write(to: url, atomically: true, encoding: .utf8)
    }

    /// 图标位置命中的 NSView 类名。若淡出后这里仍是 HandleView，
    /// 说明拖拽热区盖住了图标，点击会被它吃掉。
    private static func hitViewName(panel: NSWindow, at screenRect: NSRect) -> String {
        guard let content = panel.contentView else { return "no-content" }
        let point = NSPoint(x: screenRect.midX, y: screenRect.midY)
        let inWindow = panel.convertPoint(fromScreen: point)
        return content.hitTest(inWindow).map { String(describing: type(of: $0)) } ?? "nil"
    }

    /// 当前是否处于淡出（鼠标穿透）状态
    var isIdleFaded: Bool { isFaded }

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
        fadeAnchor = Date()
        setFaded(false)
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
        // 先恢复可交互，否则最多要等 0.25 秒才能点设置里的控件
        fadeAnchor = Date()
        setFaded(false)
        model.showSettings = true
        show()
        panel.makeKeyAndOrderFront(nil)
    }
}
