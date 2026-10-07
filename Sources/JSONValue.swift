import Foundation

/// 针对 DeepSeek 平台那些「没有写进文档、形状还不统一」的 JSON 做容错遍历。
///
/// 实测两个开源实现里同一族接口的响应形状并不一致：
///   - `usage/by_api_key/{amount,cost}` → `data.biz_data.series[].buckets[].usage/cost`
///   - `usage/{amount,cost}`            → `data.biz_data.total[].usage[]` 与 `days[].data[].usage[]`
///   - `usage/by_api_key/cost`          → `data.biz_data.data[].series[].buckets[].cost`
/// 所以这里不做严格 Codable 建模，而是按语义递归抓取：凡是 `usage` 里的 `type→amount`、
/// 凡是叫 `cost` 的数值、凡是带 `time`/`date` 的节点。
///
/// **一个关键约束**：月度接口里 `total` 是总账、`days` 是同一批数据按天的明细，
/// 两者相加会翻倍。因此当某个节点同时有 `total` 与 `days`/`series`/`data` 时，
/// 后者只用来画趋势，不计入总计。
enum JSON {

    // MARK: - 基础取值

    static func root(_ data: Data) throws -> Any {
        do {
            return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw DSFloatError.decoding(error.localizedDescription)
        }
    }

    static func dict(_ v: Any?) -> [String: Any]? { v as? [String: Any] }
    static func array(_ v: Any?) -> [Any]? { v as? [Any] }

    static func string(_ v: Any?) -> String? {
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        return nil
    }

    static func double(_ v: Any?) -> Double {
        switch v {
        case let d as Double: return d
        case let i as Int: return Double(i)
        case let n as NSNumber: return n.doubleValue
        case let s as String: return Double(s.trimmingCharacters(in: .whitespaces)) ?? 0
        default: return 0
        }
    }

    static func int(_ v: Any?) -> Int64 {
        switch v {
        case let i as Int: return Int64(i)
        case let d as Double: return Int64(d)
        case let n as NSNumber: return n.int64Value
        case let s as String: return Int64(Double(s.trimmingCharacters(in: .whitespaces)) ?? 0)
        default: return 0
        }
    }

    /// 沿路径取值，任意一层缺失都返回 nil
    static func dig(_ root: Any?, _ keys: String...) -> Any? {
        var current: Any? = root
        for key in keys {
            guard let dict = current as? [String: Any] else { return nil }
            current = dict[key]
        }
        return current
    }

    // MARK: - 业务错误识别

    /// 官方信封：`{ "error": { "message": …, "type": …, "code": … } }`
    /// 平台业务错误：`{ "code": 40003, "msg": … }`
    static func errorMessage(_ root: Any?) -> String? {
        if let error = dict(dig(root, "error")) {
            let parts = [string(error["message"]), string(error["type"]), string(error["code"])]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
            return parts.isEmpty ? nil : parts.joined(separator: " / ")
        }
        if let object = dict(root), let code = object["code"], int(code) != 0 {
            return string(object["msg"]) ?? string(object["message"]) ?? "业务错误码 \(int(code))"
        }
        return nil
    }

    static func businessCode(_ root: Any?) -> Int64 {
        guard let object = dict(root) else { return 0 }
        if let code = object["code"] { return int(code) }
        if let error = dict(object["error"]), let code = error["code"] { return int(code) }
        return 0
    }

    // MARK: - 余额

    static func parseBalance(_ data: Data) throws -> BalanceSnapshot {
        let root = try self.root(data)
        if let message = errorMessage(root) {
            throw DSFloatError.decoding(message)
        }
        let isAvailable = (dig(root, "is_available") as? Bool) ?? (int(dig(root, "is_available")) != 0)
        let rawInfos = array(dig(root, "balance_infos")) ?? []
        let infos: [BalanceInfo] = rawInfos.compactMap { item in
            guard let dict = dict(item) else { return nil }
            return BalanceInfo(
                currency: (string(dict["currency"]) ?? "CNY").uppercased(),
                total: double(dict["total_balance"]),
                granted: double(dict["granted_balance"]),
                toppedUp: double(dict["topped_up_balance"])
            )
        }
        guard !infos.isEmpty else {
            throw DSFloatError.decoding("balance_infos 为空")
        }
        return BalanceSnapshot(isAvailable: isAvailable, infos: infos, fetchedAt: Date())
    }

    // MARK: - Token 类型归一

