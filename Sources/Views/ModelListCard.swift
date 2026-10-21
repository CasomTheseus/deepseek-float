import SwiftUI

/// 分模型明细。月度接口才会给 model 维度，所以优先用它。
struct ModelListCard: View {
    @EnvironmentObject var model: AppModel

    private var models: [ModelUsage] {
        let monthly = model.monthlyUsage?.models ?? []
        if !monthly.isEmpty { return monthly }
        return model.usage?.models ?? []
    }

    private var scope: String {
        let monthly = model.monthlyUsage?.models ?? []
        return monthly.isEmpty ? (model.usage?.scopeNote ?? "") : "本月"
    }

    private var maxTokens: Double {
        max(1, models.map { Double($0.breakdown.totalTokens) }.max() ?? 1)
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: "分模型", trailing: scope)

                if models.isEmpty {
                    Text(model.canShowUsage ? "暂无分模型数据" : model.usageEmptyHint)
                        .font(.system(size: 10.5))
                        .foregroundStyle(DS.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 10)
                } else {
                    ForEach(models.prefix(6)) { item in
                        row(item)
                    }
                    if models.count > 6 {
                        Text("另有 \(models.count - 6) 个模型未显示")
                            .font(.system(size: 9))
                            .foregroundStyle(DS.textTertiary)
                    }
                }
            }
        }
    }

    private func row(_ item: ModelUsage) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(displayName(item.model))
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(DS.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if item.cost > 0 {
                    Text(Fmt.moneyCompact(item.cost, currency: model.monthlyUsage?.currency ?? model.usage?.currency ?? "CNY"))
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(DS.textSecondary)
                } else {
                    Text(Fmt.tokens(item.breakdown.totalTokens))
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(DS.textSecondary)
                }
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.06))
                    Capsule()
                        .fill(
                            LinearGradient(colors: [DS.accent.opacity(0.75), DS.accentSoft],
                                           startPoint: .leading, endPoint: .trailing)
                        )
                        .frame(width: max(2, geo.size.width * CGFloat(Double(item.breakdown.totalTokens) / maxTokens)))
                }
            }
            .frame(height: 4)
            HStack(spacing: 7) {
                if let average = averageCostPerMillion(item) {
                    Text(average)
                        .font(.ds(8.5, .semibold))
                        .foregroundStyle(DS.textSecondary)
                    Text("·")
                }
                Text("命中 \(Fmt.tokens(item.breakdown.cacheHit))")
                Text("未命中 \(Fmt.tokens(item.breakdown.cacheMiss))")
                Text("输出 \(Fmt.tokens(item.breakdown.output))")
            }
            .font(.ds(8.5))
            .foregroundStyle(DS.textTertiary)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
        }
        .padding(.vertical, 1)
    }

    /// 每百万 token 平均费用 = 实际费用 ÷ 实际 token 数 × 100 万。
    /// 完全从真实账单数据反推，不依赖任何单价假设，因此跨模型、跨时段可比。
    private func averageCostPerMillion(_ item: ModelUsage) -> String? {
        let tokens = Double(item.breakdown.totalTokens)
        guard item.cost > 0, tokens > 0 else { return nil }
        let currency = model.monthlyUsage?.currency ?? model.usage?.currency ?? "CNY"
        let symbol = currency.uppercased() == "USD" ? "$" : "¥"
        return String(format: "均 %@%.2f/M", symbol, item.cost / tokens * 1_000_000)
    }

    /// `deepseek-chat` → `chat`，`deepseek-reasoner` → `reasoner`，保留可读性又省宽度
    private func displayName(_ raw: String) -> String {
        raw.hasPrefix("deepseek-") ? String(raw.dropFirst("deepseek-".count)) : raw
    }
}
