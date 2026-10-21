import Foundation
import SwiftUI

/// 全局状态与刷新调度。
///
/// 余额与用量是两条互相独立的通路：任意一条失败只影响自己的卡片，
/// 余额（只需 API Key）永远优先可用。
@MainActor
final class AppModel: ObservableObject {

    // MARK: - 凭据状态
    @Published private(set) var hasAPIKey = false
    @Published private(set) var hasUserToken = false
    @Published private(set) var maskedAPIKey = ""

    // MARK: - 数据
    @Published private(set) var balance: BalanceSnapshot?
    @Published private(set) var usage: UsageSnapshot?
    @Published private(set) var monthlyUsage: UsageSnapshot?

    @Published private(set) var balanceError: String?
    @Published private(set) var usageError: String?

    @Published private(set) var isRefreshing = false
    @Published private(set) var lastRefresh: Date?
    /// 余额历史采样，用于估算消耗速率
    @Published private(set) var balanceHistory: [(date: Date, total: Double)] = []
    /// 最近发生的余额增减，用于弹出 `-¥0.05` 气泡（视觉细节 A1）
    @Published private(set) var recentDeltas: [BalanceDelta] = []

    // MARK: - 偏好（持久化到 UserDefaults）
    @Published var range: UsageRange = .today { didSet { persist(); requestUsageRefresh() } }
    @Published var chartMode: ChartMode = .heat { didSet { persist() } }
    @Published var refreshInterval: Double = 60 { didSet { persist(); restartTimer() } }
    @Published var opacity: Double = 0.94 { didSet { persist() } }
    @Published var alwaysOnTop: Bool = true { didSet { persist() } }
    @Published var expanded: Bool = true { didSet { persist() } }
    @Published var showModels: Bool = true { didSet { persist() } }
    @Published var lowBalanceThreshold: Double = 5 { didSet { persist() } }
    @Published var notificationsEnabled: Bool = true { didSet { persist() } }
    @Published var hideWhenIdle: Bool = true { didSet { persist() } }
    @Published var launchAtLogin: Bool = false { didSet { persist(); applyLaunchAtLogin() } }

    // MARK: - 瞬时 UI 状态（不持久化）
    @Published var showSettings = false
    @Published var panelVisible = true
    /// SwiftUI 内容自然高度，NSPanel 据此自适应
    @Published var contentHeight: CGFloat = 0

