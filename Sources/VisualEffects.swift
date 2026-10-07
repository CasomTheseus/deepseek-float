import SwiftUI
import CoreGraphics

// MARK: - 噪点纹理（视觉细节 D1）

/// 极细的灰噪，叠在渐变背景上消除大面积渐变的"塑料感"。
/// 用固定种子的 LCG 生成，保证每次启动纹理一致（否则会闪）。
/// 纯代码生成，不引入任何图片资源。
enum NoiseTexture {

    static let image: Image = make()

    private static func make() -> Image {
        let side = 96
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        var seed: UInt32 = 0x9E37_79B9

        func nextByte() -> UInt8 {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return UInt8(truncatingIfNeeded: (seed >> 17) & 0xFF)
        }

        for index in 0..<(side * side) {
            let value = nextByte()
            // 中心化到 96…160，避免纯黑白噪点过冲
            let centered = UInt8(96 + Int(value) / 3)
            pixels[index * 4 + 0] = centered
            pixels[index * 4 + 1] = centered
            pixels[index * 4 + 2] = centered
            pixels[index * 4 + 3] = 255
        }

        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let cgImage = CGImage(
                width: side,
                height: side,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: side * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: bitmapInfo,
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              )
        else {
            return Image(systemName: "circle")
        }
        return Image(decorative: cgImage, scale: 2)
    }
}

/// 铺满可用空间的噪点层
struct NoiseOverlay: View {
    var opacity: Double = 0.032

    var body: some View {
        NoiseTexture.image
            .resizable(resizingMode: .tile)
            .opacity(opacity)
            .blendMode(.overlay)
            .allowsHitTesting(false)
    }
}

// MARK: - 同步成功对勾（视觉细节 F3）

/// 保存/同步成功时弹出的一枚对勾，弹簧入场、短暂停留后淡出。
struct SuccessCheck: View {
    var appeared: Bool

    var body: some View {
        Image(systemName: "checkmark.circle.fill")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(DS.hit)
            .symbolEffect(.bounce, value: appeared)
            .scaleEffect(appeared ? 1 : 0.4)
            .opacity(appeared ? 1 : 0)
            .animation(.spring(response: 0.34, dampingFraction: 0.58), value: appeared)
    }
}

// MARK: - 余额增减气泡（视觉细节 A1）

/// 一次余额变动的记录，供 UI 弹出 `-¥0.05` 这类气泡。
struct BalanceDelta: Identifiable, Equatable {
    let id = UUID()
    let amount: Double
    let currency: String

    var isSpend: Bool { amount < 0 }

    var symbol: String { currency.uppercased() == "USD" ? "$" : "¥" }

    /// 显示文本用真正的减号 U+2212，视觉上比连字符更居中、更像"扣钱"
    var text: String {
        let sign = amount < 0 ? "−" : "+"
        return sign + symbol + String(format: "%.2f", abs(amount))
    }

    /// 纯函数：给上次与本次余额，判断该不该弹、弹多少。
    /// 首次（`previous == nil`）只建立基线不弹，否则会把"全部余额"当成一次变化。
    /// 抽成纯函数是为了能被断言覆盖 —— 这段判断错了就会满屏乱弹或永远不弹。
    ///
    /// 金额先归整到「分」再比较：余额接口返回的是两位小数字符串，
    /// 但转成 Double 后会有表示误差（例如 `100 - 99.995` 实际是 0.00499999…），
    /// 直接和阈值比会让边界行为不可预期。
    static func change(
        previous: Double?,
        current: Double,
        currency: String,
        threshold: Double = 0.005
    ) -> BalanceDelta? {
        guard let previous else { return nil }
        let diff = ((current - previous) * 100).rounded() / 100
        guard abs(diff) >= threshold else { return nil }
        return BalanceDelta(amount: diff, currency: currency)
    }
}

/// 从余额右上角飘出的增减量气泡。
/// 三段关键帧：快速弹入 → 上浮 → 淡出，累计约 1.2s。
struct DeltaBubble: View {
    let delta: BalanceDelta

    @Environment(\.snapshotMode) private var snapshotMode

    /// `KeyframeAnimator(initialValue:trigger:)` 只在 **trigger 发生变化** 时播放关键帧。
    /// 每枚气泡都是一个全新的视图标识，`delta.id` 在它的一生中始终是同一个值，
    /// 于是动画永远不会开始，视图就停在 `initialValue`（opacity 0）——
    /// 肉眼看就是"气泡没显示"。所以这里用一个 onAppear 才翻转的布尔量真正驱动它。
    @State private var fired = false

    private struct Motion {
        var y: CGFloat = 0
        var opacity: Double = 0
        var scale: CGFloat = 0.72
    }

    private var tint: Color { delta.isSpend ? DS.spend : DS.gain }

    var body: some View {
        if snapshotMode {
            // 离屏渲染只有单帧，这里固定到动画中段，好验收配色与排版。
            // 注意：这只验证样式，验证不了动画本身 —— 动画要靠 LiveCapture 抓中间帧。
            bubble(y: -13, opacity: 1, scale: 1)
        } else {
            KeyframeAnimator(initialValue: Motion(), trigger: fired) { motion in
                bubble(y: motion.y, opacity: motion.opacity, scale: motion.scale)
            } keyframes: { _ in
                KeyframeTrack(\.y) {
                    LinearKeyframe(0, duration: 0.001)
                    CubicKeyframe(-11, duration: 0.30)
                    LinearKeyframe(-26, duration: 0.78)
                }
                KeyframeTrack(\.opacity) {
                    LinearKeyframe(0, duration: 0.001)
                    LinearKeyframe(1, duration: 0.10)
                    LinearKeyframe(1, duration: 0.58)
                    LinearKeyframe(0, duration: 0.40)
                }
                KeyframeTrack(\.scale) {
                    LinearKeyframe(0.72, duration: 0.001)
                    CubicKeyframe(1.08, duration: 0.18)
                    CubicKeyframe(1.0, duration: 0.16)
                }
            }
            .onAppear { fired = true }
        }
    }

    private func bubble(y: CGFloat, opacity: Double, scale: CGFloat) -> some View {
        Text(delta.text)
            .font(.ds(11, .semibold, rounded: true))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2.5)
            .background(Capsule().fill(tint.opacity(0.16)))
            .overlay(Capsule().stroke(tint.opacity(0.30), lineWidth: 0.5))
            .shadow(color: tint.opacity(0.35), radius: 6, y: 1)
            .scaleEffect(scale)
            .opacity(opacity)
            .offset(y: y)
            .fixedSize()
    }
}
