import Foundation

// MARK: - 余额

struct BalanceInfo: Identifiable, Hashable {
    var id: String { currency }
    let currency: String
    let total: Double
    let granted: Double
    let toppedUp: Double
}

struct BalanceSnapshot: Equatable {
    let isAvailable: Bool
    let infos: [BalanceInfo]
    let fetchedAt: Date

    /// 主币种（优先人民币，其次第一个）
    var primary: BalanceInfo? {
        infos.first(where: { $0.currency.uppercased() == "CNY" }) ?? infos.first
    }
}

// MARK: - Token 口径

/// 与 DeepSeek 平台一致的三段口径：缓存命中 / 缓存未命中 / 输出
struct TokenBreakdown: Equatable {
    var cacheHit: Int64 = 0
    var cacheMiss: Int64 = 0
    var output: Int64 = 0
    var requests: Int = 0

    var promptTokens: Int64 { cacheHit + cacheMiss }
    var totalTokens: Int64 { cacheHit + cacheMiss + output }

    /// 缓存命中率 = 命中 / (命中 + 未命中)。这是 DeepSeek 计费上真正省钱的那个比例。
    var cacheHitRate: Double {
        let denom = cacheHit + cacheMiss
        return denom > 0 ? Double(cacheHit) / Double(denom) : 0
    }

    var isEmpty: Bool { totalTokens == 0 && requests == 0 }

    static func + (lhs: TokenBreakdown, rhs: TokenBreakdown) -> TokenBreakdown {
        TokenBreakdown(
            cacheHit: lhs.cacheHit + rhs.cacheHit,
            cacheMiss: lhs.cacheMiss + rhs.cacheMiss,
            output: lhs.output + rhs.output,
            requests: lhs.requests + rhs.requests
        )
    }

    static func += (lhs: inout TokenBreakdown, rhs: TokenBreakdown) { lhs = lhs + rhs }
}

struct ModelUsage: Identifiable, Equatable {
    var id: String { model }
    let model: String
    var breakdown: TokenBreakdown = TokenBreakdown()
    var cost: Double = 0
}

struct UsageBucket: Identifiable, Equatable {
    var id: Double { time }
    /// Unix 秒（已按请求时区平移）
    let time: Double
    var breakdown: TokenBreakdown = TokenBreakdown()
    var cost: Double = 0
    var label: String = ""
}

struct UsageSnapshot: Equatable {
    var currency: String = "CNY"
    var totals = TokenBreakdown()
    var cost: Double = 0
    /// 该来源是否提供真实金额。本地日志只有 token 数、没有钱，
    /// 此时 cost 恒为 0 但**不能当成「0 元」展示**，所以单独用这个标志区分。
    var hasCost: Bool = true
    var buckets: [UsageBucket] = []
    var models: [ModelUsage] = []
    var fetchedAt: Date = Date()
    /// 该快照覆盖的时间范围描述（用于 UI 标注）
    var scopeNote: String = ""

    var isEmpty: Bool { totals.isEmpty && models.isEmpty && buckets.isEmpty }
}

// MARK: - 用量来源

/// 用量的取数来源。做成显式选择，是因为两条通路的**统计口径不同**：
/// 平台接口是账户全量、官方账单口径；本地日志只有本机 DSH 发出的请求。
/// 混在一起显示会让人误以为是一套数字。
enum UsageSource: String, CaseIterable, Identifiable {
    /// 平台令牌：platform.deepseek.com 用量接口，账户全量，含真实金额
    case platform
    /// DSH 本地日志：只覆盖本机 DSH 的请求，逐请求、无需令牌，但没有金额
    case localLog
    /// 不显示用量，只看余额
    case none

    var id: String { rawValue }

    var title: String {
        switch self {
        case .platform: return "平台令牌"
        case .localLog: return "DSH 本地日志"
        case .none: return "不显示"
        }
    }

    var caption: String {
        switch self {
        case .platform: return "账户全量 · 官方口径 · 含真实金额"
        case .localLog: return "仅本机 DSH 请求 · 无需令牌 · 无金额"
        case .none: return "只看余额"
        }
    }

    /// 该来源是否提供真实金额
    var providesCost: Bool { self == .platform }
}

// MARK: - 时间范围