    /// 由视图在布局阶段回调，切到主线程并做去抖，避免布局期间改状态
    func reportContentHeight(_ height: CGFloat) {
        guard height > 1, abs(height - contentHeight) > 0.5 else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, abs(height - self.contentHeight) > 0.5 else { return }
            self.contentHeight = height
        }
    }

    // MARK: - 内部
    private var loaded = false
    private var timer: Timer?
    private var lastBalanceFetch: Date = .distantPast
    private var lastUsageFetch: Date = .distantPast
    private var lastMonthlyFetch: Date = .distantPast
    private var lowBalanceNotified = false
    private var lastKnownTotal: Double?
    private var balanceTask: Task<Void, Never>?
    private var usageTask: Task<Void, Never>?

    private let credentials = CredentialStore.shared

    init(startAutomatically: Bool = true, withSampleData: Bool = true, sampleDaily: Bool = false) {
        loadPreferences()
        syncCredentialFlags()
        if startAutomatically {
            // loaded 是「可以写回 UserDefaults」的闸门。
            // 离屏渲染/预览这类模式不能让 loaded 变 true，否则 --render --collapsed
            // 会把 expanded=false 写进用户的真实配置。
            loaded = true
            restartTimer()
            refreshNotificationStatus()
            Task { await refresh(force: true) }
        } else if withSampleData {
            installSampleData(daily: sampleDaily)
        }
    }

    /// 系统通知权限状态，用来在设置页给出准确反馈而不是让用户以为开了却没收到
    @Published var notificationStatus: String = "未知"

    func refreshNotificationStatus() {
        Notifier.authorizationStatus { [weak self] status in
            self?.notificationStatus = status
        }
    }

    // MARK: - 示例数据（离屏渲染 / 预览用，不参与联网）

    private func installSampleData(daily: Bool) {
        hasAPIKey = true
        hasUserToken = true
        // 此时 loaded 仍为 false，didSet 里的 persist/联网都会被闸门挡住
        range = daily ? .last90d : .today
        chartMode = .heat
        // 故意用一眼假的占位串。绝不能用真实 Key 的片段——
        // 示例数据会被渲染进 docs/ 的截图里，而那些截图会随仓库公开。
        maskedAPIKey = "sk-demo••••••demo0"
        balance = BalanceSnapshot(
            isAvailable: true,
            infos: [BalanceInfo(currency: "CNY", total: 343.91, granted: 0, toppedUp: 343.91)],
            fetchedAt: Date()
        )
        lastRefresh = Date()

        // 供 A1 气泡做视觉验收；同时建立基线，让预览态与真实态行为一致
        lastKnownTotal = 343.91
        recentDeltas = [BalanceDelta(amount: -0.05, currency: "CNY")]

        let now = Date()
        var buckets: [UsageBucket] = []
        let count = daily ? 84 : 24
        let stepHours: Double = daily ? 24 : 1
        let scale: Int64 = daily ? 7 : 1

        for index in stride(from: count - 1, through: 0, by: -1) {
            let stamp = now.addingTimeInterval(-Double(index) * stepHours * 3600)
            let seed = Double(index + 1)

            // 伪随机活动量 + 周末低谷，制造明显的日间差异，
            // 否则热力图会糊成一片同色，看不出分布
            let noise = Double(Int(seed * 37.7) % 100) / 100.0
            var activity = 0.10 + noise * 1.05
            if daily {
                let weekday = Calendar.current.component(.weekday, from: stamp)
                if weekday == 1 || weekday == 7 { activity *= 0.28 }
            }

            let base = Double(scale) * activity
            let hit = Int64((41_000 + (seed * 7_919).truncatingRemainder(dividingBy: 63_000)) * base)
            let miss = Int64((8_500 + (seed * 4_127).truncatingRemainder(dividingBy: 19_000)) * base)
            let out = Int64((2_800 + (seed * 2_311).truncatingRemainder(dividingBy: 7_400)) * base)
            let cost = Double(hit) / 1_000_000 * 0.1
                + Double(miss) / 1_000_000 * 1.0
                + Double(out) / 1_000_000 * 2.0
            buckets.append(UsageBucket(
                time: stamp.timeIntervalSince1970,
                breakdown: TokenBreakdown(cacheHit: hit, cacheMiss: miss, output: out, requests: 0),
                cost: cost,
                label: daily ? Fmt.day.string(from: stamp) : Fmt.time.string(from: stamp)
            ))
        }

        let totals = buckets.reduce(TokenBreakdown()) { $0 + $1.breakdown }
        var withRequests = totals
        withRequests.requests = 412

        var snapshot = UsageSnapshot()
        snapshot.totals = withRequests
        snapshot.cost = buckets.reduce(0) { $0 + $1.cost }
        snapshot.buckets = buckets
        snapshot.scopeNote = range.title
        snapshot.fetchedAt = now
        usage = snapshot

        var monthly = UsageSnapshot()
        monthly.scopeNote = "本月分模型"
        monthly.currency = "CNY"
        monthly.totals = TokenBreakdown(cacheHit: 9_812_400, cacheMiss: 2_104_900, output: 613_300, requests: 3_184)
        monthly.cost = 12.47
        monthly.models = [
            ModelUsage(model: "deepseek-chat",
                       breakdown: TokenBreakdown(cacheHit: 7_420_100, cacheMiss: 1_580_200, output: 402_700, requests: 2_406),
                       cost: 8.31),
            ModelUsage(model: "deepseek-reasoner",
                       breakdown: TokenBreakdown(cacheHit: 2_392_300, cacheMiss: 524_700, output: 210_600, requests: 778),
                       cost: 4.16),
        ]
        monthlyUsage = monthly

        balanceHistory = [
            (now.addingTimeInterval(-6 * 3600), 346.12),
            (now.addingTimeInterval(-3 * 3600), 345.04),
            (now, 343.91),
        ]
    }

    // MARK: - 偏好读写

    private enum Key {
        static let range = "usageRange"
        static let chartMode = "chartMode"
        static let refreshInterval = "refreshInterval"
        static let opacity = "panelOpacity"
        static let alwaysOnTop = "alwaysOnTop"
        static let expanded = "expanded"
        static let showModels = "showModels"
        static let threshold = "lowBalanceThreshold"
        static let notifications = "notificationsEnabled"
        static let hideWhenIdle = "hideWhenIdle"
        static let launchAtLogin = "launchAtLogin"
        static let windowFrame = "panelFrame"
    }

    private func loadPreferences() {
        let d = UserDefaults.standard
        if let raw = d.string(forKey: Key.range), let r = UsageRange(rawValue: raw) { range = r }
        if let raw = d.string(forKey: Key.chartMode), let m = ChartMode(rawValue: raw) { chartMode = m }
        if d.object(forKey: Key.refreshInterval) != nil { refreshInterval = d.double(forKey: Key.refreshInterval) }
        if d.object(forKey: Key.opacity) != nil { opacity = d.double(forKey: Key.opacity) }
        if d.object(forKey: Key.alwaysOnTop) != nil { alwaysOnTop = d.bool(forKey: Key.alwaysOnTop) }
        if d.object(forKey: Key.expanded) != nil { expanded = d.bool(forKey: Key.expanded) }
        if d.object(forKey: Key.showModels) != nil { showModels = d.bool(forKey: Key.showModels) }
        if d.object(forKey: Key.threshold) != nil { lowBalanceThreshold = d.double(forKey: Key.threshold) }
        if d.object(forKey: Key.notifications) != nil { notificationsEnabled = d.bool(forKey: Key.notifications) }
        if d.object(forKey: Key.hideWhenIdle) != nil { hideWhenIdle = d.bool(forKey: Key.hideWhenIdle) }
        launchAtLogin = LaunchAtLogin.isEnabled
    }

    private func persist() {
        guard loaded else { return }
        let d = UserDefaults.standard
        d.set(range.rawValue, forKey: Key.range)
        d.set(chartMode.rawValue, forKey: Key.chartMode)
        d.set(refreshInterval, forKey: Key.refreshInterval)
        d.set(opacity, forKey: Key.opacity)
        d.set(alwaysOnTop, forKey: Key.alwaysOnTop)
        d.set(expanded, forKey: Key.expanded)
        d.set(showModels, forKey: Key.showModels)
        d.set(lowBalanceThreshold, forKey: Key.threshold)
        d.set(notificationsEnabled, forKey: Key.notifications)
        d.set(hideWhenIdle, forKey: Key.hideWhenIdle)
    }

    // MARK: - 窗口位置记忆

    var savedFrame: NSRect? {
        get {
            guard let s = UserDefaults.standard.string(forKey: Key.windowFrame) else { return nil }
            let r = NSRectFromString(s)
            return r.width > 0 ? r : nil
        }
        set {
            guard let newValue else { return }
            UserDefaults.standard.set(NSStringFromRect(newValue), forKey: Key.windowFrame)
        }
    }

    // MARK: - 凭据

    private func syncCredentialFlags() {
        hasAPIKey = credentials.hasAPIKey
        hasUserToken = credentials.hasUserToken
        maskedAPIKey = credentials.maskedAPIKey()
    }

    func saveAPIKey(_ value: String) {
        credentials.setAPIKey(value)
        syncCredentialFlags()
        lowBalanceNotified = false
        lastBalanceFetch = .distantPast
        Task { await refresh(force: true) }
    }

    func saveUserToken(_ value: String) {
        credentials.setUserToken(value)
        syncCredentialFlags()
        lastUsageFetch = .distantPast
        Task { await refreshUsage(force: true) }
    }

    func clearCredentials() {
        credentials.clearAll()
        syncCredentialFlags()
        balance = nil; usage = nil; monthlyUsage = nil
        balanceError = nil; usageError = nil
        balanceHistory = []
    }

    func importKeyFromDSH() -> Bool {
        guard let key = CredentialStore.importAPIKeyFromDSH() else { return false }
        saveAPIKey(key)
        return true
    }

    var dshAvailable: Bool { CredentialStore.dshCredentialFileExists }

    // MARK: - 刷新

    func refresh(force: Bool = false) async {
        if isRefreshing && !force { return }
        isRefreshing = true
        defer { isRefreshing = false }
        await refreshBalance(force: force)
        await refreshUsage(force: force)
        lastRefresh = Date()
    }

    func refreshBalance(force: Bool = false) async {
        guard hasAPIKey else {
            balanceError = DSFloatError.missingAPIKey.errorDescription
            balance = nil
            return
        }
        // 防抖：短时间内的重复请求直接合并，避免连点右键菜单打爆接口
        let minGap: TimeInterval = force ? 1.0 : 5.0
        if Date().timeIntervalSince(lastBalanceFetch) < minGap, balance != nil { return }
        lastBalanceFetch = Date()

        do {
            let snapshot = try await DeepSeekAPI.fetchBalance(apiKey: credentials.apiKey)
            balance = snapshot
            balanceError = nil
            recordBalanceSample(snapshot)
            recordDelta(snapshot)
            evaluateLowBalance(snapshot)
        } catch {
            balanceError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func refreshUsage(force: Bool = false) async {
        guard hasUserToken else {
            usageError = nil
            return
        }
        let minGap: TimeInterval = force ? 1.0 : 20.0
        if Date().timeIntervalSince(lastUsageFetch) < minGap, usage != nil { return }
        lastUsageFetch = Date()

        do {
            let snapshot = try await DeepSeekAPI.fetchWindowUsage(userToken: credentials.userToken, range: range)
            usage = snapshot
            usageError = nil
        } catch {
            usageError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }

        // 分模型 / 请求次数只有月度接口给。首次必拉；之后按 10 分钟节流，
        // 免得停在「今日」范围时模型卡片一直不更新。
        let monthlyStale = Date().timeIntervalSince(lastMonthlyFetch) > 600
        if range.isMonthlyAPIWorthwhile || monthlyUsage == nil || (monthlyStale && force) {
            if let monthly = try? await DeepSeekAPI.fetchMonthlyUsage(userToken: credentials.userToken) {
                monthlyUsage = monthly
                lastMonthlyFetch = Date()
            }
        }
    }

    /// 范围切换时立刻拉新数据（带节流）。
    /// `loaded` 为假说明是预览/渲染模式，绝不能因为改个属性就去联网。
    private func requestUsageRefresh() {
        guard loaded else { return }
        Task { await refreshUsage(force: true) }
    }

    // MARK: - 定时

    private var effectiveInterval: TimeInterval {
        let base = max(15, refreshInterval)
        if hideWhenIdle && !panelVisible { return max(base, 300) }
        return base
    }

    private func restartTimer() {
        timer?.invalidate()
        let t = Timer.scheduledTimer(withTimeInterval: effectiveInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func panelVisibilityChanged(_ visible: Bool) {
        let previous = panelVisible
        panelVisible = visible
        guard hideWhenIdle, previous != visible else { return }
        restartTimer()
        if visible { Task { await refresh() } }
    }

    /// 与上一次已知余额比较，产生一枚会飘走的气泡。
    private func recordDelta(_ snapshot: BalanceSnapshot) {
        guard let info = snapshot.primary else { return }
        let previous = lastKnownTotal
        lastKnownTotal = info.total

        guard let delta = BalanceDelta.change(previous: previous, current: info.total, currency: info.currency) else { return }
        emit(delta)
    }

    /// 把一枚变化推入待显示队列
    private func emit(_ delta: BalanceDelta) {
        recentDeltas.append(delta)
        if recentDeltas.count > 3 { recentDeltas.removeFirst(recentDeltas.count - 3) }

        // 气泡动画约 1.2s，多留一点余量再摘掉
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_900_000_000)
            self?.recentDeltas.removeAll { $0.id == delta.id }
        }
    }

    /// 测试钩子：注入一次合成变化，用来验收 A1/A2/A3 的视觉反馈，
    /// 不必真的花钱、也不必等下一次真实刷新。
    /// 金额为 0 时随机取 0.03～0.60 的扣费。
    @discardableResult
    func simulateBalanceChange(_ amount: Double? = nil) -> Bool {
        guard let info = balance?.primary else { return false }
        let change = amount ?? -(Double(Int.random(in: 3...60)) / 100.0)
        // 归整到「分」：不然 343.91 - 0.07 会得到 343.84000000000003，
        // 多次模拟会一点点漂离分边界（显示看不出，但模型不该带这种脏值）
        let newTotal = max(0, ((info.total + change) * 100).rounded() / 100)

        balance = BalanceSnapshot(
            isAvailable: balance?.isAvailable ?? true,
            infos: [BalanceInfo(currency: info.currency, total: newTotal,
                                granted: info.granted, toppedUp: info.toppedUp)],
            fetchedAt: Date()
        )
        if let updated = balance {
            recordBalanceSample(updated)
            recordDelta(updated)
        }
        return true
    }

    /// 最近一次变化，供数字色闪使用
    var latestDelta: BalanceDelta? { recentDeltas.last }

    // MARK: - 峰谷时段

    /// 仅预览/截图用：强制指定峰谷状态，nil 表示按真实时间判定。
    /// 没有它就没法在同一个时间点把「峰」「谷」两种价签都截出来做验收。
    var peakOverride: Bool?

    var isPeakNow: Bool { peakOverride ?? PeakSchedule.isPeak() }

    /// 例：「1 小时 20 分后进入空闲时段」
    var peakTransitionText: String {
        let next = PeakSchedule.nextTransition()
        return PeakSchedule.countdown(to: next.date) + "后" + (next.becomesPeak ? "进入高峰" : "进入空闲")
    }

    // MARK: - 余额速率与提醒

    private func recordBalanceSample(_ snapshot: BalanceSnapshot) {
        guard let total = snapshot.primary?.total else { return }
        balanceHistory.append((Date(), total))
        // 只保留最近 24 小时的采样
        let cutoff = Date().addingTimeInterval(-24 * 3600)
        balanceHistory.removeAll { $0.date < cutoff }
        if balanceHistory.count > 500 { balanceHistory.removeFirst(balanceHistory.count - 500) }
    }

    /// 基于余额下滑估算的每小时消耗（元/小时）
    var spendPerHour: Double? {
        guard balanceHistory.count >= 2,
              let first = balanceHistory.first, let last = balanceHistory.last else { return nil }
        let hours = last.date.timeIntervalSince(first.date) / 3600
        guard hours > 0.05 else { return nil }
        let delta = first.total - last.total
        guard delta > 0 else { return nil }
        return delta / hours
    }

    /// 按当前速率，余额还能撑多久
    var estimatedRemainingHours: Double? {
        guard let rate = spendPerHour, rate > 0.0001, let total = balance?.primary?.total, total > 0 else { return nil }
        return total / rate
    }

    private func evaluateLowBalance(_ snapshot: BalanceSnapshot) {
        guard notificationsEnabled, let info = snapshot.primary else { return }
        if info.total < lowBalanceThreshold, !lowBalanceNotified {
            lowBalanceNotified = true
            Notifier.lowBalance(amount: info.total, currency: info.currency, threshold: lowBalanceThreshold)
        } else if info.total >= lowBalanceThreshold * 1.2 {
            // 充值后复位，下次再低还能提醒
            lowBalanceNotified = false
        }
    }

    // MARK: - 开机自启

    private func applyLaunchAtLogin() {
        guard loaded else { return }
        LaunchAtLogin.set(launchAtLogin)
    }

    // MARK: - 派生的展示值

    var cacheHitRate: Double { usage?.totals.cacheHitRate ?? 0 }

    var statusLevel: StatusLevel {
        guard let info = balance?.primary else { return .unknown }
        if !(balance?.isAvailable ?? false) { return .critical }
        if info.total <= 0 { return .critical }
        if info.total < lowBalanceThreshold { return .warning }
        return .healthy
    }

    /// 是否进入告警态。面板据此显示呼吸红边——这是**不需要任何系统权限**的
    /// 低余额提醒通道，因为在 ad-hoc 签名下系统通知拿不到权限
    /// （已实测：连换一个全新 bundle id 也照样被拒，所以不是记录陈旧的问题）。
    var isLowBalance: Bool {
        statusLevel == .warning || statusLevel == .critical
    }

    enum StatusLevel {
        case healthy, warning, critical, unknown
        var color: Color {
            switch self {
            case .healthy: return Color(red: 0.29, green: 0.85, blue: 0.53)
            case .warning: return Color(red: 1.0, green: 0.76, blue: 0.25)
            case .critical: return Color(red: 1.0, green: 0.36, blue: 0.36)
            case .unknown: return Color.white.opacity(0.35)
            }
        }
        var label: String {
            switch self {
            case .healthy: return "余额充足"
            case .warning: return "余额偏低"
            case .critical: return "余额耗尽"
            case .unknown: return "未连接"
            }
        }
    }
}
