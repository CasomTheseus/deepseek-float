import Foundation
import ServiceManagement

/// 开机自启。macOS 13+ 走 SMAppService；失败只记日志，不打扰用户。
///
/// 注意：`SMAppService.mainApp` 依赖 LaunchServices 对这个 .app 的登记，
/// 因此**必须先 `./build.sh install` 装到 /Applications**；从 build/ 里直接跑通常注册不上。
enum LaunchAtLogin {

    static var isEnabled: Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }

    static func set(_ enabled: Bool) {
        guard #available(macOS 13.0, *) else { return }
        let service = SMAppService.mainApp
        do {
            if enabled {
                guard service.status != .enabled else { return }
                try service.register()
            } else {
                guard service.status == .enabled else { return }
                try service.unregister()
            }
        } catch {
            // 未安装到 /Applications 或签名不被 LaunchServices 接受时会走到这里
            NSLog("[DeepSeekFloat] 开机自启设置失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 命令行接口

    /// `DeepSeekFloat --login-item status|enable|disable`
    ///
    /// 存在的理由：开机自启是那种「界面上看着开了、实际没注册」也不会报错的功能，
    /// 必须有办法从终端查到真实注册状态；安装/卸载脚本也依赖它。
    static func runCLI(_ action: String) -> Int32 {
        guard #available(macOS 13.0, *) else {
            print("开机自启需要 macOS 13 或更高版本")
            return 1
        }
        let service = SMAppService.mainApp
        switch action {
        case "status":
            print("开机自启：\(describe(service.status))")
            return service.status == .enabled ? 0 : 1
        case "enable":
            do {
                try service.register()
                print("开机自启：\(describe(service.status))")
                return service.status == .enabled ? 0 : 1
            } catch {
                print("注册失败：\(error.localizedDescription)")
                return 1
            }
        case "disable":
            do {
                try service.unregister()
                print("开机自启：\(describe(service.status))")
                return 0
            } catch {
                // 本来就没注册时 unregister 会抛错，这不算失败
                print("已确认为未注册状态（\(error.localizedDescription)）")
                return 0
            }
        default:
            print("用法：--login-item status|enable|disable")
            return 2
        }
    }

    @available(macOS 13.0, *)
    private static func describe(_ status: SMAppService.Status) -> String {
        switch status {
        case .enabled: return "已启用"
        case .notRegistered: return "未注册"
        case .requiresApproval: return "等待用户在「系统设置 → 通用 → 登录项」中批准"
        case .notFound:
            // 注意：App 尚未注册时，从命令行查询也会落到这一项，即使它就在 /Applications。
            // 所以文案不能写成「找不到 App」——那会让人以为安装失败了。
            return "未注册（在菜单栏里开启一次即可；已装到 /Applications 时属正常现象）"
        @unknown default: return "未知状态"
        }
    }
}
