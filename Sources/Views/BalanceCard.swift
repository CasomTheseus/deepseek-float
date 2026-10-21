import SwiftUI

/// 余额卡：API Key 这一条通路唯一能拿到的官方数据。
///
/// 视觉细节：
/// - A1 余额变化时从数字右上角飘出 `-¥0.05` 气泡
/// - A2 数字滚动（numericText 过渡）
/// - A3 变化瞬间数字染红/绿再回落
/// - E1 全部数字等宽，刷新不抖动
struct BalanceCard: View {
    @EnvironmentObject var model: AppModel

    @State private var flash: Color?

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 9) {
                SectionLabel(
                    text: "账户余额",
                    trailing: model.balance.map { Fmt.relative($0.fetchedAt) }
                )

                if let info = model.balance?.primary {
                    amountRow(info)
                    breakdownRow(info)
                    divider
                    consumptionRow(info)
                } else if let error = model.balanceError {
                    Notice(
                        icon: "exclamationmark.triangle.fill",
                        text: error,
                        tint: model.hasAPIKey ? DS.miss : DS.textTertiary,
                        actionTitle: model.hasAPIKey ? nil : "去填写 API Key",
                        action: model.hasAPIKey ? nil : { model.showSettings = true }
                    )
                    .padding(.vertical, 2)
                } else {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("正在读取余额…")
                            .font(.system(size: 11))
                            .foregroundStyle(DS.textSecondary)
                    }
                    .frame(height: 44)
                }
            }
        }
        .onChange(of: model.latestDelta?.id) { _, _ in
            guard let delta = model.latestDelta else { return }
            flashColor(delta.isSpend ? DS.spend : DS.gain)
        }
    }

    // MARK: - 金额行

    private func amountRow(_ info: BalanceInfo) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text(symbol(info.currency))
                .font(.ds(17, .medium, rounded: true))
                .foregroundStyle(DS.textSecondary)
                .padding(.trailing, 1)

            Text(String(format: "%.2f", info.total))
                .font(.ds(31, .semibold, rounded: true))
                .foregroundStyle(flash ?? DS.textPrimary)
                .contentTransition(.numericText())
                .animation(.snappy(duration: 0.45), value: info.total)

            Text(info.currency)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(DS.textTertiary)
                .padding(.leading, 3)

            Spacer(minLength: 4)
            statusPill
        }
        // A1：气泡从这一行的右上角飘出。右侧留出状态胶囊的宽度，
        // 否则会正好压在「余额充足」上；向上飘则不会盖住下面的大字。
        .overlay(alignment: .topTrailing) {
            ZStack(alignment: .topTrailing) {
                // 多枚同时出现时纵向错开，否则会叠成一团看不清
                ForEach(Array(model.recentDeltas.indices), id: \.self) { index in
                    if index < model.recentDeltas.count {
                        DeltaBubble(delta: model.recentDeltas[index])
                            .offset(y: CGFloat(index) * -17)
                    }
                }
            }
            .padding(.trailing, 78)
            .allowsHitTesting(false)
        }
    }

    private func flashColor(_ color: Color) {
        withAnimation(.easeOut(duration: 0.10)) { flash = color }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.34) {
            withAnimation(.easeOut(duration: 0.50)) { flash = nil }
        }
    }

    private var statusPill: some View {
        HStack(spacing: 5) {
            StatusDot(color: model.statusLevel.color, pulsing: model.isRefreshing)
            Text(model.statusLevel.label)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(model.statusLevel.color)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3.5)
        .background(
            Capsule().fill(model.statusLevel.color.opacity(0.13))
        )
        .overlay(Capsule().stroke(model.statusLevel.color.opacity(0.22), lineWidth: 0.5))
    }

    // MARK: - 明细行

    private func breakdownRow(_ info: BalanceInfo) -> some View {
        HStack(alignment: .top, spacing: 12) {
            miniStat("充值余额", Fmt.moneyCompact(info.toppedUp, currency: info.currency))
            miniStat("赠送余额", Fmt.moneyCompact(info.granted, currency: info.currency))
            peakStat
            Spacer(minLength: 0)
        }
    }

    private func miniStat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.system(size: 9))
                .foregroundStyle(DS.textTertiary)
            Text(value)
                .font(.ds(11.5, .medium, rounded: true))
                .foregroundStyle(DS.textSecondary)
        }
    }

    /// 峰谷时段：官方口径见 PeakSchedule
    private var peakStat: some View {
        let isPeak = model.isPeakNow
        // 与收起态的单字价签同一套颜色（红=峰 / 绿=谷），
        // 否则同一概念两处不同色，会让人以为是两回事
        let tint = isPeak ? DS.peakTag : DS.offPeakTag
        return VStack(alignment: .leading, spacing: 1) {
            Text("时段")
                .font(.system(size: 9))
                .foregroundStyle(DS.textTertiary)
            HStack(spacing: 4) {
                Circle().fill(tint).frame(width: 5, height: 5)
                Text(isPeak ? "高峰 原价" : "空闲 5 折")
                    .font(.ds(11.5, .medium, rounded: true))
                    .foregroundStyle(tint)
            }
        }
        .help("官方口径：北京时间周一至周五 9:00–12:00、14:00–18:00 为高峰时段，其余时段（含周末及法定节假日全天）为空闲时段，空闲价正好是高峰价的一半。\n当前：\(model.peakTransitionText)。\n注：中国法定节假日未做离线判定，节假日当天会显示为高峰。")
    }

    private var divider: some View {
        Rectangle().fill(DS.stroke).frame(height: 0.5)
    }

    private func consumptionRow(_ info: BalanceInfo) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text("\(model.range.title)消耗")
                    .font(.system(size: 9))
                    .foregroundStyle(DS.textTertiary)
                if let cost = model.usage?.cost, cost > 0 {
                    Text(Fmt.moneyCompact(cost, currency: model.usage?.currency ?? info.currency))
                        .font(.ds(12, .medium, rounded: true))
                        .foregroundStyle(DS.textPrimary)
                } else if model.usage != nil && !model.usageHasCost {
                    // 本地日志源没有金额字段，写 "—" 会让人以为取数失败
                    Text("不提供")
                        .font(.ds(12, .medium, rounded: true))
                        .foregroundStyle(DS.textTertiary)
                        .help("当前用量来源是\(model.usageSource.title)，它只有 token 数、没有金额。命中率与 token 数见「缓存命中」卡。")
                } else {
                    Text("—")
                        .font(.ds(12, .medium, rounded: true))
                        .foregroundStyle(DS.textTertiary)
                }
            }

            Spacer(minLength: 0)

            if let hours = model.estimatedRemainingHours {
                VStack(alignment: .trailing, spacing: 1) {
                    Text("按当前速率可用")
                        .font(.system(size: 9))
                        .foregroundStyle(DS.textTertiary)
                    Text(remainingText(hours))
                        .font(.ds(12, .medium, rounded: true))
                        .foregroundStyle(DS.textPrimary)
                }
            } else if let rate = model.spendPerHour {
                VStack(alignment: .trailing, spacing: 1) {
                    Text("消耗速率")
                        .font(.system(size: 9))
                        .foregroundStyle(DS.textTertiary)
                    Text(String(format: "%@ / 小时", Fmt.moneyCompact(rate, currency: info.currency)))
                        .font(.ds(12, .medium, rounded: true))
                        .foregroundStyle(DS.textPrimary)
                }
            }
        }
    }

    private func remainingText(_ hours: Double) -> String {
        if hours >= 24 * 365 { return "一年以上" }
        if hours >= 24 { return String(format: "%.1f 天", hours / 24) }
        return String(format: "%.1f 小时", hours)
    }

    private func symbol(_ currency: String) -> String {
        currency.uppercased() == "USD" ? "$" : "¥"
    }
}
