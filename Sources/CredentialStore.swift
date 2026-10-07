import Foundation

/// 凭据存储。
///
/// 采用 0600 权限的本地文件（`~/Library/Application Support/DeepSeekFloat/credentials.json`），
/// 而不是钥匙串：本 App 以 ad-hoc 签名分发，每次重新编译 cdhash 都会变，
/// 钥匙串 ACL 会把新构建当成陌生程序反复弹窗甚至拒绝读取。同为本地小工具的同生态实现
/// （dsh-usage、deepseek-usage-monitor）也都是 0600 文件方案。
///
/// 文件里只有两样东西：`sk-` API Key 与 platform.deepseek.com 的网页会话令牌。
/// 两者都只发往 DeepSeek 官方域名，不做任何遥测。
final class CredentialStore {

    static let shared = CredentialStore()

    private struct Payload: Codable {
        var apiKey: String = ""
        var userToken: String = ""
    }

    private let fileManager = FileManager.default
    private var payload = Payload()
    private let lock = NSLock()

    private init() {
        load()
    }

    // MARK: - 路径

    var directoryURL: URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("DeepSeekFloat", isDirectory: true)
    }

    var fileURL: URL { directoryURL.appendingPathComponent("credentials.json") }

    // MARK: - 读取

    private func load() {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(Payload.self, from: data) else { return }
        payload = decoded
    }

    private func persist() {
        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(payload)
            try data.write(to: fileURL, options: [.atomic])
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            NSLog("[DeepSeekFloat] 凭据写入失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 对外

    var apiKey: String {
        lock.lock(); defer { lock.unlock() }
        if !payload.apiKey.isEmpty { return payload.apiKey }
        // 环境变量回退：方便脚本/终端直接带凭据启动，也兼容 DSH 的既有习惯
        return Self.env(["DEEPSEEK_API_KEY", "DSF_API_KEY"])
    }

    var userToken: String {
        lock.lock(); defer { lock.unlock() }
        if !payload.userToken.isEmpty { return payload.userToken }
        return Self.env(["DEEPSEEK_USER_TOKEN", "DSF_USER_TOKEN"])
    }

    private static func env(_ names: [String]) -> String {
        let environment = ProcessInfo.processInfo.environment
        for name in names {
            if let value = environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                return value
            }
        }
        return ""
    }

    var hasAPIKey: Bool { !apiKey.trimmingCharacters(in: .whitespaces).isEmpty }
    var hasUserToken: Bool { !userToken.trimmingCharacters(in: .whitespaces).isEmpty }

    func setAPIKey(_ value: String) {
        lock.lock()
        payload.apiKey = value.trimmingCharacters(in: .whitespacesAndNewlines)
        lock.unlock()
        persist()
    }

    func setUserToken(_ value: String) {
        lock.lock()
        payload.userToken = normalizeToken(value)
        lock.unlock()
        persist()
    }

    /// 用户从浏览器控制台粘过来的可能是 `{"value":"..."}` 或带引号的原文，这里统一剥壳
    private func normalizeToken(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("{"), let data = s.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let v = obj["value"] as? String {
            s = v
        }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "\"' \n\r\t"))
        return s
    }

    func clearAll() {
        lock.lock()
        payload = Payload()
        lock.unlock()
        persist()
    }

    /// 出于 UI 展示目的给出的脱敏串
    func maskedAPIKey() -> String {
        let key = apiKey
        guard key.count > 10 else { return key.isEmpty ? "" : "••••" }
        return key.prefix(6) + "••••••" + key.suffix(4)
    }

    // MARK: - 从 DSH 导入

    /// 本机 DSH（DeepSeek Harness）的凭据文件里已经存了一份 `DEEPSEEK_API_KEY`，
    /// 直接复用可以省掉一次手工复制。只读取、不写回、不上传。
    static func importAPIKeyFromDSH() -> String? {
        let home = ProcessInfo.processInfo.environment["DSH_HOME"]
            ?? (NSHomeDirectory() + "/.dsh")
        let candidates = [
            home + "/.credentials.yaml",
            home + "/credentials.yaml",
        ]
        for path in candidates {
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            for rawLine in text.split(separator: "\n") {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                guard let range = line.range(of: "DEEPSEEK_API_KEY:") else { continue }
                var value = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                if value.hasPrefix("sk-"), value.count > 12 { return value }
            }
        }
        return nil
    }

    /// 同时给出 DSH 里是否存在该凭据，用于 UI 决定是否显示「从 DSH 导入」按钮
    static var dshCredentialFileExists: Bool {
        let home = ProcessInfo.processInfo.environment["DSH_HOME"]
            ?? (NSHomeDirectory() + "/.dsh")
        return FileManager.default.fileExists(atPath: home + "/.credentials.yaml")
    }
}
