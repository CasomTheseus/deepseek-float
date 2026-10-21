import SwiftUI
import AppKit

// MARK: - 配色

enum DS {
    /// DeepSeek 品牌蓝
    static let accent = Color(red: 0.30, green: 0.42, blue: 1.0)
    static let accentSoft = Color(red: 0.45, green: 0.56, blue: 1.0)

    static let hit = Color(red: 0.29, green: 0.85, blue: 0.53)       // 缓存命中：绿
    static let hitBright = Color(red: 0.35, green: 0.95, blue: 0.72) // 命中率优秀：亮青绿
    static let miss = Color(red: 1.00, green: 0.66, blue: 0.30)      // 缓存未命中：橙
    static let output = Color(red: 0.55, green: 0.62, blue: 1.00)    // 输出：蓝

    static let spend = Color(red: 1.00, green: 0.42, blue: 0.44)     // 花费（气泡/色闪）：红
    static let gain = Color(red: 0.32, green: 0.88, blue: 0.58)      // 充值：绿

    static let peak = Color(red: 1.00, green: 0.62, blue: 0.30)      // 高峰时段
    static let offPeak = Color(red: 0.38, green: 0.82, blue: 0.62)   // 空闲时段

    /// 峰谷单字价签（收起态用）：红=高峰，绿=空闲。
    /// 与上面的 peak/offPeak 分开，是因为那两个还兼作「低余额告警」等处的语义色，
    /// 直接把 peak 改成红色会让告警态和价签撞色。
    static let peakTag = Color(red: 1.00, green: 0.40, blue: 0.42)
    static let offPeakTag = Color(red: 0.35, green: 0.90, blue: 0.62)

    static let textPrimary = Color.white.opacity(0.96)
    static let textSecondary = Color.white.opacity(0.62)
    static let textTertiary = Color.white.opacity(0.38)

    static let stroke = Color.white.opacity(0.10)
    static let surface = Color.white.opacity(0.055)
    static let surfaceStrong = Color.white.opacity(0.09)

    static let corner: CGFloat = 12
}

/// 命中率的分级（视觉细节 B3）：把「省钱」变成一个可被奖励的状态
enum HitTier {
    case excellent, good, fair, poor

    static func of(_ rate: Double) -> HitTier {
        if rate >= 0.90 { return .excellent }
        if rate >= 0.75 { return .good }
        if rate >= 0.55 { return .fair }
        return .poor
    }

    var color: Color {
        switch self {
        case .excellent: return DS.hitBright
        case .good: return DS.hit
        case .fair: return DS.miss
        case .poor: return DS.spend
        }
    }

    var label: String {
        switch self {
        case .excellent: return "极佳"
        case .good: return "良好"
        case .fair: return "一般"
        case .poor: return "偏低"
        }
    }

    /// 只有最优秀的一档才给光晕，避免满屏发光
    var glows: Bool { self == .excellent }
}

// MARK: - 字体（视觉细节 E1）

extension Font {
    /// 所有数字都用等宽数位：刷新时位数变化不会让布局左右抖动
    static func ds(_ size: CGFloat, _ weight: Font.Weight = .regular, rounded: Bool = false) -> Font {
        let base: Font = rounded
            ? .system(size: size, weight: weight, design: .rounded)
            : .system(size: size, weight: weight)
        return base.monospacedDigit()
    }
}

// MARK: - 毛玻璃

struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blending: NSVisualEffectView.BlendingMode = .behindWindow
    var strength: Double = 1.0

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blending
        view.state = .active
        view.alphaValue = strength
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blending
        view.state = .active
        view.alphaValue = strength
    }
}

// MARK: - 卡片与区块

struct Card<Content: View>: View {
    private let padding: CGFloat
    private let content: Content

    init(padding: CGFloat = 11, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DS.corner, style: .continuous)
                    .fill(DS.surface)
            )
            // 视觉细节 D2 + D3：上边缘亮、下边缘有极弱反光的角度渐变描边，
            // 模拟玻璃被光打到的边，而不是一圈死板的均匀描边
            .overlay(
                RoundedRectangle(cornerRadius: DS.corner, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            stops: [
                                .init(color: Color.white.opacity(0.26), location: 0.00),
                                .init(color: Color.white.opacity(0.07), location: 0.28),
                                .init(color: Color.white.opacity(0.015), location: 0.62),
                                .init(color: Color.white.opacity(0.055), location: 1.00),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 0.9
                    )
            )
    }
}

struct SectionLabel: View {
    let text: String
    var trailing: String? = nil

    var body: some View {
        HStack(spacing: 4) {
            Text(text)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(DS.textSecondary)
                .tracking(0.3)
            Spacer(minLength: 4)
            if let trailing {
                Text(trailing)
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(DS.textTertiary)
            }
        }
    }
}

// MARK: - 小控件