    /// 把两个接口族里五花八门的类型名归一到三段口径：
    /// `PROMPT_CACHE_HIT_TOKEN` / `input_cache_hit_tokens` → cacheHit
    /// `PROMPT_CACHE_MISS_TOKEN` / `input_cache_miss_tokens` → cacheMiss
    /// `RESPONSE_TOKEN` / `output_tokens` / `COMPLETION_TOKEN`   → output
    /// `REQUEST` / `request_count`                               → requests
    enum TokenKind { case cacheHit, cacheMiss, output, requests, unknown }

    static func classify(_ raw: String) -> TokenKind {
        let type = raw.lowercased()
        if type.contains("cache_hit") || type.contains("cachehit") { return .cacheHit }
        if type.contains("cache_miss") || type.contains("cachemiss") { return .cacheMiss }
        if type.contains("request") || type.hasSuffix("_count") { return .requests }
        if type.contains("output") || type.contains("response") || type.contains("completion") { return .output }
        return .unknown
    }

    private static func apply(_ kind: TokenKind, _ amount: Double, _ breakdown: inout TokenBreakdown) {
        switch kind {
        case .cacheHit: breakdown.cacheHit += Int64(amount)
        case .cacheMiss: breakdown.cacheMiss += Int64(amount)
        case .output: breakdown.output += Int64(amount)
        case .requests: breakdown.requests += Int(amount)
        case .unknown: break
        }
    }

    /// 只有 `total` 在场时，这些键才是「同一批数据的另一种切法」，不能再计入总计
    private static func isBreakdownOnlyKey(_ key: String) -> Bool {
        key == "days" || key == "series" || key == "data"
    }

    private static func parseDayKey(_ raw: String) -> Double? {
        let compact = raw.replacingOccurrences(of: "-", with: "")
        guard compact.count >= 8 else { return nil }
        var components = DateComponents()
        components.year = Int(compact.prefix(4))
        components.month = Int(compact.dropFirst(4).prefix(2))
        components.day = Int(compact.dropFirst(6).prefix(2))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar.date(from: components)?.timeIntervalSince1970
    }

    // MARK: - 用量：token

    struct TokenContext {
        var model: String?
        var bucket: Double?
        /// false 表示这棵子树只贡献趋势桶，不贡献总计
        var toTotals: Bool = true
    }

    struct TokenWalkResult {
        var totals = TokenBreakdown()
        var models: [String: TokenBreakdown] = [:]
        var buckets: [Double: TokenBreakdown] = [:]
        var rawModelNames: [String] = []
    }

    static func walkTokens(_ node: Any, _ context: TokenContext = TokenContext(), into result: inout TokenWalkResult) {
        if let array = node as? [Any] {
            for item in array { walkTokens(item, context, into: &result) }
            return
        }
        guard let dict = node as? [String: Any] else { return }

        var context = context
        if let model = string(dict["model"]), !model.isEmpty { context.model = model }
        if let names = array(dict["models"]) {
            for name in names {
                if let value = string(name), !value.isEmpty, !result.rawModelNames.contains(value) {
                    result.rawModelNames.append(value)
                }
            }
        }
        if let time = dict["time"], !(time is String) {
            context.bucket = double(time)
        } else if let date = string(dict["date"]), !date.isEmpty, let parsed = parseDayKey(date) {
            context.bucket = parsed
        }

        if let usage = dict["usage"] {
            var local = TokenBreakdown()
            collectAmounts(usage, into: &local)
            if !local.isEmpty {
                if context.toTotals {
                    result.totals += local
                    if let model = context.model {
                        result.models[model, default: TokenBreakdown()] += local
                    }
                }
                if let bucket = context.bucket {
                    result.buckets[bucket, default: TokenBreakdown()] += local
                }
            }
        }

        let hasTotal = dict["total"] != nil
        for (key, value) in dict where key != "usage" && key != "models" {
            guard value is [String: Any] || value is [Any] else { continue }
            var childContext = context
            if hasTotal && isBreakdownOnlyKey(key) { childContext.toTotals = false }
            walkTokens(value, childContext, into: &result)
        }
    }

    /// `usage` 可能是 `{TYPE: n}`，也可能是 `[{type, amount}]`
    private static func collectAmounts(_ usage: Any, into breakdown: inout TokenBreakdown) {
        if let dict = usage as? [String: Any] {
            for (key, value) in dict {
                let kind = classify(key)
                guard kind != .unknown else { continue }
                apply(kind, double(value), &breakdown)
            }
        } else if let array = usage as? [Any] {
            for item in array {
                guard let dict = item as? [String: Any] else { continue }
                let kind = classify(string(dict["type"]) ?? string(dict["name"]) ?? "")
                guard kind != .unknown else { continue }
                apply(kind, double(dict["amount"]), &breakdown)
            }
        }
    }

