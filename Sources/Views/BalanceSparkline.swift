import SwiftUI

/// 余额走势迷你曲线，末端一个呼吸光点（视觉细节 C3）。
///
/// 只在有两个以上采样时才有意义；一个点时退化成一个静止的点，
/// 由调用方决定要不要显示整块。
struct BalanceSparkline: View {
    let samples: [BalanceSample]
    var height: CGFloat = 28
    var tint: Color = DS.accent

    private var points: [CGPoint] { BalanceTrend.points(samples, in: size) }

    @State private var size: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            let points = BalanceTrend.points(samples, in: geo.size)
            ZStack(alignment: .topLeading) {
                if points.count >= 2 {
                    areaPath(points, in: geo.size)
                        .fill(LinearGradient(
                            colors: [tint.opacity(0.26), tint.opacity(0.02)],
                            startPoint: .top, endPoint: .bottom
                        ))

                    smoothPath(points)
                        .stroke(
                            LinearGradient(colors: [tint.opacity(0.55), tint],
                                           startPoint: .leading, endPoint: .trailing),
                            style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round)
                        )

                    if let last = points.last { endDot().position(last) }
                } else if let only = points.first {
                    // 只有一个采样：画一条基准线加一个点，表示"正在积累"
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: only.y))
                        path.addLine(to: CGPoint(x: geo.size.width, y: only.y))
                    }
                    .stroke(tint.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

                    endDot().position(only)
                }
            }
        }
        .frame(height: height)
        .onGeometryChangeSize(into: $size)
    }

    /// 末端光点 + 一圈扩散的呼吸环。
    /// 用 `phaseAnimator` 而不是 `withAnimation(.repeatForever)`：
    /// 前者每帧改的是 SwiftUI 状态，抓帧能看见；后者走 Core Animation，抓帧拍不到。
    private func endDot() -> some View {
        ZStack {
            Circle()
                .stroke(tint.opacity(0.55), lineWidth: 1)
                .frame(width: 7, height: 7)
                .phaseAnimator([false, true]) { ring, phase in
                    ring
                        .scaleEffect(phase ? 2.4 : 1)
                        .opacity(phase ? 0 : 0.9)
                } animation: { _ in .easeOut(duration: 1.8) }

            Circle()
                .fill(Color.white)
                .frame(width: 3.6, height: 3.6)
                .shadow(color: tint.opacity(0.9), radius: 3)
        }
    }

    // MARK: - 路径

    /// Catmull-Rom 转三次贝塞尔，避免折线的棱角
    private func smoothPath(_ points: [CGPoint]) -> Path {
        var path = Path()
        guard points.count > 1 else { return path }
        path.move(to: points[0])
        for index in 0..<(points.count - 1) {
            let p0 = points[max(index - 1, 0)]
            let p1 = points[index]
            let p2 = points[index + 1]
            let p3 = points[min(index + 2, points.count - 1)]
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            path.addCurve(to: p2, control1: c1, control2: c2)
        }
        return path
    }

    /// 曲线下方到画布底部的填充区
    private func areaPath(_ points: [CGPoint], in size: CGSize) -> Path {
        var path = smoothPath(points)
        guard let last = points.last, let first = points.first else { return path }
        path.addLine(to: CGPoint(x: last.x, y: size.height))
        path.addLine(to: CGPoint(x: first.x, y: size.height))
        path.closeSubpath()
        return path
    }
}

private extension View {
    /// 记录自身尺寸，便于在外部按尺寸算点
    func onGeometryChangeSize(into binding: Binding<CGSize>) -> some View {
        background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { binding.wrappedValue = proxy.size }
                    .onChange(of: proxy.size) { _, newValue in binding.wrappedValue = newValue }
            }
        )
    }
}