enum UsageRange: String, CaseIterable, Identifiable {
    case today
    case last24h
    case last7d
    case last30d
    case thisMonth
    case last90d

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: return "今日"
        case .last24h: return "24小时"
        case .last7d: return "7天"
        case .last30d: return "30天"
        case .thisMonth: return "本月"
        case .last90d: return "90天"
        }
    }

    /// 返回 (start, end) 的 Unix 秒。tzOffset 为本地相对 UTC 的秒数偏移。
    func window(now: Date = Date(), calendar: Calendar = .current) -> (start: Int, end: Int) {
        let end = Int(now.timeIntervalSince1970)
        switch self {
        case .today:
            let startOfDay = calendar.startOfDay(for: now)
            return (Int(startOfDay.timeIntervalSince1970), end)
        case .last24h:
            return (end - 24 * 3600, end)
        case .last7d:
            return (end - 7 * 86400, end)
        case .last30d:
            return (end - 30 * 86400, end)
        case .thisMonth:
            let comps = calendar.dateComponents([.year, .month], from: now)
            let first = calendar.date(from: DateComponents(year: comps.year, month: comps.month, day: 1)) ?? now
            return (Int(first.timeIntervalSince1970), end)
        case .last90d:
            return (end - 90 * 86400, end)
        }
    }

    /// 该范围适合的聚合粒度（仅用于文案提示，服务端会自行决定）
    var granularityNote: String {
        switch self {
        case .today, .last24h: return "按小时"
        case .last7d: return "按天"
        default: return "按天"
        }
    }

    var isMonthlyAPIWorthwhile: Bool {
        switch self {
        case .thisMonth, .last30d, .last7d: return true
        default: return false
        }
    }
}

// MARK: - 图表模式

enum ChartMode: String, CaseIterable, Identifiable {
    case bars
    case heat

    var id: String { rawValue }
}

// MARK: - 错误

enum DSFloatError: LocalizedError, Equatable {
    case missingAPIKey
    case invalidAPIKey
    case insufficientBalance
    case missingUserToken
    case invalidUserToken
    case wafBlocked
    case rateLimited
    case http(Int, String)
    case network(String)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "还没有填写 API Key"
        case .invalidAPIKey:
            return "API Key 无效或已被撤销（401）"
        case .insufficientBalance:
            return "账户余额不足（402）"
        case .missingUserToken:
            return "未填写平台访问令牌，无法读取 token 用量"
        case .invalidUserToken:
            return "平台访问令牌已失效，请在 platform.deepseek.com 重新获取（40003）"
        case .wafBlocked:
            return "被 platform.deepseek.com 的 WAF 拦截，请稍后重试"
        case .rateLimited:
            return "请求过于频繁，已自动降速"
        case let .http(code, msg):
            return "HTTP \(code)" + (msg.isEmpty ? "" : "：\(msg)")
        case let .network(msg):
            return "网络错误：\(msg)"
        case let .decoding(msg):
            return "响应解析失败：\(msg)"
        }
    }

    /// 是否属于「再等一会儿可能就好了」的临时错误
    var isTransient: Bool {
        switch self {
        case .wafBlocked, .rateLimited, .network: return true
        default: return false
        }
    }
}

// MARK: - 格式化

enum Fmt {
    static func money(_ value: Double, currency: String = "CNY") -> String {
        value.formatted(.currency(code: currency).precision(.fractionLength(2)))
    }

    /// ¥ 前缀的紧凑金额
    static func moneyCompact(_ value: Double, currency: String = "CNY") -> String {
        let symbol = currency.uppercased() == "USD" ? "$" : "¥"
        return symbol + String(format: "%.2f", value)
    }

    static func tokens(_ value: Int64) -> String {
        let v = Double(value)
        if value >= 100_000_000 { return String(format: "%.2f亿", v / 100_000_000) }
        if value >= 10_000 { return String(format: "%.2f万", v / 10_000) }
        return number(value)
    }

    /// 千分位数字
    static func number(_ value: Int64) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = ","
        return f.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    static func percent(_ ratio: Double) -> String {
        String(format: "%.1f%%", ratio * 100)
    }

    static func relative(_ date: Date, now: Date = Date()) -> String {
        let dt = now.timeIntervalSince(date)
        if dt < 5 { return "刚刚" }
        if dt < 60 { return "\(Int(dt)) 秒前" }
        if dt < 3600 { return "\(Int(dt / 60)) 分钟前" }
        if dt < 86400 { return "\(Int(dt / 3600)) 小时前" }
        return "\(Int(dt / 86400)) 天前"
    }

    static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    static let day: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd"
        return f
    }()
}