    // MARK: - 用量：费用

    struct CostContext {
        var model: String?
        var bucket: Double?
        var toTotals: Bool = true
    }

    struct CostWalkResult {
        var total: Double = 0
        var currency: String = ""
        var buckets: [Double: Double] = [:]
        var perModel: [String: Double] = [:]
    }

    static func walkCosts(_ node: Any, _ context: CostContext = CostContext(), into result: inout CostWalkResult) {
        if let array = node as? [Any] {
            for item in array { walkCosts(item, context, into: &result) }
            return
        }
        guard let dict = node as? [String: Any] else { return }

        var context = context
        if let model = string(dict["model"]), !model.isEmpty { context.model = model }
        if result.currency.isEmpty, let currency = string(dict["currency"]), !currency.isEmpty {
            result.currency = currency.uppercased()
        }
        if let time = dict["time"], !(time is String) {
            context.bucket = double(time)
        } else if let date = string(dict["date"]), !date.isEmpty, let parsed = parseDayKey(date) {
            context.bucket = parsed
        }

        var sum = 0.0
        if dict["cost"] != nil { sum += double(dict["cost"]) }
        if let usage = dict["usage"] { sum += costOfUsage(usage) }

        if sum != 0 {
            if context.toTotals {
                result.total += sum
                if let model = context.model { result.perModel[model, default: 0] += sum }
            }
            if let bucket = context.bucket { result.buckets[bucket, default: 0] += sum }
        }

        let hasTotal = dict["total"] != nil
        for (key, value) in dict where key != "usage" {
            guard value is [String: Any] || value is [Any] else { continue }
            var childContext = context
            if hasTotal && isBreakdownOnlyKey(key) { childContext.toTotals = false }
            walkCosts(value, childContext, into: &result)
        }
    }

    /// 费用接口里 `usage` 的 `amount` 本身就是钱；`REQUEST` 那条是次数，必须排除
    private static func costOfUsage(_ usage: Any) -> Double {
        var sum = 0.0
        if let dict = usage as? [String: Any] {
            for (key, value) in dict {
                let kind = classify(key)
                guard kind != .requests, kind != .unknown else { continue }
                sum += double(value)
            }
        } else if let array = usage as? [Any] {
            for item in array {
                guard let dict = item as? [String: Any] else { continue }
                let kind = classify(string(dict["type"]) ?? string(dict["name"]) ?? "")
                guard kind != .requests, kind != .unknown else { continue }
                sum += double(dict["amount"])
            }
        }
        return sum
    }

    // MARK: - 组装

    static func makeUsageSnapshot(amountData: Data?, costData: Data?, scopeNote: String) throws -> UsageSnapshot {
        guard let amountData else { throw DSFloatError.decoding("缺少 amount 响应") }
        let amountRoot = try root(amountData)
        if businessCode(amountRoot) != 0, let message = errorMessage(amountRoot) {
            throw DSFloatError.decoding(message)
        }

        var tokenResult = TokenWalkResult()
        walkTokens(amountRoot, into: &tokenResult)

        var snapshot = UsageSnapshot()
        snapshot.totals = tokenResult.totals
        snapshot.scopeNote = scopeNote
        snapshot.fetchedAt = Date()

        var costResult = CostWalkResult()
        if let costData, let costRoot = try? root(costData) {
            walkCosts(costRoot, into: &costResult)
            snapshot.cost = costResult.total
            if !costResult.currency.isEmpty { snapshot.currency = costResult.currency }
        }

        let bucketKeys = Set(tokenResult.buckets.keys).union(costResult.buckets.keys)
        snapshot.buckets = bucketKeys.sorted().map { key in
            UsageBucket(
                time: key,
                breakdown: tokenResult.buckets[key] ?? TokenBreakdown(),
                cost: costResult.buckets[key] ?? 0,
                label: bucketLabel(key)
            )
        }

        let modelKeys = Set(tokenResult.models.keys).union(costResult.perModel.keys)
        snapshot.models = modelKeys
            .map { name in
                ModelUsage(
                    model: name,
                    breakdown: tokenResult.models[name] ?? TokenBreakdown(),
                    cost: costResult.perModel[name] ?? 0
                )
            }
            .filter { !$0.breakdown.isEmpty || $0.cost > 0 }
            .sorted { $0.breakdown.totalTokens > $1.breakdown.totalTokens }

        return snapshot
    }

    private static func bucketLabel(_ key: Double) -> String {
        Fmt.day.string(from: Date(timeIntervalSince1970: key))
    }
}
