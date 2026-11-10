import Foundation

private final class MockURLProtocol: URLProtocol {
    struct Response {
        let status: Int
        let body: String
        var headers: [String: String] = [:]
    }

    static var handler: ((URLRequest) throws -> Response)?
    static var delay: TimeInterval = 0
    static var requestPaths: [String] = []
    static var lastAuthorization: String?
    private var stopped = false

    static func reset() {
        handler = nil
        delay = 0
        requestPaths = []
        lastAuthorization = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requestPaths.append(request.url?.path ?? "")
        Self.lastAuthorization = request.value(forHTTPHeaderField: "Authorization")
        if Self.delay > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.delay) { [weak self] in self?.respond() }
        } else {
            respond()
        }
    }

    override func stopLoading() { stopped = true }

    private func respond() {
        guard !stopped, let handler = Self.handler else { return }
        do {
            let mock = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: mock.status,
                                           httpVersion: nil, headerFields: mock.headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(mock.body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
}

/// 离线回归测试：`DeepSeekFloat --parsetest`
///
/// 平台的用量接口是未公开接口，因此把真实响应形状固化成夹具，并用伪 URL 响应
/// 覆盖状态码、请求头、路径回退和取消，无需真实账号或联网。
/// 尤其覆盖「`total` 与 `days` 不能相加」这条最容易写错、且错了会翻倍计费的规则。
enum ParserTests {

    private static var failures = 0
    private static var checks = 0

    @MainActor
    static func run() async -> Int {
        failures = 0
        checks = 0

        print("── 离线回归测试 ──")

        balance()
        windowAmount()
        monthlyAmount()
        monthlyCost()
        lowercaseTypes()
        missingFields()
        refreshBackoff()
        await refreshRace()
        await networkTransport()
        credentials()
        peakSchedule()
        balanceDelta()
        simulatePath()
        localLogUsage()
        idleFade()
        balanceTrend()

        print("")
        print(failures == 0 ? "结果：\(checks) 项断言全部通过。" : "结果：\(checks) 项断言中 \(failures) 项失败。")
        return failures
    }

    // MARK: - 夹具

    /// 官方 `GET /user/balance`
    private static let balanceJSON = """
    {"is_available":true,"balance_infos":[
      {"currency":"CNY","total_balance":"343.91","granted_balance":"0.00","topped_up_balance":"343.91"}]}
    """

    /// `usage/by_api_key/amount`：total 给总账，series 给趋势
    private static let windowAmountJSON = """
    {"code":0,"data":{"biz_data":{"bucket":"1d","models":["deepseek-chat","deepseek-reasoner"],
      "total":[
        {"model":"deepseek-chat","usage":[{"type":"PROMPT_CACHE_HIT_TOKEN","amount":120000},
                                          {"type":"PROMPT_CACHE_MISS_TOKEN","amount":30000},
                                          {"type":"COMPLETION_TOKEN","amount":8000}]},
        {"model":"deepseek-reasoner","usage":[{"type":"PROMPT_CACHE_HIT_TOKEN","amount":45000},
                                              {"type":"PROMPT_CACHE_MISS_TOKEN","amount":12000},
                                              {"type":"COMPLETION_TOKEN","amount":5000}]}],
      "series":[
        {"model":"deepseek-chat","buckets":[{"time":1767225600,"usage":{"PROMPT_CACHE_HIT_TOKEN":120000,"PROMPT_CACHE_MISS_TOKEN":30000,"COMPLETION_TOKEN":8000}}]},
        {"model":"deepseek-reasoner","buckets":[{"time":1767225600,"usage":{"PROMPT_CACHE_HIT_TOKEN":45000,"PROMPT_CACHE_MISS_TOKEN":12000,"COMPLETION_TOKEN":5000}}]}]}}}
    """

    /// `usage/by_api_key/cost`：biz_data.data[].total + .series[].buckets[].cost
    private static let windowCostJSON = """
    {"code":0,"data":{"biz_data":{"data":[{"currency":"CNY",
      "total":[
        {"model":"deepseek-chat","usage":[{"type":"PROMPT_CACHE_HIT_TOKEN","amount":0.012}]},
        {"model":"deepseek-reasoner","usage":[{"type":"PROMPT_CACHE_HIT_TOKEN","amount":0.0045}]}],
      "series":[{"buckets":[{"time":1767225600,"cost":0.0165}]}]}]}}}
    """

    /// `usage/amount?month=&year=`：total 是月总账，days 是同批数据按天切
    private static let monthlyAmountJSON = """
    {"code":0,"data":{"biz_data":{
      "total":[{"model":"deepseek-chat","usage":[{"type":"REQUEST","amount":120},
                                                {"type":"PROMPT_CACHE_HIT_TOKEN","amount":500000},
                                                {"type":"PROMPT_CACHE_MISS_TOKEN","amount":120000},
                                                {"type":"RESPONSE_TOKEN","amount":40000}]}],
      "days":[
        {"date":"2026-01-05","data":[{"model":"deepseek-chat","usage":[{"type":"REQUEST","amount":60},
                                                                     {"type":"PROMPT_CACHE_HIT_TOKEN","amount":200000},
                                                                     {"type":"PROMPT_CACHE_MISS_TOKEN","amount":50000},
                                                                     {"type":"RESPONSE_TOKEN","amount":20000}]}]},
        {"date":"2026-01-06","data":[{"model":"deepseek-chat","usage":[{"type":"REQUEST","amount":60},
                                                                     {"type":"PROMPT_CACHE_HIT_TOKEN","amount":300000},
                                                                     {"type":"PROMPT_CACHE_MISS_TOKEN","amount":70000},
                                                                     {"type":"RESPONSE_TOKEN","amount":20000}]}]}]}}}
    """

    /// `usage/cost?month=&year=`：biz_data 直接是数组
    private static let monthlyCostJSON = """
    {"code":0,"data":{"biz_data":[{"currency":"CNY",
      "total":[{"model":"deepseek-chat","usage":[{"type":"REQUEST","amount":120},
                                                {"type":"PROMPT_CACHE_HIT_TOKEN","amount":0.05},
                                                {"type":"PROMPT_CACHE_MISS_TOKEN","amount":0.12}]}],
      "days":[
        {"date":"2026-01-05","data":[{"model":"deepseek-chat","usage":[{"type":"PROMPT_CACHE_HIT_TOKEN","amount":0.02},
                                                                      {"type":"PROMPT_CACHE_MISS_TOKEN","amount":0.05}]}]},
        {"date":"2026-01-06","data":[{"model":"deepseek-chat","usage":[{"type":"PROMPT_CACHE_HIT_TOKEN","amount":0.03},
                                                                      {"type":"PROMPT_CACHE_MISS_TOKEN","amount":0.07}]}]}]}]}}
    """

    /// 导出 CSV 那一族的列名（小写下划线）
    private static let lowercaseJSON = """
    {"data":{"biz_data":{"total":[{"model":"deepseek-chat","usage":[
      {"type":"input_cache_hit_tokens","amount":10},
      {"type":"input_cache_miss_tokens","amount":4},
      {"type":"output_tokens","amount":2},
      {"type":"request_count","amount":3}]}]}}}
    """

    private static let emptyJSON = """
    {"code":0,"data":{"biz_data":{}}}
    """

    // MARK: - 用例

    private static func balance() {
        do {
            let snapshot = try JSON.parseBalance(Data(balanceJSON.utf8))
            check("balance.isAvailable", snapshot.isAvailable == true)
            check("balance.currency", snapshot.primary?.currency == "CNY")
            check("balance.total", snapshot.primary?.total == 343.91, "\(snapshot.primary?.total ?? -1)")
            check("balance.toppedUp", snapshot.primary?.toppedUp == 343.91)
            check("balance.granted", snapshot.primary?.granted == 0)
        } catch {
            check("balance 解析抛错", false, "\(error)")
        }
    }

    private static func windowAmount() {
        let snapshot = snapshotFor(amount: windowAmountJSON, cost: windowCostJSON)
        guard let snapshot else { return }
        check("window.totals.cacheHit", snapshot.totals.cacheHit == 165_000, "\(snapshot.totals.cacheHit)")
        check("window.totals.cacheMiss", snapshot.totals.cacheMiss == 42_000, "\(snapshot.totals.cacheMiss)")
        check("window.totals.output", snapshot.totals.output == 13_000, "\(snapshot.totals.output)")
        check("window.totals 未与 series 重复计数",
              snapshot.totals.totalTokens == 220_000, "\(snapshot.totals.totalTokens)")
        check("window.models 数量", snapshot.models.count == 2, "\(snapshot.models.count)")
        check("window.models.chat",
              snapshot.models.first(where: { $0.model == "deepseek-chat" })?.breakdown.cacheHit == 120_000)
        check("window.buckets 数量", snapshot.buckets.count == 1, "\(snapshot.buckets.count)")
        check("window.buckets[0].total",
              snapshot.buckets.first?.breakdown.totalTokens == 220_000,
              "\(snapshot.buckets.first?.breakdown.totalTokens ?? -1)")

        // 费用：total 与 series 只能取其一
        check("window.cost 未翻倍", abs(snapshot.cost - 0.0165) < 1e-9, "\(snapshot.cost)")
        check("window.currency", snapshot.currency == "CNY", snapshot.currency)
        check("window.cost bucket", abs((snapshot.buckets.first?.cost ?? 0) - 0.0165) < 1e-9)
        check("window.cost 分模型",
              abs((snapshot.models.first(where: { $0.model == "deepseek-chat" })?.cost ?? 0) - 0.012) < 1e-9)
    }

    private static func monthlyAmount() {
        let snapshot = snapshotFor(amount: monthlyAmountJSON, cost: monthlyCostJSON)
        guard let snapshot else { return }
        check("monthly.totals.cacheHit", snapshot.totals.cacheHit == 500_000, "\(snapshot.totals.cacheHit)")
        check("monthly.totals.cacheMiss", snapshot.totals.cacheMiss == 120_000, "\(snapshot.totals.cacheMiss)")
        check("monthly.totals.output", snapshot.totals.output == 40_000, "\(snapshot.totals.output)")
        check("monthly.totals.requests", snapshot.totals.requests == 120, "\(snapshot.totals.requests)")
        check("monthly.totals 未与 days 重复计数",
              snapshot.totals.totalTokens == 660_000, "\(snapshot.totals.totalTokens)")
        check("monthly.buckets 数量", snapshot.buckets.count == 2, "\(snapshot.buckets.count)")
        check("monthly 单日 token",
              snapshot.buckets.map { $0.breakdown.totalTokens }.reduce(0, +) == 660_000)
        check("monthly.models 数量", snapshot.models.count == 1, "\(snapshot.models.count)")
    }

    private static func monthlyCost() {
        let snapshot = snapshotFor(amount: monthlyAmountJSON, cost: monthlyCostJSON)
        guard let snapshot else { return }
        check("monthly.cost 未翻倍", abs(snapshot.cost - 0.17) < 1e-9, "\(snapshot.cost)")
        check("monthly.currency", snapshot.currency == "CNY", snapshot.currency)
        check("monthly.cost buckets 求和",
              abs(snapshot.buckets.map { $0.cost }.reduce(0, +) - 0.17) < 1e-9,
              "\(snapshot.buckets.map { $0.cost }.reduce(0, +))")
        check("monthly.cost 分模型",
              abs((snapshot.models.first?.cost ?? 0) - 0.17) < 1e-9,
              "\(snapshot.models.first?.cost ?? -1)")
    }

    private static func lowercaseTypes() {
        let snapshot = snapshotFor(amount: lowercaseJSON, cost: nil)
        guard let snapshot else { return }
        check("lowercase.cacheHit", snapshot.totals.cacheHit == 10, "\(snapshot.totals.cacheHit)")
        check("lowercase.cacheMiss", snapshot.totals.cacheMiss == 4, "\(snapshot.totals.cacheMiss)")
        check("lowercase.output", snapshot.totals.output == 2, "\(snapshot.totals.output)")
        check("lowercase.requests", snapshot.totals.requests == 3, "\(snapshot.totals.requests)")
    }

    private static func missingFields() {
        let snapshot = snapshotFor(amount: emptyJSON, cost: nil)
        guard let snapshot else { return }
        check("空响应不崩且为空", snapshot.isEmpty)

        do {
            _ = try JSON.parseBalance(Data("{\"balance_infos\":[]}".utf8))
            check("空 balance_infos 应抛错", false)
        } catch {
            check("空 balance_infos 抛错", true)
        }

        let errorRoot = try? JSON.root(Data("{\"error\":{\"message\":\"Authentication Fails\",\"type\":\"authentication_error\",\"code\":\"invalid_request_error\"}}".utf8))
        check("官方错误信封可识别",
              JSON.errorMessage(errorRoot)?.contains("Authentication Fails") == true)
        check("平台业务码可识别",
              JSON.businessCode(try? JSON.root(Data("{\"code\":40003,\"msg\":\"invalid token\"}".utf8))) == 40003)
    }

    // MARK: - 刷新退避

    private static func refreshBackoff() {
        check("backoff.首次失败下限", RefreshBackoff.delay(failureCount: 1, jitter: 0) == 12)
        check("backoff.首次失败上限", abs(RefreshBackoff.delay(failureCount: 1, jitter: 1) - 18) < 0.0001)
        check("backoff.第二次指数增长", RefreshBackoff.delay(failureCount: 2, jitter: 0.5) == 30)
        check("backoff.退避封顶", RefreshBackoff.delay(failureCount: 20, jitter: 1) == 300)
        check("backoff.优先 Retry-After", RefreshBackoff.delay(failureCount: 3, retryAfter: 42) == 42)
        check("backoff.Retry-After 同样封顶", RefreshBackoff.delay(failureCount: 1, retryAfter: 900) == 300)

        let now = Date(timeIntervalSince1970: 0)
        check("backoff.解析秒数", RefreshBackoff.retryAfter(from: " 30 ", now: now) == 30)
        let httpDate = "Thu, 01 Jan 1970 00:01:00 GMT"
        check("backoff.解析 HTTP 日期", RefreshBackoff.retryAfter(from: httpDate, now: now) == 60)
        check("backoff.拒绝非法值", RefreshBackoff.retryAfter(from: "later", now: now) == nil)
        check("backoff.503 可重试", DSFloatError.http(503, "").isTransient)
        check("backoff.400 不退避", !DSFloatError.http(400, "").isTransient)
        check("backoff.保留服务端等待时间", DSFloatError.rateLimited(retryAfter: 9).retryAfter == 9)
    }

    // MARK: - 刷新竞态

    @MainActor
    private static func refreshRace() async {
        func snapshot(_ note: String) -> UsageSnapshot {
            var value = UsageSnapshot()
            value.scopeNote = note
            value.totals = TokenBreakdown(cacheHit: 10, cacheMiss: 2, output: 1)
            return value
        }

        for oldRequestFails in [false, true] {
            let model = AppModel(
                startAutomatically: false,
                withSampleData: false,
                usageFetcher: { _, requestedRange in
                    if requestedRange == .today {
                        try await Task.sleep(nanoseconds: 250_000_000)
                        if oldRequestFails { throw DSFloatError.network("旧请求延迟失败") }
                        return snapshot("旧平台响应")
                    }
                    return snapshot("平台响应")
                },
                localUsageFetcher: { requestedRange in
                    snapshot("本机 DSH 全会话 · \(requestedRange.title)")
                }
            )
            model.setCredentialFlagsForTesting(apiKey: false, userToken: true)
            model.usageSource = .platform
            model.range = .today

            let oldRequest = Task { await model.refreshUsage(force: true) }
            try? await Task.sleep(nanoseconds: 50_000_000)
            model.usageSource = .localLog
            model.range = .last7d
            await model.refreshUsage(force: true)
            await oldRequest.value

            let phase = oldRequestFails ? "旧失败" : "旧成功"
            check("race.\(phase)响应不覆盖新来源", model.usage?.scopeNote == "本机 DSH 全会话 · 7天",
                  model.usage?.scopeNote ?? "nil")
            check("race.\(phase)响应不污染新错误态", model.usageError == nil,
                  model.usageError ?? "nil")
        }
    }

    // MARK: - 网络传输层

    @MainActor
    private static func networkTransport() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        DeepSeekAPI.setSessionForTesting(session)
        defer {
            DeepSeekAPI.setSessionForTesting(nil)
            session.finishTasksAndInvalidate()
        }

        func expectError(_ label: String,
                         _ operation: () async throws -> Void,
                         _ matches: (DSFloatError) -> Bool) async {
            do {
                try await operation()
                check(label, false, "请求意外成功")
            } catch let error as DSFloatError {
                check(label, matches(error), error.errorDescription ?? "\(error)")
            } catch {
                check(label, false, "错误类型 \(error)")
            }
        }

        MockURLProtocol.reset()
        MockURLProtocol.handler = { _ in .init(status: 200, body: balanceJSON) }
        do {
            let result = try await DeepSeekAPI.fetchBalance(apiKey: "sk-test")
            check("transport.余额 200 解析", result.primary?.total == 343.91)
            check("transport.余额 Authorization 头", MockURLProtocol.lastAuthorization == "Bearer sk-test")
        } catch {
            check("transport.余额 200 解析", false, "\(error)")
        }

        MockURLProtocol.reset()
        MockURLProtocol.handler = { _ in
            .init(status: 429, body: "{}", headers: ["Retry-After": "17"])
        }
        await expectError("transport.429 保留数字 Retry-After", {
            _ = try await DeepSeekAPI.fetchBalance(apiKey: "sk-test")
        }, {
            if case .rateLimited(let retryAfter) = $0 { return retryAfter == 17 }
            return false
        })

        let httpDate = DateFormatter()
        httpDate.locale = Locale(identifier: "en_US_POSIX")
        httpDate.timeZone = TimeZone(secondsFromGMT: 0)
        httpDate.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        MockURLProtocol.reset()
        MockURLProtocol.handler = { _ in
            .init(status: 429, body: "{}",
                  headers: ["Retry-After": httpDate.string(from: Date().addingTimeInterval(30))])
        }
        await expectError("transport.429 解析 HTTP 日期", {
            _ = try await DeepSeekAPI.fetchBalance(apiKey: "sk-test")
        }, {
            if case .rateLimited(let retryAfter) = $0 {
                guard let retryAfter else { return false }
                return (25...31).contains(retryAfter)
            }
            return false
        })

        MockURLProtocol.reset()
        MockURLProtocol.handler = { request in
            switch request.url?.path {
            case "/api/v0/usage/by_api_key/amount":
                return .init(status: 404, body: "missing")
            case "/api/v0/usage/amount":
                return .init(status: 200, body: windowAmountJSON)
            case "/api/v0/usage/by_api_key/cost":
                return .init(status: 404, body: "missing")
            case "/api/v0/usage/cost":
                return .init(status: 200, body: windowCostJSON)
            default:
                return .init(status: 500, body: "unexpected")
            }
        }
        do {
            let result = try await DeepSeekAPI.fetchWindowUsage(
                userToken: "token", range: .today,
                now: Date(timeIntervalSince1970: 1_800_000_000)
            )
            check("transport.400/404 路径回退汇总", result.totals.totalTokens == 220_000)
            check("transport.金额与费用都回退", abs(result.cost - 0.0165) < 0.0001)
            check("transport.平台 Authorization 头", MockURLProtocol.lastAuthorization == "Bearer token")
            check("transport.回退请求顺序", MockURLProtocol.requestPaths == [
                "/api/v0/usage/by_api_key/amount", "/api/v0/usage/amount",
                "/api/v0/usage/by_api_key/cost", "/api/v0/usage/cost",
            ])
        } catch {
            check("transport.400/404 路径回退汇总", false, "\(error)")
        }

        MockURLProtocol.reset()
        MockURLProtocol.handler = { _ in
            .init(status: 200, body: "{\"code\":40003,\"msg\":\"invalid token\"}")
        }
        await expectError("transport.40003 映射令牌失效", {
            _ = try await DeepSeekAPI.fetchWindowUsage(userToken: "bad", range: .today)
        }, { $0 == .invalidUserToken })
        check("transport.认证失败不尝试费用路径", MockURLProtocol.requestPaths.count == 1)

        MockURLProtocol.reset()
        MockURLProtocol.handler = { _ in .init(status: 403, body: "<html>blocked</html>") }
        await expectError("transport.403 HTML 映射 WAF", {
            _ = try await DeepSeekAPI.fetchWindowUsage(userToken: "bad", range: .today)
        }, { $0 == .wafBlocked })

        MockURLProtocol.reset()
        MockURLProtocol.handler = { _ in .init(status: 503, body: "unavailable") }
        await expectError("transport.503 保留可重试语义", {
            _ = try await DeepSeekAPI.fetchBalance(apiKey: "sk-test")
        }, { $0.isTransient })

        MockURLProtocol.reset()
        MockURLProtocol.handler = { _ in throw URLError(.timedOut) }
        await expectError("transport.超时映射临时网络错误", {
            _ = try await DeepSeekAPI.fetchBalance(apiKey: "sk-test")
        }, {
            if case .network = $0 { return $0.isTransient }
            return false
        })

        MockURLProtocol.reset()
        MockURLProtocol.delay = 0.2
        MockURLProtocol.handler = { _ in .init(status: 404, body: "missing") }
        let cancelled = Task {
            try await DeepSeekAPI.fetchWindowUsage(userToken: "token", range: .today)
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            check("transport.取消请求抛出错误", false)
        } catch {
            check("transport.取消请求抛出错误", true)
        }
        try? await Task.sleep(nanoseconds: 300_000_000)
        check("transport.取消后不再回退请求", MockURLProtocol.requestPaths.count == 1,
              MockURLProtocol.requestPaths.joined(separator: ","))
    }

    // MARK: - 凭据规范化

    private static func credentials() {
        let plain = CredentialStore.normalizeToken("  \"token-value\" \n")
        check("token 剥掉引号", plain.token == "token-value")
        check("token 原文没有到期时间", plain.expiresAt == nil)

        let seconds = CredentialStore.normalizeToken("{\"value\":\"abc\",\"expireAt\":1800000000}")
        check("token JSON 保留 value", seconds.token == "abc")
        check("token 解析秒级 expireAt", seconds.expiresAt?.timeIntervalSince1970 == 1_800_000_000)

        let milliseconds = CredentialStore.normalizeToken("{\"value\":\"xyz\",\"expireAt\":\"1800000000123\"}")
        check("token 解析毫秒级 expireAt",
              abs((milliseconds.expiresAt?.timeIntervalSince1970 ?? 0) - 1_800_000_000.123) < 0.001)
        check("token 非法 JSON 不崩溃", CredentialStore.normalizeToken("{bad").token == "{bad")
    }

    // MARK: - 峰谷时段

    /// 官方口径：北京时间周一至周五 9:00–12:00、14:00–18:00 为高峰，其余（含周末全天）为空闲。
    /// 参照：2026-10-05 周一、10-09 周五、10-10 周六、10-12 周一。
    private static func peakSchedule() {
        let peaks: [(String, Date)] = [
            ("周一 09:00 高峰", bj(2026, 10, 5, 9, 0)),
            ("周一 11:59 高峰", bj(2026, 10, 5, 11, 59)),
            ("周一 14:00 高峰", bj(2026, 10, 5, 14, 0)),
            ("周一 17:59 高峰", bj(2026, 10, 5, 17, 59)),
        ]
        for (label, date) in peaks {
            check("peak.\(label)", PeakSchedule.isPeak(at: date))
        }

        let offPeaks: [(String, Date)] = [
            ("周一 08:59 空闲", bj(2026, 10, 5, 8, 59)),
            ("周一 12:00 空闲（窗口右开）", bj(2026, 10, 5, 12, 0)),
            ("周一 13:59 空闲", bj(2026, 10, 5, 13, 59)),
            ("周一 18:00 空闲（窗口右开）", bj(2026, 10, 5, 18, 0)),
            ("周六 10:00 空闲", bj(2026, 10, 10, 10, 0)),
            ("周日 15:00 空闲", bj(2026, 10, 11, 15, 0)),
        ]
        for (label, date) in offPeaks {
            check("peak.\(label)", !PeakSchedule.isPeak(at: date))
        }

        typealias Expectation = (label: String, from: Date, to: Date, becomesPeak: Bool)
        let transitions: [Expectation] = [
            ("周一 08:00 → 当日 09:00 进峰", bj(2026, 10, 5, 8, 0), bj(2026, 10, 5, 9, 0), true),
            ("周一 12:30 → 当日 14:00 进峰", bj(2026, 10, 5, 12, 30), bj(2026, 10, 5, 14, 0), true),
            ("周一 10:00 → 当日 12:00 出峰", bj(2026, 10, 5, 10, 0), bj(2026, 10, 5, 12, 0), false),
            ("周一 19:00 → 次日 09:00 进峰", bj(2026, 10, 5, 19, 0), bj(2026, 10, 6, 9, 0), true),
            // 这条最关键：跨周末必须跳到下周一，而不是周六
            ("周五 19:00 → 下周一 09:00 进峰", bj(2026, 10, 9, 19, 0), bj(2026, 10, 12, 9, 0), true),
        ]
        for item in transitions {
            let next = PeakSchedule.nextTransition(from: item.from)
            check("peak.\(item.label) · 时刻", abs(next.date.timeIntervalSince(item.to)) < 1, "\(next.date)")
            check("peak.\(item.label) · 方向", next.becomesPeak == item.becomesPeak, "\(next.becomesPeak)")
        }
    }

    // MARK: - 余额变化气泡（A1/A2/A3 的触发判断）

    private static func balanceDelta() {
        // 首次取到余额只建立基线，绝不能把"全部余额"当成一次变化弹出来
        check("delta.首次不弹", BalanceDelta.change(previous: nil, current: 343.91, currency: "CNY") == nil)

        // 阈值以下不弹，避免 0.001 级别的浮点抖动把气泡刷屏
        check("delta.阈值以下不弹",
              BalanceDelta.change(previous: 100, current: 100.004, currency: "CNY") == nil)
        check("delta.一分钱要弹",
              BalanceDelta.change(previous: 100, current: 99.99, currency: "CNY") != nil)
        // 「半分钱」这个边界无法精确表示：99.995 的 Double 值略大于 99.995，
        // 于是 100-99.995 得到 -0.0049999999999954525，落在阈值之下。
        // 这是浮点表示的现实而非逻辑错误 —— 真实余额永远是整分，不影响到使用。
        check("delta.半分钱落在阈值下不弹",
              BalanceDelta.change(previous: 100, current: 99.995, currency: "CNY") == nil)

        guard let spend = BalanceDelta.change(previous: 342.60, current: 342.41, currency: "CNY") else {
            check("delta.扣费能弹出", false); return
        }
        check("delta.扣费为负", spend.isSpend)
        check("delta.扣费金额", abs(spend.amount + 0.19) < 1e-9, "\(spend.amount)")
        check("delta.扣费文案", spend.text == "−¥0.19", spend.text)

        guard let topUp = BalanceDelta.change(previous: 100, current: 200, currency: "CNY") else {
            check("delta.充值能弹出", false); return
        }
        check("delta.充值为正", !topUp.isSpend)
        check("delta.充值文案", topUp.text == "+¥100.00", topUp.text)

        guard let usd = BalanceDelta.change(previous: 10, current: 9.5, currency: "USD") else {
            check("delta.美元能弹出", false); return
        }
        check("delta.美元符号", usd.text == "−$0.50", usd.text)

        // 文案里用的是真正的减号 U+2212，不是连字符，居中效果更好
        check("delta.使用 U+2212 减号", spend.text.unicodeScalars.first?.value == 0x2212)
    }

    /// 菜单栏「模拟一次余额扣费/充值」走的就是这条路。
    /// 它是唯一能在不花钱、不等真实扣费的前提下验收 A1/A2/A3 的入口，
    /// 所以必须保证它真的会产出气泡。
    @MainActor
    private static func simulatePath() {
        let model = AppModel(startAutomatically: false, withSampleData: true)
        let before = model.recentDeltas.count

        check("simulate.有基线时可注入", model.simulateBalanceChange(-0.07) == true)
        check("simulate.队列增加一枚", model.recentDeltas.count == before + 1,
              "\(before) → \(model.recentDeltas.count)")
        check("simulate.金额正确", model.recentDeltas.last?.amount == -0.07,
              "\(model.recentDeltas.last?.amount ?? 0)")
        check("simulate.文案正确", model.recentDeltas.last?.text == "−¥0.07",
              model.recentDeltas.last?.text ?? "")
        check("simulate.余额同步更新", model.balance?.primary?.total == 343.84,
              "\(model.balance?.primary?.total ?? -1)")

        model.simulateBalanceChange(100)
        check("simulate.充值方向为绿", model.recentDeltas.last?.isSpend == false)
        check("simulate.充值文案", model.recentDeltas.last?.text == "+¥100.00",
              model.recentDeltas.last?.text ?? "")

        // 没有余额基线时要明确返回 false，菜单项据此改为触发真实刷新
        let blank = AppModel(startAutomatically: false, withSampleData: false)
        check("simulate.无余额时拒绝注入", blank.simulateBalanceChange(-0.07) == false)
    }

    /// 构造北京时间
    private static func bj(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = PeakSchedule.beijing
        return calendar.date(from: DateComponents(year: year, month: month, day: day,
                                                  hour: hour, minute: minute)) ?? Date()
    }

    // MARK: - 工具

    private static func snapshotFor(amount: String, cost: String?) -> UsageSnapshot? {
        do {
            return try JSON.makeUsageSnapshot(
                amountData: Data(amount.utf8),
                costData: cost.map { Data($0.utf8) },
                scopeNote: "test"
            )
        } catch {
            check("makeUsageSnapshot 抛错", false, "\(error)")
            return nil
        }
    }

    // MARK: - DSH 本地日志源

    /// 合成夹具。绝不能用真实会话日志做断言——那会把别人的对话内容写进测试。
    private static func localLogUsage() {
        let jsonl = #"""
        {"type":"assistant/message","time":1791087639410,"data":{"usage":{"inputTokens":508,"cacheReadTokens":7168,"cacheWriteTokens":0,"outputTokens":701,"totalTokens":8377},"message":{"source":{"model":"deepseek-flash"}}}}
        {"type":"assistant/message","time":1791091239410,"data":{"usage":{"inputTokens":1000,"cacheReadTokens":0,"outputTokens":500,"totalTokens":1500},"message":{"source":{"model":"deepseek-flash"}}}}
        {"type":"compaction/summary","time":1791094839410,"data":{"usage":{"inputTokens":490900,"cacheReadTokens":0,"outputTokens":4182,"totalTokens":495082}}}
        {"type":"assistant/message","time":1791098439410,"data":{"message":{"content":[]}}}
        not-json-at-all

        """#

        let records = DSHLogSource.parse(jsonl: Data(jsonl.utf8))
        check("日志行解析：只取带 usage 的记录", records.count == 3, "实际 \(records.count)")

        if records.count == 3 {
            check("命中取 cacheReadTokens", records[0].hit == 7168)
            check("未命中取 inputTokens", records[0].miss == 508)
            check("输出取 outputTokens", records[0].output == 701)
            check("model 字段原样保留", records[0].model == "deepseek-flash")
            check("缺 model 的按类型兜底为「压缩摘要」", records[2].model == "压缩摘要", records[2].model)
            let expected = Date(timeIntervalSince1970: 1_791_087_639.410)
            check("毫秒时间戳换算正确", abs(records[0].time.timeIntervalSince(expected)) < 1.0)
            // 这条恒等式正是字段语义的判定依据，钉死在测试里
            check("totalTokens 恒等式成立",
                  records[0].hit + records[0].miss + records[0].output == 8377)
        }

        // 空桶补齐：稀疏数据也不能让步长失真，否则热力图会误判小时/天档位
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let hourly = DSHLogSource.bucketKeys(from: start,
                                             to: start.addingTimeInterval(3 * 3600),
                                             hourly: true)
        check("小时桶数量正确", hourly.count == 4, "实际 \(hourly.count)")
        check("小时桶步长恰为 3600 秒",
              hourly.count == 4 && abs(hourly[1] - hourly[0] - 3600) < 0.5)

        let daily = DSHLogSource.bucketKeys(from: start,
                                            to: start.addingTimeInterval(3 * 86400),
                                            hourly: false)
        check("天桶数量正确", daily.count == 4, "实际 \(daily.count)")
        check("天桶步长恰为 86400 秒",
              daily.count == 4 && abs(daily[1] - daily[0] - 86400) < 0.5)

        check("只有平台来源提供金额", UsageSource.platform.providesCost
                                      && !UsageSource.localLog.providesCost
                                      && !UsageSource.none.providesCost)
    }

    // MARK: - 闲置淡出

    private static func idleFade() {
        func action(phase: IdleFadePolicy.Phase = .awake,
                    hovering: Bool = false,
                    idle: TimeInterval = 20,
                    delay: TimeInterval = 10,
                    enabled: Bool = true,
                    settings: Bool = false,
                    lowBalance: Bool = false,
                    expanded: Bool = false) -> IdleFadePolicy.Action {
            IdleFadePolicy.action(phase: phase, hovering: hovering, idleFor: idle, delay: delay,
                                  enabled: enabled, settingsOpen: settings,
                                  lowBalance: lowBalance, expanded: expanded)
        }

        check("闲置超时 → 淡出", action() == .fade)
        check("未到延迟 → 不动", action(idle: 5) == .stay)
        check("刚好到延迟 → 淡出", action(idle: 10) == .fade)
        check("指针在面板上 → 不淡出", action(hovering: true) == .stay)
        check("关掉开关 → 不淡出", action(enabled: false) == .stay)
        check("设置页开着 → 不淡出", action(settings: true) == .stay)
        check("低余额告警期间 → 不淡出", action(lowBalance: true) == .stay)
        // 展开态是"我要看细节"的信号，这时候淡掉等于把人读到一半的字弄糊
        check("展开态 → 不淡出", action(expanded: true) == .stay)
        check("展开态 + 闲置很久 → 仍不淡出", action(idle: 9_999, expanded: true) == .stay)

        // 下面几条是用户报过的 bug：淡出后指针扫过面板不能把窗口唤醒。
        // 否则为了点下面的窗口，指针必须先经过面板，可一经过就恢复，
        // 点击又被面板抢走，穿透等于没做。
        check("已淡出 + 指针扫过面板 → 保持淡出", action(phase: .faded, hovering: true) == .stay)
        check("已淡出 + 闲置继续增长 → 仍是淡出", action(phase: .faded, idle: 9_999) == .stay)
        check("已淡出 + 关掉开关 → 恢复", action(phase: .faded, enabled: false) == .restore)
        check("已淡出 + 打开设置页 → 恢复", action(phase: .faded, settings: true) == .restore)
        check("已淡出 + 低余额告警 → 恢复", action(phase: .faded, lowBalance: true) == .restore)
        check("已淡出 + 切到展开 → 恢复", action(phase: .faded, expanded: true) == .restore)

        check("淡出 + 指针在图标上 → 放行鼠标",
              IdleFadePolicy.acceptsMouseWhileFaded(cursorOverIcon: true))
        check("淡出 + 指针不在图标上 → 穿透",
              !IdleFadePolicy.acceptsMouseWhileFaded(cursorOverIcon: false))
    }

    // MARK: - 余额走势

    private static func balanceTrend() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func sample(_ hoursAgo: Double, _ total: Double) -> BalanceSample {
            BalanceSample(date: now.addingTimeInterval(-hoursAgo * 3600), total: total)
        }

        // prune：默认保留原始历史；传上限时才为展示抽样
        let messy = [sample(1, 10), sample(30, 99), sample(2, 9)]
        let pruned = BalanceTrend.prune(messy, now: now)
        check("prune 丢掉 24 小时以外的采样", pruned.count == 2, "实际 \(pruned.count)")
        check("prune 按时间升序", pruned.map(\.date) == pruned.map(\.date).sorted())
        let all = (0..<600).map { sample(Double($0) * 0.01, 1) }
        let capped = BalanceTrend.prune(all, now: now, limit: 100)
        check("prune 截断到上限", capped.count <= 100 && capped.count >= 2, "实际 \(capped.count)")
        check("prune 抽样保留首点", capped.first?.date == all.last?.date)
        check("prune 抽样保留末点", capped.last?.date == all.first?.date)
        let rawDense = BalanceTrend.prune((0...5760).map { sample(Double($0) * 15 / 3600, 100) },
                                         now: now)
        check("prune 默认保留全部原始采样", rawDense.count == 5761, "实际 \(rawDense.count)")
        let dense = BalanceTrend.prune(rawDense, now: now, limit: 500)
        check("prune 展示抽样仍覆盖 24 小时", dense.count <= 500
              && abs(BalanceTrend.span(dense) - 86400) < 1,
              "点数 \(dense.count)，跨度 \(BalanceTrend.span(dense))")
        let spiky = BalanceTrend.prune((0..<600).map {
            sample(Double($0) * 0.01, $0 == 137 ? 1_000 : ($0 == 433 ? 0 : 100))
        }, now: now, limit: 100)
        check("prune 保留桶内最高峰", spiky.contains { $0.total == 1_000 })
        check("prune 保留桶内最低谷", spiky.contains { $0.total == 0 })
        check("prune 上限为 0 时返回空", BalanceTrend.prune(all, now: now, limit: 0).isEmpty)
        check("prune 上限为 1 时保留最新点",
              BalanceTrend.prune(all, now: now, limit: 1).first?.date == all.first?.date)

        // rate
        let decline = [sample(2, 100), sample(0, 98)]
        check("rate 两小时掉 2 元 → 1 元/小时",
              abs((BalanceTrend.rate(decline) ?? 0) - 1.0) < 0.001)
        check("rate 余额上升（充值）→ nil",
              BalanceTrend.rate([sample(1, 100), sample(0, 120)]) == nil)
        let recharge = [sample(3, 100), sample(2, 95), sample(1, 120), sample(0, 118)]
        check("rate 窗口内充值不抹掉前后消耗",
              abs((BalanceTrend.rate(recharge) ?? 0) - 7.0 / 3.0) < 0.001)
        let rawSpending = (0...600).map { sample(6 - Double($0) * 0.01, $0 == 300 ? 90 : 100) }
        check("rate 使用未抽样的完整扣费段",
              abs((BalanceTrend.rate(rawSpending) ?? 0) - 10.0 / 6.0) < 0.001)
        check("rate 单点 → nil", BalanceTrend.rate([sample(1, 100)]) == nil)

        // span / 可靠性
        check("span 两点之间", abs(BalanceTrend.span(decline) - 7200) < 1)
        check("span 单点 → 0", BalanceTrend.span([sample(1, 100)]) == 0)
        check("跨度 10 分钟 → 不可靠",
              !BalanceTrend.isReliable([sample(1.0 / 6, 100), sample(0, 99.9)]))
        check("跨度 45 分钟 → 可靠",
              BalanceTrend.isReliable([sample(0.75, 100), sample(0, 99)]))

        // points：视图映射
        let size = CGSize(width: 100, height: 40)
        let mapped = BalanceTrend.points([sample(2, 10), sample(1, 20), sample(0, 15)], in: size)
        check("points 数量与采样一致", mapped.count == 3, "实际 \(mapped.count)")
        let densePoints = BalanceTrend.points(rawDense, in: size)
        check("points 只抽样展示不修改原始历史", densePoints.count <= 500 && rawDense.count == 5761,
              "展示 \(densePoints.count)，原始 \(rawDense.count)")
        check("points 横坐标按时间递增",
              mapped[0].x == 0 && abs(mapped[2].x - 100) < 0.01 && abs(mapped[1].x - 50) < 0.01)
        let uneven = BalanceTrend.points([sample(4, 10), sample(3, 20), sample(0, 15)], in: size)
        check("points 非均匀采样保留真实时间距离", abs(uneven[1].x - 25) < 0.01,
              "实际 \(uneven[1].x)")
        // y 向下：最大值应当最靠上
        check("points 最大值最靠上", mapped[1].y < mapped[0].y && mapped[1].y < mapped[2].y)
        check("points 全在画布内", mapped.allSatisfy { $0.y >= 0 && $0.y <= size.height })
        let flat = BalanceTrend.points([sample(2, 5), sample(1, 5), sample(0, 5)], in: size)
        check("points 等值序列贴中线",
              flat.allSatisfy { abs($0.y - size.height / 2) < 0.01 })
        check("points 单点落在中线",
              BalanceTrend.points([sample(0, 5)], in: size).first.map {
                  abs($0.y - size.height / 2) < 0.01
              } ?? false)
        check("points 空数组 → 空",
              BalanceTrend.points([], in: size).isEmpty)

        // 噪声下限：几分钱的抖动不能被放大成满幅悬崖
        let tiny = BalanceTrend.points([sample(2, 38.67), sample(1, 38.64), sample(0, 38.66)],
                                       in: size)
        let spread = (tiny.map(\.y).max() ?? 0) - (tiny.map(\.y).min() ?? 0)
        check("points 微小波动被压平（< 画布 25%）", spread < size.height * 0.25,
              "实际占 \(Int(spread / size.height * 100))%")

        // 落盘往返
        let data = BalanceHistoryStore.encode(decline) ?? Data()
        check("采样编码/解码往返一致", BalanceHistoryStore.decode(data) == decline)
    }

    private static func check(_ label: String, _ passed: Bool, _ detail: String = "") {
        checks += 1
        if passed {
            print("  ✓ \(label)")
        } else {
            failures += 1
            print("  ✗ \(label)" + (detail.isEmpty ? "" : "  → \(detail)"))
        }
    }
}
