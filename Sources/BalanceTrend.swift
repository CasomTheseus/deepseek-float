import Foundation
import CoreGraphics

/// 一次余额采样。
struct BalanceSample: Codable, Equatable {
    let date: Date
    let total: Double
}

/// 余额走势的计算部分。
///
/// 抽成纯函数是因为这些数字之前是**不可信的**：采样只存在内存里，重启即清零，
/// 于是刚启动三分钟就会用一个极小的样本算出「消耗速率」，界面上却看不出样本有多小。
/// 现在持久化 + 把采样时长摆到界面上，判定逻辑也就必须有断言。
enum BalanceTrend {
    /// 采样窗口
    static let window: TimeInterval = 24 * 3600
    static let limit = 500
    /// 采样少于这个时长时，速率只当参考，不当结论
    static let reliableSpan: TimeInterval = 30 * 60

    /// 丢弃过期采样、按时间排序、截断到上限。
    static func prune(_ samples: [BalanceSample],
                      now: Date,
                      window: TimeInterval = window,
                      limit: Int = limit) -> [BalanceSample] {
        let cutoff = now.addingTimeInterval(-window)
        var kept = samples
            .filter { $0.date >= cutoff && $0.date <= now.addingTimeInterval(60) }
            .sorted { $0.date < $1.date }
        if kept.count > limit { kept.removeFirst(kept.count - limit) }
        return kept
    }

    /// 采样跨度（秒）。少于两个点时为 0。
    static func span(_ samples: [BalanceSample]) -> TimeInterval {
        guard let first = samples.first, let last = samples.last, samples.count >= 2 else { return 0 }
        return max(0, last.date.timeIntervalSince(first.date))
    }

    /// 每小时消耗（元/小时）。只算余额下降的部分；充值会让 delta 为负，此时返回 nil。
    static func rate(_ samples: [BalanceSample]) -> Double? {
        guard samples.count >= 2,
              let first = samples.first, let last = samples.last else { return nil }
        let hours = last.date.timeIntervalSince(first.date) / 3600
        guard hours > 0.05 else { return nil }
        let delta = first.total - last.total
        guard delta > 0 else { return nil }
        return delta / hours
    }

    /// 采样是否够长，够的话速率的量级才值得当真
    static func isReliable(_ samples: [BalanceSample]) -> Bool {
        span(samples) >= reliableSpan
    }

    /// 把采样映射成视图里的折线点（原点左上，y 向下）。始终按实际 min/max 自适应。
    ///
    /// 边界情况都在这里处理掉了：只有一个点、所有值相同、空数组。
    static func points(_ samples: [BalanceSample], in size: CGSize) -> [CGPoint] {
        guard !samples.isEmpty, size.width > 0, size.height > 0 else { return [] }
        guard samples.count > 1 else {
            return [CGPoint(x: 0, y: size.height / 2)]
        }

        let values = samples.map(\.total)
        let minValue = values.min() ?? 0
        let maxValue = values.max() ?? 0
        let range = maxValue - minValue
        let usable = size.height * 0.8
        let inset = (size.height - usable) / 2

        // 噪声下限：差价太小时不要放成满幅。否则 2 分钟里 ¥0.03 的抖动
        // 会被画成一条悬崖，看上去像余额在暴跌。低于均值的 0.4% 就按比例压向中线。
        let noiseFloor = max(maxValue, 1) * 0.004
        let compress = noiseFloor > 0 ? min(1, range / noiseFloor) : 1

        return samples.enumerated().map { index, sample in
            let x = CGFloat(index) / CGFloat(samples.count - 1) * size.width
            let ratio = range > 0.0001 ? (sample.total - minValue) / range : 0.5
            let centered = 0.5 + (ratio - 0.5) * compress
            let y = size.height - inset - CGFloat(centered) * usable
            return CGPoint(x: x, y: y)
        }
    }
}

/// 采样落盘。路径与凭据同目录，权限 0600。
enum BalanceHistoryStore {
    static var url: URL {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/DeepSeekFloat", isDirectory: true)
        return base.appendingPathComponent("balance-history.json")
    }

    static func encode(_ samples: [BalanceSample]) -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return try? encoder.encode(samples)
    }

    static func decode(_ data: Data) -> [BalanceSample] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return (try? decoder.decode([BalanceSample].self, from: data)) ?? []
    }

    static func load() -> [BalanceSample] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return decode(data)
    }

    static func save(_ samples: [BalanceSample]) {
        guard let data = encode(samples) else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(),
                                withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        // 不存凭据，但保持一致的收紧权限，免得别人以为这个文件可以随便读
        try? data.write(to: url, options: [.atomic])
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
