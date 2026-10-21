import SwiftUI

enum Metrics {
    static let width: CGFloat = 312
    static let corner: CGFloat = 15
    static let pad: CGFloat = 11
    static let settingsHeight: CGFloat = 520
}

/// 悬浮窗根视图。高度靠 `reportHeight` 上报给 NSPanel，窗口随之自适应。
struct WidgetView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.snapshotMode) private var snapshotMode

    /// 极光漂移的往返开关（视觉细节 D5）
    @State private var auroraSwing = false
    /// 低余额呼吸告警的相位
    @State private var alertPulse = false

    var body: some View {
        ZStack {
            backdrop
            Group {
                if model.showSettings {
                    SettingsView()
                        .frame(height: snapshotMode ? nil : Metrics.settingsHeight)
                } else {
                    mainPanel
                }
            }
        }
        .frame(width: Metrics.width)
        // 强制按内容理想高度布局：否则 NSPanel 会把自身高度作为建议值传进来，
        // 上报的高度就等于当前窗口高度，形成自锁死循环
        .fixedSize(horizontal: false, vertical: true)
        .clipShape(RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous)
                .stroke(Color.white.opacity(0.13), lineWidth: 0.5)
        )
        .overlay(alertBorder)
        .reportHeight { model.reportContentHeight($0) }
    }

    // MARK: - 低余额告警

    /// 呼吸红边。这是低余额提醒的**主通道**：
    /// 系统通知在 ad-hoc 签名下拿不到权限（已实测，换新 bundle id 同样被拒），
    /// 而窗口是常驻可见的，边框呼吸比一条容易被错过的横幅更可靠，也不需要任何权限。
    @ViewBuilder
    private var alertBorder: some View {
        if model.isLowBalance {
            RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous)
                .strokeBorder(alertColor.opacity(alertPulse ? 0.85 : 0.28), lineWidth: 1.5)
                .shadow(color: alertColor.opacity(alertPulse ? 0.55 : 0.10), radius: alertPulse ? 12 : 3)
                .animation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true), value: alertPulse)
                .allowsHitTesting(false)
                .onAppear { alertPulse = true }
        }
    }

    private var alertColor: Color {
        model.statusLevel == .critical ? DS.spend : DS.peak
    }

    // MARK: - 背景

    private var backdrop: some View {
        ZStack {
            if !snapshotMode {
                VisualEffectView(material: .hudWindow, blending: .behindWindow)
            }
            LinearGradient(
                colors: [
                    Color(red: 0.06, green: 0.07, blue: 0.13).opacity(0.42 + 0.48 * model.opacity),
                    Color(red: 0.03, green: 0.04, blue: 0.08).opacity(0.50 + 0.46 * model.opacity),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            // D5 极光：两团品牌色辉光以 11s（往返 22s）周期缓慢漂移并呼吸。
            // 面板隐藏时停住，避免后台白烧 GPU。
            RadialGradient(
                colors: [DS.accent.opacity(auroraSwing ? 0.27 : 0.15), Color.clear],
                center: auroraSwing ? UnitPoint(x: 0.34, y: 0.05) : UnitPoint(x: -0.10, y: -0.08),
                startRadius: 0,
                endRadius: 215
            )
            RadialGradient(
                colors: [DS.output.opacity(auroraSwing ? 0.09 : 0.17), Color.clear],
                center: auroraSwing ? UnitPoint(x: 1.06, y: 0.94) : UnitPoint(x: 0.70, y: 1.10),
                startRadius: 0,
                endRadius: 235
            )
            // D1 噪点：消除大面积渐变的塑料感
            NoiseOverlay(opacity: 0.032)
        }
        .allowsHitTesting(false)
        .animation(.easeInOut(duration: 11).repeatForever(autoreverses: true), value: auroraSwing)
        .onAppear { auroraSwing = model.panelVisible }
        .onChange(of: model.panelVisible) { _, visible in auroraSwing = visible }
    }

    // MARK: - 主面板

    private var mainPanel: some View {
        VStack(spacing: 8) {
            header

            if !model.hasAPIKey {
                onboarding
            } else if model.expanded {
                BalanceCard()
                CacheCard()
                TrendCard()
                if model.showModels {
                    ModelListCard()
                }
                footer
            } else {
                collapsedRow
            }
        }
        .padding(Metrics.pad)
    }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: 7) {
            // 整块标题区都是拖拽热区（SwiftUI 内容设为不参与命中测试，让 AppKit 视图接管）
            ZStack(alignment: .leading) {
                if !snapshotMode { WindowDragHandle() }
                HStack(spacing: 7) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(LinearGradient(colors: [DS.accent, DS.accentSoft],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing))
                        Image(systemName: "water.waves")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .frame(width: 21, height: 21)

                    VStack(alignment: .leading, spacing: 0) {
                        Text("DeepSeek")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(DS.textPrimary)
                        Text(subtitle)
                            .font(.system(size: 8.5))
                            .foregroundStyle(DS.textTertiary)
                            .lineLimit(1)
                    }
                }
                .fixedSize()
                .allowsHitTesting(false)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 22)

            IconButton(
                systemName: model.isRefreshing ? "arrow.triangle.2.circlepath" : "arrow.clockwise",
                help: "立即刷新",
                tint: model.isRefreshing ? DS.accentSoft : DS.textSecondary
            ) {
                Task { await model.refresh(force: true) }
            }
            IconButton(systemName: "gearshape", help: "设置") {
                model.showSettings = true
            }
            IconButton(
                systemName: model.expanded ? "chevron.up" : "chevron.down",
                help: model.expanded ? "收起" : "展开"
            ) {
                withAnimation(.easeInOut(duration: 0.18)) { model.expanded.toggle() }
            }
        }
    }

    private var subtitle: String {
        if !model.hasAPIKey { return "未配置" }
        if let when = model.lastRefresh { return "更新于 " + Fmt.time.string(from: when) }
        return "就绪"
    }

    // MARK: - 未配置引导

    private var onboarding: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Text("粘贴 DeepSeek API Key")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(DS.textPrimary)
                Text("余额走官方接口，只认 sk- Key。创建地址：platform.deepseek.com/api_keys")
                    .font(.system(size: 9.5))
                    .foregroundStyle(DS.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(1.5)

                HStack(spacing: 6) {
                    PillButton(title: "打开设置") { model.showSettings = true }
                    if model.dshAvailable {
                        PillButton(title: "从 DSH 导入", tint: Color.white.opacity(0.16)) {
                            _ = model.importKeyFromDSH()
                        }
                    }
                    Spacer(minLength: 0)
                }

                Text("想同时看 token 用量与缓存命中，需要额外粘贴平台令牌（设置页第 ② 步）。")
                    .font(.system(size: 9))
                    .foregroundStyle(DS.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(1.5)
            }
        }
    }

    // MARK: - 收起态

    private var collapsedRow: some View {
        Card(padding: 9) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(model.balance.map { Fmt.moneyCompact($0.primary?.total ?? 0, currency: $0.primary?.currency ?? "CNY") } ?? "—")
                            .font(.ds(19, .semibold, rounded: true))
                            .foregroundStyle(DS.textPrimary)
                            .contentTransition(.numericText())
                            .animation(.snappy(duration: 0.45), value: model.balance?.primary?.total ?? 0)
                        peakTag
                    }
                    Text(model.statusLevel.label)
                        .font(.system(size: 8.5))
                        .foregroundStyle(model.statusLevel.color)
                }

                // 收起态同样要能看到余额变化 —— 这恰恰是桌宠最常驻的形态。
                // 之前气泡只挂在 BalanceCard 里，一收起来就彻底没了。
                // 这里放一个 0 尺寸锚点，气泡从它向右上方飘。
                ZStack(alignment: .bottomLeading) {
                    // 多枚同时出现时纵向错开
                    ForEach(Array(model.recentDeltas.indices), id: \.self) { index in
                        if index < model.recentDeltas.count {
                            DeltaBubble(delta: model.recentDeltas[index])
                                .offset(y: CGFloat(index) * -17)
                        }
                    }
                }
                .frame(width: 0, height: 0, alignment: .bottomLeading)
                .offset(y: 10)
                .allowsHitTesting(false)

                Spacer(minLength: 0)

                if model.hasUserToken, let totals = model.usage?.totals, !totals.isEmpty {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(Fmt.percent(totals.cacheHitRate))
                            .font(.ds(15, .semibold, rounded: true))
                            .foregroundStyle(HitTier.of(totals.cacheHitRate).color)
                        Text("缓存命中")
                            .font(.system(size: 8.5))
                            .foregroundStyle(DS.textTertiary)
                    }
                }
            }
        }
    }

    /// 收起态的峰谷价签：红「峰」= 高峰原价，绿「谷」= 空闲五折。
    ///
    /// 收起形态才是常驻可见的那一面，所以价格档位必须一眼能读到——
    /// 它直接决定「现在跑批划不划算」，比余额数字更有决策价值。
    private var peakTag: some View {
        let isPeak = model.isPeakNow
        return Text(isPeak ? "峰" : "谷")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(isPeak ? DS.peakTag : DS.offPeakTag)
            .accessibilityLabel(isPeak ? "高峰时段" : "空闲时段")
            .help(
                isPeak
                    ? "高峰时段：单价 ×1（北京时区 周一至周五 9:00–12:00、14:00–18:00）\n\(model.peakTransitionText)"
                    : "空闲时段：单价 5 折（其余时段，含周末与法定节假日全天）\n\(model.peakTransitionText)"
            )
    }

    // MARK: - 底栏

    private var footer: some View {
        HStack(spacing: 7) {
            statusChip("API", ok: model.hasAPIKey && model.balanceError == nil)
            statusChip("平台", ok: model.hasUserToken && model.usageError == nil)
            Spacer(minLength: 0)
            if let when = model.lastRefresh {
                Text(Fmt.relative(when))
                    .font(.system(size: 8.5))
                    .foregroundStyle(DS.textTertiary)
            }
        }
        .padding(.horizontal, 2)
        .padding(.top, 1)
    }

    private func statusChip(_ title: String, ok: Bool) -> some View {
        HStack(spacing: 3) {
            Circle()
                .fill(ok ? DS.hit : Color.white.opacity(0.22))
                .frame(width: 4.5, height: 4.5)
            Text(title)
                .font(.system(size: 8.5))
                .foregroundStyle(ok ? DS.textSecondary : DS.textTertiary)
        }
    }
}
