import Foundation
import AppKit
import UserNotifications

/// 低余额系统通知。
///
/// 走 UNUserNotificationCenter：需要 App 以 .app bundle 形式运行并已获得授权。
/// 未签名/ad-hoc 签名且未安装到 /Applications 时可能静默失败，所以全部包在 do/catch 里，
/// 通知失败绝不能影响主功能。
enum Notifier {

    private static var didRequest = false

    static func requestAuthorization() {
        guard !didRequest else { return }
        didRequest = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, error in
            if let error { NSLog("[DeepSeekFloat] 通知授权失败：\(error.localizedDescription)") }
        }
    }

    /// 当前授权状态。未安装到 /Applications、或 ad-hoc 签名未被 LaunchServices 登记时，
    /// 系统会直接拒绝，这里如实报出来。
    static func authorizationStatus(_ completion: @escaping (String) -> Void) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let text: String
            switch settings.authorizationStatus {
            case .authorized, .provisional:
                text = "已授权"
            case .denied:
                text = "被拒绝（到「系统设置 → 通知」里允许本 App）"
            case .notDetermined:
                text = "尚未申请"
            @unknown default:
                text = "未知状态"
            }
            DispatchQueue.main.async { completion(text) }
        }
    }

    static func lowBalance(amount: Double, currency: String, threshold: Double) {
        // 先问权限。没有权限时不要白白发一条永远不显示的请求——那才是真正的静默失败。
        authorizationStatus { status in
            if status == "已授权" {
                deliver(amount: amount, currency: currency, threshold: threshold)
            } else {
                // 退路：系统提示音不需要任何权限。
                // 面板本身还会进入呼吸红边告警态（见 WidgetView），那条是常驻可见的。
                NSLog("[DeepSeekFloat] 无通知权限（\(status)），退化为系统提示音")
                NSSound.beep()
            }
        }
    }

    private static func deliver(amount: Double, currency: String, threshold: Double) {
        let content = UNMutableNotificationContent()
        content.title = "DeepSeek 余额不足"
        content.body = "当前余额 \(Fmt.moneyCompact(amount, currency: currency))，已低于提醒阈值 \(Fmt.moneyCompact(threshold, currency: currency))。"
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "low-balance-\(Int(Date().timeIntervalSince1970))",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error { NSLog("[DeepSeekFloat] 通知投递失败：\(error.localizedDescription)") }
        }
    }

    /// 立刻投递一条测试通知，用来端到端确认通知真的能弹出来。
    /// 通知是静默失败重灾区：没权限时 `add` 既不报错也什么都不发生，
    /// 所以必须有一个「我现在就要看到一条」的入口。
    static func postTest(
        amount: Double = 3.21,
        currency: String = "CNY",
        threshold: Double = 5,
        completion: ((String) -> Void)? = nil
    ) {
        let content = UNMutableNotificationContent()
        content.title = "DeepSeek 悬浮窗 · 测试通知"
        content.body = "如果你看到这条，说明低余额提醒可以正常工作。（示例余额 \(Fmt.moneyCompact(amount, currency: currency)) < 阈值 \(Fmt.moneyCompact(threshold, currency: currency))）"
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "test-\(Int(Date().timeIntervalSince1970))",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            let result: String
            if let error {
                result = "add() 报错：\(error.localizedDescription)"
                NSLog("[DeepSeekFloat] 测试通知投递失败：\(error.localizedDescription)")
            } else {
                result = "add() 无错误（最终是否显示由系统决定）"
                NSLog("[DeepSeekFloat] 测试通知已投递")
            }
            DispatchQueue.main.async { completion?(result) }
        }
    }

    // MARK: - 命令行接口

    /// `DeepSeekFloat --notify-status`
    ///
    /// ⚠️ **这个值只在 App 自身进程里可信**。从终端直接执行二进制时，进程不是
    /// LaunchServices 登记的 App 实例，`getNotificationSettings` 往往直接回一个
    /// 合成的 `.denied`，即使实际权限正常。要判断真实情况请看 App 设置页，
    /// 或者用 `--notify-test` 投一条看看会不会弹。
    static func runCLIStatus() -> Int32 {
        let semaphore = DispatchSemaphore(value: 0)
        var text = "未知"
        var authorized = false

        UNUserNotificationCenter.current().getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional:
                text = "已授权"; authorized = true
            case .denied:
                text = "被系统拒绝"
            case .notDetermined:
                text = "尚未申请（首次启动会弹窗询问）"
            @unknown default:
                text = "未知状态"
            }
            semaphore.signal()
        }

        // 回调在框架自己的队列上，不是主队列，这里等待不会死锁；
        // 3 秒兜底，万一 usernotificationd 没响应也不至于挂住脚本
        _ = semaphore.wait(timeout: .now() + 3)
        print("通知权限：\(text)（命令行上下文查询，可能不准；以 App 设置页为准）")
        return authorized ? 0 : 1
    }

    /// `DeepSeekFloat --notify-test`：投一条测试通知
    static func runCLITest() -> Int32 {
        postTest()
        print("已请求投递一条测试通知；若 5 秒内没有横幅，检查「系统设置 → 通知」里是否允许了「DeepSeek 悬浮窗」")
        // 给 usernotificationd 一点时间落库
        Thread.sleep(forTimeInterval: 1.5)
        return 0
    }
}
