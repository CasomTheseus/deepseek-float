import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var model: AppModel!
    private var panelController: FloatingPanelController!
    private var statusController: StatusItemController!
    private var reloadSignal: DispatchSourceSignal?
    private var probeSignal: DispatchSourceSignal?
    private var notifySignal: DispatchSourceSignal?
    private var topToggleSignal: DispatchSourceSignal?
    private var chartProbeSignal: DispatchSourceSignal?

    /// `--demo`：用示例数据跑 GUI，不联网、不读真实凭据。
    /// 用于录屏、截图、抓动画帧 —— 否则这些素材里会带上真实账号余额。
    private let demo: Bool

    /// `--peak` / `--offpeak`：强制峰谷状态，方便预览当前时段看不到的那种价签
    private let peakOverride: Bool?

    /// `--settings`：启动就打开设置页。离屏渲染画不出 AppKit 控件（Picker 会成 🚫），
    /// 只能用实时抓帧验收，所以需要一个能直接进设置页的入口。
    private let openSettings: Bool

    init(demo: Bool = false, peakOverride: Bool? = nil, openSettings: Bool = false) {
        self.demo = demo
        self.peakOverride = peakOverride
        self.openSettings = openSettings
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        terminateIfAlreadyRunning()

        // .accessory：不进 Dock、不抢菜单栏，只保留菜单栏状态项 + 悬浮窗
        NSApp.setActivationPolicy(.accessory)

        model = demo
            ? AppModel(startAutomatically: false, withSampleData: true)
            : AppModel()
        model.peakOverride = peakOverride
        if openSettings { model.showSettings = true }
        panelController = FloatingPanelController(model: model)
        statusController = StatusItemController(model: model, panelController: panelController)

        installReloadSignal()
        installProbeSignal()
        installNotifySignal()
        installTopToggleSignal()
        installChartProbeSignal()
        Notifier.requestAuthorization()
        panelController.show()
    }

    /// 同一时刻只允许一个实例。
    /// 悬浮窗没有 Dock 图标，重复启动不会有人察觉，结果就是两个窗口各自刷新、
    /// 各自记一份余额速率，看起来像数据错乱。注意这条守卫只在 GUI 模式下生效——
    /// `--selftest` / `--render` 这些命令行模式根本不会走到 AppDelegate。
    private func terminateIfAlreadyRunning() {
        guard let identifier = Bundle.main.bundleIdentifier else { return }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        guard !others.isEmpty else { return }
        NSLog("[DeepSeekFloat] 已有实例在运行（pid \(others[0].processIdentifier)），本实例退出")
        exit(0)
    }

    /// `kill -HUP <pid>` 立即刷新一次。
    /// 默认行为是终止进程，所以必须先忽略这个信号，再挂上自己的处理。
    /// 用途：脚本联动、以及不必等 60 秒定时器就能观察余额变化的效果。
    private func installReloadSignal() {
        signal(SIGHUP, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGHUP, queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            Task { @MainActor in await self.model.refresh(force: true) }
        }
        source.resume()
        reloadSignal = source
    }

    /// `kill -USR1 <pid>` 跑一次**动画抓帧探针**：注入一次余额扣费，
    /// 然后在动画面板的三个时间点各抓一帧到 /tmp。
    ///
    /// 存在的理由：终端没有「屏幕录制」授权，`ImageRenderer` 又只能出静态首帧，
    /// 于是"动画到底跑没跑"一直是个验证盲区——气泡不显示就是这么漏出去的。
    /// 渲染自己进程的视图层级不需要授权，靠它才能把中间帧抓出来。
    private func installProbeSignal() {
        signal(SIGUSR1, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        source.setEventHandler { [weak self] in self?.runAnimationProbe() }
        source.resume()
        probeSignal = source
    }

    private func runAnimationProbe() {
        guard let window = panelController?.window else { return }
        let injected = model.simulateBalanceChange(-0.07)
        NSLog("[DeepSeekFloat] 抓帧探针启动：注入扣费=\(injected)")

        // 0.10s 应已淡入、0.45s 上浮中、1.10s 应已淡出
        let marks: [(String, Double)] = [("t010", 0.10), ("t045", 0.45), ("t110", 1.10)]
        for (name, delay) in marks {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                let ok = LiveCapture.write(window, to: "/tmp/dsf-anim-\(name).png")
                NSLog("[DeepSeekFloat] 动画帧 \(name)：\(ok ? "已写出" : "失败")")
            }
        }
    }

    /// `kill -USR2 <pid>` 让**正在运行的 App 自己**投一条测试通知。
    ///
    /// 为什么不能直接在终端跑 `--notify-test`：终端的子进程不是 LaunchServices 登记的
    /// App 实例，`usernotificationd` 在那个上下文里会给出不可信的结果。
    /// 只有从 App 自己的进程发，才能真实反映通知链路是否可用。
    private func installNotifySignal() {
        signal(SIGUSR2, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGUSR2, queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            NSLog("[DeepSeekFloat] 收到 USR2，投递测试通知并写出诊断报告")
            Notifier.postTest(threshold: self.model.lowBalanceThreshold) { delivery in
                Notifier.authorizationStatus { status in
                    self.writeNotifyReport(delivery: delivery, status: status)
                }
            }
        }
        source.resume()
        notifySignal = source
    }

    /// 诊断报告落盘。
    /// 为什么不用 NSLog：`log show` 在沙箱里直接拒绝运行（"Cannot run while sandboxed"），
    /// 而 `open` 启动的 App 的 stderr 也拿不到。写文件是这里唯一可读的通道。
    private func writeNotifyReport(delivery: String, status: String) {
        let report = """
        bundle      : \(Bundle.main.bundlePath)
        identifier  : \(Bundle.main.bundleIdentifier ?? "?")
        通知权限    : \(status)
        投递结果    : \(delivery)
        时间        : \(Date())
        """
        try? report.write(toFile: "/tmp/dsf-notify-report.txt", atomically: true, encoding: .utf8)
    }

    /// `kill -WINCH <pid>` 切换一次「窗口永远置顶」，并把结果写进诊断文件。
    ///
    /// 存在的理由：这个开关的真实验证必须在**运行中**做——菜单栏我点不到，
    /// 而从命令行改偏好再启动只能测到初始状态，测不出「切换有没有即时效果」。
    private func installTopToggleSignal() {
        signal(SIGWINCH, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.model.alwaysOnTop.toggle()
            self.writeTopReport()
        }
        source.resume()
        topToggleSignal = source
    }

    private func writeTopReport() {
        let level = panelController?.window.level.rawValue ?? -1
        let visible = panelController?.isVisible ?? false
        let report = "alwaysOnTop=\(model.alwaysOnTop)  panel.level=\(level)  visible=\(visible)\n"
        let url = URL(fileURLWithPath: "/tmp/dsf-top-report.txt")
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        try? (existing + report).write(to: url, atomically: true, encoding: .utf8)
    }

    /// `kill -INFO <pid>` 柱状图生长探针：切一次时间范围触发重播，
    /// 然后抓 0.06 / 0.20 / 0.45 秒三帧。
    ///
    /// 为什么需要专用通道：生长动画只在视图重建时播一次，
    /// 静态渲染只能看到终态，普通抓帧又很难卡在头 0.5 秒里。
    private func installChartProbeSignal() {
        signal(SIGINFO, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGINFO, queue: .main)
        source.setEventHandler { [weak self] in self?.runChartProbe() }
        source.resume()
        chartProbeSignal = source
    }

    private func runChartProbe() {
        guard let window = panelController?.window else { return }
        let cases = UsageRange.allCases
        if let current = cases.firstIndex(of: model.range) {
            model.range = cases[(current + 1) % cases.count]
        }
        NSLog("[DeepSeekFloat] 柱状图生长探针：范围=\(model.range.title)")
        for (name, delay) in [("c006", 0.06), ("c020", 0.20), ("c045", 0.45)] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                _ = LiveCapture.write(window, to: "/tmp/dsf-anim-\(name).png")
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }
}
