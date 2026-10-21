import Foundation

/// DeepSeek 两个域名、两套凭据的访问层。
///
/// | 数据                    | 接口                                            | 凭据        |
/// |------------------------|------------------------------------------------|------------|
/// | 账户余额                 | `api.deepseek.com/user/balance`（官方公开）       | `sk-` API Key |
/// | token 用量 / 费用 / 缓存命中 | `platform.deepseek.com/api/v0/usage/*`（网页私有） | 网页登录态 userToken |
///
/// 用 `sk-` Key 去调平台用量接口会返回 `40003 invalid token`，这是接口设计如此，
/// 不是配置问题。所以余额与用量是两条独立通路，任意一条失败都不影响另一条。
enum DeepSeekAPI {

    private static let balanceURL = URL(string: "https://api.deepseek.com/user/balance")!
    private static let platformUsageBase = "https://platform.deepseek.com/api/v0/usage"

    // MARK: - URLSession

    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 20
        cfg.timeoutIntervalForResource = 40
        cfg.waitsForConnectivity = false
        cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        cfg.httpAdditionalHeaders = ["Connection": "close"]
        return URLSession(configuration: cfg)
    }()

    /// platform.deepseek.com 前面有 WAF，必须装成浏览器，否则直接被挡
    private static func platformHeaders(token: String) -> [String: String] {
        [
            "Authorization": "Bearer \(token)",
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36",
            "Accept": "application/json, text/plain, */*",
            "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8",
            "Origin": "https://platform.deepseek.com",
            "Referer": "https://platform.deepseek.com/usage",
        ]
    }

    private struct RawResponse {
        let status: Int
        let body: Data
        var text: String { String(data: body, encoding: .utf8) ?? "" }
        var looksLikeHTML: Bool {
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return t.hasPrefix("<") || t.contains("<html")
        }
    }

    private static func get(_ url: URL, headers: [String: String]) async throws -> RawResponse {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }

        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            return RawResponse(status: status, body: data)
        } catch let error as URLError {
            throw DSFloatError.network(error.localizedDescription)
        } catch {
            throw DSFloatError.network(error.localizedDescription)
        }
    }

    // MARK: - 余额

    static func fetchBalance(apiKey: String) async throws -> BalanceSnapshot {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw DSFloatError.missingAPIKey }

        let raw = try await get(balanceURL, headers: [
            "Authorization": "Bearer \(key)",
            "Accept": "application/json",
        ])

        switch raw.status {
        case 200:
            return try JSON.parseBalance(raw.body)
        case 401:
            throw DSFloatError.invalidAPIKey
        case 402:
            throw DSFloatError.insufficientBalance
        case 429:
            throw DSFloatError.rateLimited
        default:
            let msg = JSON.errorMessage(try? JSON.root(raw.body)) ?? raw.text.prefix(160).description
            throw DSFloatError.http(raw.status, msg)
        }
    }

    // MARK: - 用量：时间窗口（支持今日 / 24h / N 天）

    static func fetchWindowUsage(userToken: String, range: UsageRange, now: Date = Date()) async throws -> UsageSnapshot {
        let token = userToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw DSFloatError.missingUserToken }

        let window = range.window(now: now)
        let tzOffset = TimeZone.current.secondsFromGMT(for: now)
        let query = "start=\(window.start)&end=\(window.end)&tz=\(tzOffset)"

        // 平台有两族路径，`by_api_key` 是「按 API Key 筛选」视图。
        // 实测文档外的接口可能随时调整，所以按顺序回退。
        let amountPaths = ["/by_api_key/amount", "/amount"]
        let costPaths = ["/by_api_key/cost", "/cost"]

        let amount = try await firstSuccess(paths: amountPaths, query: query, token: token)
        let cost = try? await firstSuccess(paths: costPaths, query: query, token: token)

        return try JSON.makeUsageSnapshot(
            amountData: amount.body,
            costData: cost?.body,
            scopeNote: "平台账户 · \(range.title)"
        )
    }

    // MARK: - 用量：本月（带分模型与请求次数）

    static func fetchMonthlyUsage(userToken: String, now: Date = Date()) async throws -> UsageSnapshot {
        let token = userToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw DSFloatError.missingUserToken }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let comps = calendar.dateComponents([.year, .month], from: now)
        let query = "month=\(comps.month ?? 1)&year=\(comps.year ?? 2026)"

        let amount = try await firstSuccess(paths: ["/amount"], query: query, token: token)
        let cost = try? await firstSuccess(paths: ["/cost"], query: query, token: token)

        return try JSON.makeUsageSnapshot(
            amountData: amount.body,
            costData: cost?.body,
            scopeNote: "平台账户 · 本月分模型"
        )
    }

    // MARK: - 私有

    private static func firstSuccess(paths: [String], query: String, token: String) async throws -> RawResponse {
        var lastError: Error = DSFloatError.decoding("无可用路径")
        for path in paths {
            guard let url = URL(string: platformUsageBase + path + "?" + query) else { continue }
            do {
                return try await validatedPlatformGet(url: url, token: token)
            } catch let error as DSFloatError {
                lastError = error
                // 只有「路径不存在」才值得换下一条；认证/风控失败换路径也没用
                if case .http(let code, _) = error, code == 404 || code == 400 { continue }
                throw error
            }
        }
        throw lastError
    }

    private static func validatedPlatformGet(url: URL, token: String) async throws -> RawResponse {
        let raw = try await get(url, headers: platformHeaders(token: token))

        switch raw.status {
        case 200:
            let root = try? JSON.root(raw.body)
            let code = JSON.businessCode(root)
            if code == 40003 || code == 401 {
                throw DSFloatError.invalidUserToken
            }
            if code != 0, let msg = JSON.errorMessage(root) {
                throw DSFloatError.decoding(msg)
            }
            return raw
        case 401:
            throw DSFloatError.invalidUserToken
        case 403:
            throw raw.looksLikeHTML ? DSFloatError.wafBlocked : DSFloatError.invalidUserToken
        case 429:
            throw DSFloatError.rateLimited
        default:
            if raw.looksLikeHTML { throw DSFloatError.wafBlocked }
            let msg = JSON.errorMessage(try? JSON.root(raw.body)) ?? raw.text.prefix(160).description
            throw DSFloatError.http(raw.status, msg)
        }
    }
}
