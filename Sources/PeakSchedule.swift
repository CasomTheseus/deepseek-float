import Foundation

/// DeepSeek 峰谷时段判定。
///
/// 官方「模型 & 价格」页注 2 原文：
/// > 空闲时段价格为高峰时段价格的一半。北京时间周一至周五（不含中国法定节假日）
/// > 9:00 - 12:00、14:00 - 18:00 为高峰时段；其余时段，包括周末及中国法定节假日
/// > 全天均为空闲时段。
///
/// **已知近似**：中国法定节假日无法离线可靠判定，这里按普通工作日处理，
/// 因此调休/节假日当天会被显示成高峰（偏保守，不会让你以为便宜了）。
/// UI 的 tooltip 里必须如实说明这一点。
enum PeakSchedule {

    /// 官方按北京时间定义，与使用者所在时区无关
    static let beijing = TimeZone(secondsFromGMT: 8 * 3600) ?? .current

    static let peakWindows: [(startHour: Int, endHour: Int)] = [(9, 12), (14, 18)]

    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = beijing
        return calendar
    }

    /// 是否处于高峰时段
    static func isPeak(at date: Date = Date()) -> Bool {
        let calendar = calendar
        let components = calendar.dateComponents([.weekday, .hour, .minute], from: date)
        guard let weekday = components.weekday, let hour = components.hour else { return false }
        // Calendar: 1 = 周日, 2 = 周一 … 7 = 周六
        guard (2...6).contains(weekday) else { return false }
        let minutes = hour * 60 + (components.minute ?? 0)
        return peakWindows.contains { window in
            minutes >= window.startHour * 60 && minutes < window.endHour * 60
        }
    }

    /// 距离下一次峰谷切换还有多久，以及切换后是否进入高峰。
    /// 做法：把未来 8 天里所有「高峰窗口的起点与终点」都列出来，取最近的一个未来时刻。
    /// 周末不产生任何候选点，因此周五收盘后会自动跳到下周一 9:00。
    static func nextTransition(from date: Date = Date()) -> (date: Date, becomesPeak: Bool) {
        let calendar = calendar
        var candidates: [(date: Date, becomesPeak: Bool)] = []

        for dayOffset in 0...8 {
            guard let day = calendar.date(byAdding: .day, value: dayOffset, to: date) else { continue }
            let weekday = calendar.component(.weekday, from: day)
            guard (2...6).contains(weekday) else { continue } // 周末全天低谷，无边界的峰谷切换

            for window in peakWindows {
                if let start = calendar.date(bySettingHour: window.startHour, minute: 0, second: 0, of: day) {
                    candidates.append((start, true))
                }
                if let end = calendar.date(bySettingHour: window.endHour, minute: 0, second: 0, of: day) {
                    candidates.append((end, false))
                }
            }
        }

        let upcoming = candidates.filter { $0.date > date }.sorted { $0.date < $1.date }
        return upcoming.first ?? (date.addingTimeInterval(3600), !isPeak(at: date))
    }

    /// 人类可读的倒计时："1 小时 20 分"
    static func countdown(to target: Date, from date: Date = Date()) -> String {
        let seconds = max(0, target.timeIntervalSince(date))
        let totalMinutes = Int(seconds / 60)
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours > 0 { return "\(hours) 小时 \(minutes) 分" }
        if minutes > 0 { return "\(minutes) 分钟" }
        return "不到 1 分钟"
    }
}
