import SwiftUI

/// 时间范围 + 趋势图。两种模式：
/// - **柱状**：命中/未命中/输出堆叠柱
/// - **热力**（视觉细节 C1）：按数据粒度自适应
///   · 拿到小时级桶（今日 / 24 小时）→ 24 格单行小时热力条
///   · 拿到天级桶 → 星期 × 周 贡献热力图（仿 GitHub / codexU）
struct TrendCard: View {
    @EnvironmentObject var model: AppModel

    private var buckets: [UsageBucket] { model.usage?.buckets ?? [] }

    private var maxTotal: Double {
        max(1, buckets.map { Double($0.breakdown.totalTokens) }.max() ?? 1)
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 9) {
                header
                RangeSelector(selection: $model.range)
                if model.chartMode == .bars {
                    barChart
                } else {
                    HeatmapView(buckets: buckets, hasToken: model.hasUserToken)
                }
            }
        }
    }

    // MARK: - 头部（含模式切换）

    private var header: some View {
        HStack(spacing: 6) {
            Text("用量趋势")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(DS.textSecondary)
                .tracking(0.3)
            Spacer(minLength: 4)
            Text(model.range.granularityNote + " · " + model.range.title)
                .font(.system(size: 10))
                .foregroundStyle(DS.textTertiary)
            modeToggle
        }
    }

    private var modeToggle: some View {
        HStack(spacing: 1) {
            modeButton(.bars, icon: "chart.bar.fill", help: "堆叠柱状图")
            modeButton(.heat, icon: "square.grid.3x3.fill", help: "热力图")
        }
        .padding(1.5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(0.06))
        )
    }

    private func modeButton(_ mode: ChartMode, icon: String, help: String) -> some View {
        let active = model.chartMode == mode
        return Button {
            guard !active else { return }
            withAnimation(.easeInOut(duration: 0.18)) { model.chartMode = mode }
        } label: {
            Image(systemName: icon)
                .font(.system(size: 8.5, weight: .semibold))
                .foregroundStyle(active ? Color.white : DS.textTertiary)
                .frame(width: 18, height: 14)
                .background(
                    RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                        .fill(active ? DS.accent.opacity(0.9) : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: - 柱状

    @ViewBuilder
    private var barChart: some View {
        if buckets.isEmpty {
            emptyPlaceholder(height: 52)
        } else {
            GeometryReader { geo in
                let spacing: CGFloat = buckets.count > 40 ? 1 : (buckets.count > 15 ? 2 : 4)
                HStack(alignment: .bottom, spacing: spacing) {
                    ForEach(buckets) { bucket in
                        column(bucket, height: geo.size.height)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 54)
        }
    }

    private func column(_ bucket: UsageBucket, height: CGFloat) -> some View {
        let scale = height / maxTotal
        let hitH = CGFloat(Double(bucket.breakdown.cacheHit) * scale)
        let missH = CGFloat(Double(bucket.breakdown.cacheMiss) * scale)
        let outH = CGFloat(Double(bucket.breakdown.output) * scale)
        let visibleTotal = hitH + missH + outH

        return VStack(spacing: 0.5) {
            Spacer(minLength: 0)
            if outH > 0.4 { bar(DS.output, outH) }
            if missH > 0.4 { bar(DS.miss, missH) }
            if hitH > 0.4 { bar(DS.hit, hitH) }
            if visibleTotal < 1.2 { bar(Color.white.opacity(0.18), 1.5) }
        }
        .frame(maxWidth: .infinity)
        .help(tooltip(bucket))
    }

    private func bar(_ color: Color, _ h: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 1.2, style: .continuous)
            .fill(color)
            .frame(height: max(0.8, h))
    }

    private func emptyPlaceholder(height: CGFloat) -> some View {
        HStack {
            Spacer()
            Text(model.hasUserToken ? "暂无数据" : "需要平台令牌")
                .font(.system(size: 10.5))
                .foregroundStyle(DS.textTertiary)
            Spacer()
        }
        .frame(height: height)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.03)))
    }

    private func tooltip(_ bucket: UsageBucket) -> String {
        "\(bucket.label)：命中 \(Fmt.tokens(bucket.breakdown.cacheHit)) · 未命中 \(Fmt.tokens(bucket.breakdown.cacheMiss)) · 输出 \(Fmt.tokens(bucket.breakdown.output))"
            + (bucket.cost > 0 ? " · \(Fmt.moneyCompact(bucket.cost, currency: model.usage?.currency ?? "CNY"))" : "")
    }
}

// MARK: - 热力图

private struct HeatCell: Identifiable {
    let id: Int
    let weekday: Int
    let week: Int
    let tokens: Int64
    let label: String
}

struct HeatmapView: View {
    let buckets: [UsageBucket]
    let hasToken: Bool

    private var maxTokens: Int64 {
        max(1, buckets.map { $0.breakdown.totalTokens }.max() ?? 1)
    }

    /// 小时级：span ≤ 27 小时且相邻间隔 ≤ 2.5 小时
    private var hourlyBuckets: [UsageBucket]? {
        guard buckets.count >= 4 else { return nil }
        let times = buckets.map(\.time).sorted()
        guard let first = times.first, let last = times.last, last > first else { return nil }
        let span = last - first
        let step = span / Double(max(1, times.count - 1))
        guard span <= 27 * 3600, step > 0, step <= 2.5 * 3600 else { return nil }
        return buckets.sorted { $0.time < $1.time }
    }

    var body: some View {
        if buckets.isEmpty {
            HStack {
                Spacer()
                Text(hasToken ? "暂无数据" : "需要平台令牌")
                    .font(.system(size: 10.5))
                    .foregroundStyle(DS.textTertiary)
                Spacer()
            }
            .frame(height: 64)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.03)))
        } else if let hourly = hourlyBuckets {
            hourlyStrip(hourly)
        } else {
            weekGrid
        }
    }

    // MARK: 小时条

    private func hourlyStrip(_ items: [UsageBucket]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            GeometryReader { geo in
                let spacing: CGFloat = 2
                let count = CGFloat(items.count)
                let cellWidth = max(2, (geo.size.width - spacing * (count - 1)) / count)
                HStack(spacing: spacing) {
                    ForEach(items) { bucket in
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(color(for: bucket.breakdown.totalTokens))
                            .frame(width: cellWidth)
                            .help(label(for: bucket))
                    }
                }
            }
            .frame(height: 24)

            let ticks = hourTicks(items)
            HStack(spacing: 0) {
                ForEach(ticks.indices, id: \.self) { index in
                    Text(ticks[index])
                        .font(.ds(8))
                        .foregroundStyle(DS.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func hourTicks(_ items: [UsageBucket]) -> [String] {
        guard items.count > 1 else { return ["—"] }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH"
        let count = items.count
        // 取 4 个均匀采样点
        return [0, count / 3, count * 2 / 3, count - 1].map { index in
            formatter.string(from: Date(timeIntervalSince1970: items[max(0, min(count - 1, index))].time))
        }
    }

    // MARK: 星期 × 周 网格

    private var weekGrid: some View {
        let grid = buildGrid()
        return VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 4) {
                // 星期轴：只标 一/三/五/日，避免 7 行全标把标签挤成一条灰线
                VStack(spacing: 2) {
                    ForEach(0..<7, id: \.self) { weekday in
                        Text(weekdayMark(weekday))
                            .font(.system(size: 7.5))
                            .foregroundStyle(DS.textTertiary)
                            .frame(width: 12, height: 10, alignment: .trailing)
                    }
                }

                GeometryReader { geo in
                    let cellSize: CGFloat = 10
                    let spacing: CGFloat = 2
                    let maxWeeks = max(1, Int((geo.size.width + spacing) / (cellSize + spacing)))
                    let shown = min(grid.weeks, maxWeeks)
                    let startWeek = max(0, grid.weeks - shown)
                    let lookup = Dictionary(grid.cells.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

                    HStack(alignment: .top, spacing: spacing) {
                        ForEach(Array(startWeek..<max(startWeek + 1, grid.weeks)), id: \.self) { week in
                            VStack(spacing: spacing) {
                                ForEach(0..<7, id: \.self) { weekday in
                                    let cell = lookup[week * 7 + weekday]
                                    RoundedRectangle(cornerRadius: 2.2, style: .continuous)
                                        .fill(color(for: cell?.tokens ?? 0))
                                        .frame(width: cellSize, height: cellSize)
                                        .help(cell.map { "\($0.label)：\(Fmt.tokens($0.tokens)) tokens" } ?? "无记录")
                                }
                            }
                        }
                    }
                }
            }
            .frame(height: 7 * 10 + 6 * 2)

            HStack(spacing: 5) {
                Text("少").font(.system(size: 8.5)).foregroundStyle(DS.textTertiary)
                ForEach(0..<5, id: \.self) { level in
                    RoundedRectangle(cornerRadius: 1.8, style: .continuous)
                        .fill(DS.accent.opacity([0.16, 0.34, 0.55, 0.80, 1.0][level]))
                        .frame(width: 8, height: 8)
                }
                Text("多").font(.system(size: 8.5)).foregroundStyle(DS.textTertiary)
                Spacer(minLength: 4)
                Text(dateRangeLabel)
                    .font(.ds(8.5))
                    .foregroundStyle(DS.textTertiary)
                Text("峰值 \(Fmt.tokens(maxTokens))")
                    .font(.ds(8.5))
                    .foregroundStyle(DS.textTertiary)
            }
        }
    }

    /// 0 = 周一 … 6 = 周日
    private func weekdayMark(_ weekday: Int) -> String {
        switch weekday {
        case 0: return "一"
        case 2: return "三"
        case 4: return "五"
        case 6: return "日"
        default: return ""
        }
    }

    private var dateRangeLabel: String {
        let sorted = buckets.sorted { $0.time < $1.time }
        guard let first = sorted.first?.label, let last = sorted.last?.label else { return "" }
        return first == last ? first : "\(first) → \(last)"
    }

    private func buildGrid() -> (cells: [HeatCell], weeks: Int) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 2 // 周一
        calendar.timeZone = .current

        guard let earliest = buckets.map({ Date(timeIntervalSince1970: $0.time) }).min() else {
            return ([], 0)
        }
        let earliestWeek = calendar.dateInterval(of: .weekOfYear, for: earliest)?.start ?? earliest

        var cells: [HeatCell] = []
        var weeks = 0
        for bucket in buckets {
            let date = Date(timeIntervalSince1970: bucket.time)
            let weekStart = calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? date
            let week = calendar.dateComponents([.weekOfYear], from: earliestWeek, to: weekStart).weekOfYear ?? 0
            // Calendar 的 weekday：1=周日 … 7=周六 → 归一到 0=周一 … 6=周日
            let raw = calendar.component(.weekday, from: date)
            let weekday = (raw + 5) % 7
            weeks = max(weeks, week + 1)
            cells.append(HeatCell(id: week * 7 + weekday, weekday: weekday, week: week,
                                  tokens: bucket.breakdown.totalTokens, label: bucket.label))
        }
        return (cells, weeks)
    }

    // MARK: 配色

    private func color(for tokens: Int64) -> Color {
        guard tokens > 0 else { return Color.white.opacity(0.05) }
        let ratio = Double(tokens) / Double(maxTokens)
        // 开方压一下长尾，否则正态分布的数据会全挤在同一档，糊成一片
        let curved = pow(ratio, 0.62)
        switch min(4, Int(curved * 5)) {
        case 0: return DS.accent.opacity(0.16)
        case 1: return DS.accent.opacity(0.34)
        case 2: return DS.accent.opacity(0.55)
        case 3: return DS.accent.opacity(0.80)
        default: return DS.accentSoft
        }
    }

    private func label(for bucket: UsageBucket) -> String {
        "\(bucket.label)：\(Fmt.tokens(bucket.breakdown.totalTokens)) tokens · 命中率 \(Fmt.percent(bucket.breakdown.cacheHitRate))"
    }
}

/// 时间范围胶囊选择器
struct RangeSelector: View {
    @Binding var selection: UsageRange

    var body: some View {
        HStack(spacing: 2) {
            ForEach(UsageRange.allCases) { range in
                let active = range == selection
                Button {
                    guard selection != range else { return }
                    selection = range
                } label: {
                    Text(range.title)
                        .font(.system(size: 9.5, weight: active ? .semibold : .regular))
                        .foregroundStyle(active ? Color.white : DS.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(active ? DS.accent.opacity(0.9) : Color.clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(range.title + "的 token 用量与费用")
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.05))
        )
    }
}
