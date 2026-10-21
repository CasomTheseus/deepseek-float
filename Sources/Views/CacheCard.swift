import SwiftUI

/// 缓存命中卡 —— 这个悬浮窗最核心的指标。
/// DeepSeek 的缓存命中价与未命中价差一个数量级（如 flash：命中 ¥0.04/M vs 未命中 ¥2/M），
/// 所以「命中率」比「总 token」更能说明钱花得值不值。
///
/// 视觉细节：
/// - B4 双同心环：外环 = 缓存命中率，内环 = 输出占总量比例
/// - B3 命中率分级：≥90% 转亮青绿并加外发光 + 图标弹跳
/// - B2 构成条上循环掠过的流光
/// - E1 数字等宽
struct CacheCard: View {
    @EnvironmentObject var model: AppModel

    private var breakdown: TokenBreakdown { model.usage?.totals ?? TokenBreakdown() }

    private var tier: HitTier { HitTier.of(breakdown.cacheHitRate) }

    /// 内环：输出 token 占总量的比例
    private var outputShare: Double {
        let total = Double(breakdown.totalTokens)
        return total > 0 ? Double(breakdown.output) / total : 0
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(
                    text: "缓存命中",
                    trailing: model.usage?.scopeNote
                )

                if !model.canShowUsage {
                    Notice(
                        icon: "key.horizontal",
                        text: "token 用量走 platform.deepseek.com 私有接口，需要网页登录态令牌；sk- API Key 调不通这个接口。",
                        tint: DS.textTertiary,
                        actionTitle: "粘贴平台令牌",
                        action: { model.showSettings = true }
                    )
                } else if let error = model.usageError {
                    Notice(
                        icon: "exclamationmark.triangle.fill",
                        text: error,
                        tint: DS.miss,
                        actionTitle: "重新获取令牌",
                        action: { model.showSettings = true }
                    )
                } else if model.usage == nil {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("正在读取用量…").font(.system(size: 11)).foregroundStyle(DS.textSecondary)
                    }
                    .frame(height: 60)
                } else if breakdown.isEmpty {
                    Notice(icon: "tray", text: "该时间范围内没有调用记录。", tint: DS.textTertiary)
                        .frame(height: 60)
                } else {
                    HStack(alignment: .center, spacing: 13) {
                        rings
                        VStack(alignment: .leading, spacing: 6) {
                            Legend(color: tier.color, title: "命中", value: Fmt.tokens(breakdown.cacheHit))
                            Legend(color: DS.miss, title: "未命中", value: Fmt.tokens(breakdown.cacheMiss))
                            Legend(color: DS.output, title: "输出", value: Fmt.tokens(breakdown.output))
                            Text("内环 = 输出占比 \(Fmt.percent(outputShare))")
                                .font(.system(size: 8.5))
                                .foregroundStyle(DS.textTertiary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    CompositionBar(breakdown: breakdown, shimmer: model.panelVisible)
                    HStack(spacing: 6) {
                        Text("共 \(Fmt.tokens(breakdown.totalTokens)) tokens")
                        Spacer(minLength: 4)
                        tierChip
                        if breakdown.requests > 0 {
                            Text("\(Fmt.number(Int64(breakdown.requests))) 次")
                        }
                    }
                    .font(.system(size: 9.5))
                    .foregroundStyle(DS.textTertiary)
                }
            }
        }
    }

    // MARK: - 双同心环（B4）

    private var rings: some View {
        ZStack {
            // 外环：缓存命中率
            Circle()
                .stroke(Color.white.opacity(0.08), lineWidth: 6.5)

            Circle()
                .trim(from: 0, to: max(0.001, min(1, breakdown.cacheHitRate)))
                .stroke(
                    AngularGradient(
                        gradient: Gradient(colors: [tier.color.opacity(0.55), tier.color]),
                        center: .center,
                        startAngle: .degrees(0),
                        endAngle: .degrees(360)
                    ),
                    style: StrokeStyle(lineWidth: 6.5, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .shadow(color: tier.glows ? tier.color.opacity(0.7) : .clear, radius: 8)
                .animation(.spring(response: 0.55, dampingFraction: 0.62), value: breakdown.cacheHitRate)

            // 内环：输出占比
            Circle()
                .stroke(Color.white.opacity(0.06), lineWidth: 5)
                .padding(13)

            Circle()
                .trim(from: 0, to: max(0.001, min(1, outputShare)))
                .stroke(
                    DS.output.opacity(0.85),
                    style: StrokeStyle(lineWidth: 5, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .padding(13)
                .animation(.spring(response: 0.55, dampingFraction: 0.62), value: outputShare)

            VStack(spacing: -1) {
                Text(Fmt.percent(breakdown.cacheHitRate))
                    .font(.ds(13.5, .semibold, rounded: true))
                    .foregroundStyle(DS.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text("命中率")
                    .font(.system(size: 7.5))
                    .foregroundStyle(DS.textTertiary)
            }
            .padding(.horizontal, 4)
        }
        .frame(width: 74, height: 74)
        .help("外环 = 命中 token ÷（命中 + 未命中）；内环 = 输出 token ÷ 全部 token。\n命中价远低于未命中价，外环越高越省钱。")
    }

    // MARK: - 分级徽章（B3）

    private var tierChip: some View {
        HStack(spacing: 3) {
            if tier.glows {
                Image(systemName: "sparkles")
                    .font(.system(size: 8, weight: .semibold))
                    .symbolEffect(.bounce, value: tier == .excellent)
            }
            Text(tier.label)
                .font(.system(size: 9, weight: .semibold))
        }
        .foregroundStyle(tier.color)
        .padding(.horizontal, 5)
        .padding(.vertical, 1.5)
        .background(Capsule().fill(tier.color.opacity(0.14)))
        .overlay(Capsule().stroke(tier.color.opacity(0.26), lineWidth: 0.5))
        .help("命中率分级：≥90% 极佳 · ≥75% 良好 · ≥55% 一般 · 其余偏低")
    }
}
