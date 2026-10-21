import AppKit
import SwiftUI

// 入口。不用 SwiftUI 的 App 生命周期：悬浮窗需要对 NSPanel 做精细控制
// （非激活面板、跨 Space、置顶层级），NSApplication + AppDelegate 更直接。
@main
struct DeepSeekFloatApp {
    @MainActor
    static func main() async {
        let arguments = CommandLine.arguments

        // 开机自启的真实注册状态，供安装/卸载脚本与人工核查
        //   --login-item status|enable|disable
        if let index = arguments.firstIndex(of: "--login-item") {
            let action = index + 1 < arguments.count ? arguments[index + 1] : "status"
            exit(LaunchAtLogin.runCLI(action))
        }

        // 通知权限的真实状态（典型的静默失败功能，必须能查）
        if arguments.contains("--notify-status") {
            exit(Notifier.runCLIStatus())
        }

        // 投一条测试通知，端到端确认通知链路
        if arguments.contains("--notify-test") {
            exit(Notifier.runCLITest())
        }

        // 解析器夹具测试：离线校验两族接口的响应形状
        if arguments.contains("--parsetest") {
            exit(ParserTests.run() == 0 ? 0 : 1)
        }

        // 本地日志源：把真实 DSH 日志读一遍并打印汇总，用于验收取数是否正确
        if arguments.contains("--logtest") {
            await runLogTest()
            exit(0)
        }

        // 无头自检：不建窗口、不装菜单栏，跑完就退
        if arguments.contains("--selftest") {
            await SelfTest.run()
            exit(0)
        }

        // 离屏渲染：把面板画成 PNG。不依赖「屏幕录制」权限，用于验收排版。
        //   --render out.png [--settings] [--collapsed] [--empty] [--daily] [--bars] [--low] [--bars|--heat] [--peak|--offpeak] [--localsrc]
        if let index = arguments.firstIndex(of: "--render") {
            let path = index + 1 < arguments.count ? arguments[index + 1] : "widget.png"
            renderSnapshot(
                to: path,
                settings: arguments.contains("--settings"),
                collapsed: arguments.contains("--collapsed"),
                empty: arguments.contains("--empty"),
                daily: arguments.contains("--daily"),
                localSrc: arguments.contains("--localsrc"),
                bars: arguments.contains("--bars"),
                heat: arguments.contains("--heat"),
                low: arguments.contains("--low"),
                forcePeak: arguments.contains("--peak"),
                forceOffPeak: arguments.contains("--offpeak")
            )
            exit(0)
        }

        let app = NSApplication.shared
        // --demo：用示例数据跑 GUI（不联网、不读真实凭据），用于录屏 / 截图 / 抓动画帧。
        // 没有它就只能拿真账号跑，截图里会带上真实余额。
        // --peak / --offpeak：强制峰谷状态，方便在非对应时段预览另一种价签
        // （比如现在是空闲时段，想看看高峰的红「峰」长什么样）。
        let delegate = AppDelegate(
            demo: arguments.contains("--demo"),
            peakOverride: arguments.contains("--peak") ? true
                : (arguments.contains("--offpeak") ? false : nil),
            openSettings: arguments.contains("--settings")
        )
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    /// 把真实 DSH 日志读一遍并打印汇总。
    /// 断言只能用合成夹具（不能把真实会话内容写进测试），
    /// 所以真实数据的口径要靠这个入口人工核对。
    @MainActor
    private static func runLogTest() async {
        for range in [UsageRange.today, .last24h, .last7d, .last30d] {
            do {
                let snapshot = try await DSHLogSource.shared.snapshot(for: range)
                let totals = snapshot.totals
                print("── \(range.title) ──")
                print("  命中 \(totals.cacheHit)  未命中 \(totals.cacheMiss)  输出 \(totals.output)  合计 \(totals.totalTokens)")
                print("  命中率 \(String(format: "%.1f%%", totals.cacheHitRate * 100))  请求 \(totals.requests)")
                print("  分桶 \(snapshot.buckets.count)  金额 \(snapshot.hasCost ? "有" : "无（符合预期）")")
                let models = snapshot.models
                    .map { "\($0.model)=\($0.breakdown.totalTokens)" }
                    .joined(separator: "  ")
                print("  模型 \(models.isEmpty ? "—" : models)")
                if let first = snapshot.buckets.first, let last = snapshot.buckets.last,
                   snapshot.buckets.count > 1 {
                    let step = Int((last.time - first.time) / Double(snapshot.buckets.count - 1))
                    print("  区间 \(stamp(first.time)) → \(stamp(last.time))  步长约 \(step) 秒")
                }
            } catch {
                print("── \(range.title) ── 失败：\(error.localizedDescription)")
            }
            print("")
        }
    }

    private static func stamp(_ epoch: Double) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: Date(timeIntervalSince1970: epoch))
    }

    /// 用示例数据把 `WidgetView` 画成 PNG（2 倍图）。
    /// 注意：离屏渲染拿不到 `NSVisualEffectView` 的真实模糊，背景会退化成渐变，
    /// 但排版、字号、颜色、图表都是真实结果。
    @MainActor
    private static func renderSnapshot(to path: String, settings: Bool, collapsed: Bool, empty: Bool, daily: Bool, localSrc: Bool, bars: Bool, heat: Bool, low: Bool, forcePeak: Bool, forceOffPeak: Bool) {
        let model = AppModel(startAutomatically: false, withSampleData: !empty,
                             sampleDaily: daily, sampleLocalSource: localSrc)
        model.showSettings = settings
        model.expanded = !collapsed
        // chartMode 现在来自偏好；文档截图要可复现，所以两个模式都能显式指定
        if bars { model.chartMode = .bars }
        if heat { model.chartMode = .heat }
        // 把余额压到阈值以下，用来验收低余额告警态（呼吸红边）
        if low { _ = model.simulateBalanceChange(-341.51) }
        // 强制峰谷，用来在同一时刻把两种单字价签都截出来验收
        if forcePeak { model.peakOverride = true }
        if forceOffPeak { model.peakOverride = false }
        let renderer = ImageRenderer(
            content: WidgetView()
                .environmentObject(model)
                .environment(\.snapshotMode, true)
        )
        renderer.scale = 2

        guard let cgImage = renderer.cgImage else {
            FileHandle.standardError.write(Data("渲染失败\n".utf8))
            exit(1)
        }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("PNG 编码失败\n".utf8))
            exit(1)
        }
        do {
            try data.write(to: URL(fileURLWithPath: path))
            print("已写出 \(path)  (\(cgImage.width)×\(cgImage.height))")
        } catch {
            FileHandle.standardError.write(Data("写入失败：\(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}