/// 图标按钮，hover 有反馈
struct IconButton: View {
    let systemName: String
    var help: String = ""
    var tint: Color = DS.textSecondary
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(hovering ? DS.textPrimary : tint)
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(hovering ? DS.surfaceStrong : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// 带颜色的状态点。`pulsing` 为真时向外扩散一圈会消失的光环（视觉细节 A5）。
struct StatusDot: View {
    let color: Color
    var pulsing: Bool = false
    var size: CGFloat = 7

    @State private var ripple = false

    var body: some View {
        ZStack {
            if pulsing {
                Circle()
                    .stroke(color.opacity(0.5), lineWidth: 1.4)
                    .frame(width: size, height: size)
                    .scaleEffect(ripple ? 2.7 : 1.0)
                    .opacity(ripple ? 0 : 1)
            }
            Circle()
                .fill(color)
                .frame(width: size, height: size)
        }
        .frame(width: size, height: size)
        .animation(.easeOut(duration: 1.15).repeatForever(autoreverses: false), value: ripple)
        .onAppear { restart(pulsing) }
        .onChange(of: pulsing) { _, newValue in restart(newValue) }
    }

    /// repeatForever 需要一个 false → true 的跳变才会重新开始，
    /// 所以每次都要先复位再异步置位
    private func restart(_ on: Bool) {
        ripple = false
        guard on else { return }
        DispatchQueue.main.async { ripple = true }
    }
}

/// 横向构成条（命中 / 未命中 / 输出），带一条循环掠过的流光（视觉细节 B2）
struct CompositionBar: View {
    let breakdown: TokenBreakdown
    var height: CGFloat = 6
    var shimmer: Bool = true

    private var total: Double { Double(max(breakdown.totalTokens, 1)) }

    var body: some View {
        GeometryReader { geo in
            let spacing: CGFloat = 2
            let usable = max(0, geo.size.width - spacing * 2)
            ZStack(alignment: .leading) {
                HStack(spacing: spacing) {
                    segment(DS.hit, Double(breakdown.cacheHit) / total, usable)
                    segment(DS.miss, Double(breakdown.cacheMiss) / total, usable)
                    segment(DS.output, Double(breakdown.output) / total, usable)
                }
                .frame(width: geo.size.width, alignment: .leading)

                if shimmer {
                    ShimmerBand(width: geo.size.width, height: height)
                }
            }
        }
        .frame(height: height)
        .clipShape(Capsule())
        .background(Capsule().fill(Color.white.opacity(0.06)))
    }

    @ViewBuilder
    private func segment(_ color: Color, _ fraction: Double, _ width: CGFloat) -> some View {
        if fraction > 0 {
            RoundedRectangle(cornerRadius: height / 2, style: .continuous)
                .fill(color)
                .frame(width: max(1.5, width * fraction))
        }
    }
}

/// 反复从左扫到右的窄高光
private struct ShimmerBand: View {
    let width: CGFloat
    let height: CGFloat

    @State private var phase: CGFloat = -0.3

    var body: some View {
        LinearGradient(
            colors: [.clear, Color.white.opacity(0.38), .clear],
            startPoint: .leading,
            endPoint: .trailing
        )
        .frame(width: width * 0.30, height: height)
        .offset(x: phase * width)
        .blendMode(.plusLighter)
        .allowsHitTesting(false)
        .onAppear {
            withAnimation(.linear(duration: 3.2).repeatForever(autoreverses: false)) {
                phase = 1.15
            }
        }
    }
}

/// 图例
struct Legend: View {
    let color: Color
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 1.5).fill(color).frame(width: 7, height: 7)
            Text(title).font(.system(size: 10)).foregroundStyle(DS.textSecondary)
            Spacer(minLength: 2)
            Text(value)
                .font(.ds(10.5, .medium, rounded: true))
                .foregroundStyle(DS.textPrimary)
        }
    }
}

/// 胶囊按钮
struct PillButton: View {
    let title: String
    var tint: Color = DS.accent
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.95))
                .padding(.horizontal, 9)
                .padding(.vertical, 4.5)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(hovering ? tint.opacity(1.0) : tint.opacity(0.86))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// 空态 / 错误态提示
struct Notice: View {
    let icon: String
    let text: String
    var tint: Color = DS.textSecondary
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .padding(.top, 0.5)
            VStack(alignment: .leading, spacing: 5) {
                Text(text)
                    .font(.system(size: 10.5))
                    .foregroundStyle(DS.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(1.5)
                if let actionTitle, let action {
                    Button(actionTitle, action: action)
                        .buttonStyle(.plain)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(DS.accentSoft)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - 离屏渲染模式

/// `ImageRenderer` 无法光栅化 `ScrollView` 与 `NSViewRepresentable`，会画成 🚫 占位符。
/// 打开这个开关时视图改走等价的可渲染路径（普通 VStack / 不挂 AppKit 拖拽视图），
/// 以便在不需要「屏幕录制」权限的前提下验收真实排版。
private struct SnapshotModeKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var snapshotMode: Bool {
        get { self[SnapshotModeKey.self] }
        set { self[SnapshotModeKey.self] = newValue }
    }
}

// MARK: - 视图扩展

extension View {
    /// 报告自身高度，供 NSPanel 自适应
    func reportHeight(_ callback: @escaping (CGFloat) -> Void) -> some View {
        background(
            GeometryReader { geo in
                Color.clear.preference(key: HeightPreferenceKey.self, value: geo.size.height)
            }
        )
        .onPreferenceChange(HeightPreferenceKey.self) { callback($0) }
    }
}

struct HeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
