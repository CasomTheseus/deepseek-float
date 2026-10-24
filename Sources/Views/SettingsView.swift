import SwiftUI
import AppKit

/// 设置页。窄窗里的单列表单，按「凭据 → 用量 → 外观 → 提醒」分组。
struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.snapshotMode) private var snapshotMode

    @State private var keyDraft = ""
    @State private var tokenDraft = ""
    @State private var revealKey = false
    @State private var revealToken = false
    @State private var toast: String?
    @State private var successFlash = false

    var body: some View {
        VStack(spacing: 0) {
            header
            if snapshotMode {
                sections
            } else {
                ScrollView(.vertical, showsIndicators: false) { sections }
            }
        }
    }

    private var sections: some View {
        VStack(alignment: .leading, spacing: 9) {
            credentialSection
            tokenSection
            appearanceSection
            alertSection
            aboutSection
        }
        .padding(.horizontal, 11)
        .padding(.bottom, 12)
    }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: 6) {
            IconButton(systemName: "chevron.left", help: "返回") {
                model.showSettings = false
            }
            Text("设置")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(DS.textPrimary)
            Spacer()
            if let toast {
                Text(toast)
                    .font(.system(size: 9.5))
                    .foregroundStyle(DS.textTertiary)
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
            // F3：成功时弹出一枚对勾，而不是只留一行容易被忽略的文字
            SuccessCheck(appeared: successFlash)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.03))
    }

    // MARK: - 凭据

    private var credentialSection: some View {
        Card {
            VStack(alignment: .leading, spacing: 7) {
                SectionLabel(text: "① API KEY（查余额，官方接口）", trailing: model.hasAPIKey ? "已保存" : nil)

                HStack(spacing: 5) {
                    secretField(
                        placeholder: "sk-…",
                        text: $keyDraft,
                        revealed: $revealKey
                    )
                }

                HStack(spacing: 6) {
                    pillButton("保存并测试", tint: DS.accent) {
                        model.saveAPIKey(keyDraft)
                        keyDraft = ""
                        flash("已保存，正在测试")
                    }
                    if model.dshAvailable {
                        pillButton("从 DSH 导入", tint: Color.white.opacity(0.14)) {
                            if model.importKeyFromDSH() {
                                keyDraft = ""
                                flash("已从本机 DSH 导入")
                            } else {
                                flash("未在 DSH 凭据里找到 Key", success: false)
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }

                if model.hasAPIKey {
                    HStack(spacing: 6) {
                        Text("当前：\(model.maskedAPIKey)")
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(DS.textTertiary)
                        Spacer(minLength: 0)
                        Button("清除") { model.clearCredentials(); flash("已清除") }
                            .buttonStyle(.plain)
                            .font(.system(size: 9.5))
                            .foregroundStyle(DS.miss)
                    }
                } else {
                    Text("余额接口是官方公开接口，只需要 sk- 开头的 API Key。")
                        .font(.system(size: 9.5))
                        .foregroundStyle(DS.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - 平台令牌

    private var tokenSection: some View {
        Card {
            VStack(alignment: .leading, spacing: 9) {
                SectionLabel(text: "② 用量来源", trailing: model.usageSource.title)

                // 来源必须显式可选：两条通路的口径完全不同，
                // 平台令牌是账户全量、官方账单；本地日志只有本机 DSH 的请求。
                // 混着显示会让人把两套数字当成一套。
                Picker("", selection: $model.usageSource) {
                    ForEach(UsageSource.allCases) { source in
                        Text(source.title).tag(source)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Text(model.usageSource.caption)
                    .font(.system(size: 9))
                    .foregroundStyle(DS.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                switch model.usageSource {
                case .localLog:
                    Text("读取本机 ~/.dsh/sessions 下的 DSH 会话日志，只统计这台机器用当前 Key 发出的请求。不需要平台令牌，也不会上传任何东西。\n注意：日志只有 token 数、没有金额；同一把 Key 在别处（手机、其他客户端）的调用不计入。\n依赖 zstd 命令行解压（brew install zstd）。")
                        .font(.system(size: 9))
                        .foregroundStyle(DS.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineSpacing(1.5)
                        .textSelection(.enabled)

                case .platform:
                    secretField(placeholder: "粘贴 userToken", text: $tokenDraft, revealed: $revealToken)

                    HStack(spacing: 6) {
                        pillButton("保存并同步", tint: DS.accent) {
                            model.saveUserToken(tokenDraft)
                            tokenDraft = ""
                            flash("已保存，正在同步")
                        }
                        pillButton("怎么获取？", tint: Color.white.opacity(0.14)) {
                            openUsagePage()
                        }
                        Spacer(minLength: 0)
                    }

                    Text("用法：浏览器登录平台用量页 → F12 控制台执行\nJSON.parse(localStorage.getItem('userToken')).value\n把结果粘到上面。它是网页登录态令牌，不是 sk- Key。")
                        .font(.system(size: 9))
                        .foregroundStyle(DS.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineSpacing(1.5)
                        .textSelection(.enabled)

                case .none:
                    Text("不显示用量，只保留余额。")
                        .font(.system(size: 9))
                        .foregroundStyle(DS.textTertiary)
                }
            }
        }
    }

    // MARK: - 外观

    private var appearanceSection: some View {
        Card {
            VStack(alignment: .leading, spacing: 9) {
                SectionLabel(text: "外观与刷新")

                Picker("刷新间隔", selection: $model.refreshInterval) {
                    Text("15 秒").tag(15.0)
                    Text("30 秒").tag(30.0)
                    Text("1 分钟").tag(60.0)
                    Text("5 分钟").tag(300.0)
                }
                .pickerStyle(.menu)
                .font(.system(size: 10.5))

                HStack(spacing: 6) {
                    Text("背景浓度").font(.system(size: 10.5)).foregroundStyle(DS.textSecondary)
                    Slider(value: $model.opacity, in: 0.35...1.0)
                        .controlSize(.mini)
                    Text(Fmt.percent(model.opacity))
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(DS.textTertiary)
                        .frame(width: 34, alignment: .trailing)
                }

                toggleRow("闲置后淡出", isOn: $model.fadeWhenIdle)

                if model.fadeWhenIdle {
                    Picker("闲置判定", selection: $model.idleFadeDelay) {
                        Text("5 秒").tag(5.0)
                        Text("10 秒").tag(10.0)
                        Text("30 秒").tag(30.0)
                        Text("1 分钟").tag(60.0)
                    }
                    .pickerStyle(.menu)
                    .font(.system(size: 10.5))

                    HStack(spacing: 6) {
                        Text("淡出透明度").font(.system(size: 10.5)).foregroundStyle(DS.textSecondary)
                        Slider(value: $model.idleOpacity, in: 0.08...0.6)
                            .controlSize(.mini)
                        Text(Fmt.percent(model.idleOpacity))
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(DS.textTertiary)
                            .frame(width: 34, alignment: .trailing)
                    }

                    Text("淡出后鼠标可以点穿到下面的窗口。指针移回面板会自动恢复，"
                         + "所以不看它的时候不占地方，要看的时候也点得到。\n"
                         + "设置页打开或低余额告警期间不会淡出。")
                        .font(.system(size: 8.5))
                        .foregroundStyle(DS.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineSpacing(1.5)
                }

                toggleRow("窗口永远置顶", isOn: $model.alwaysOnTop)
                toggleRow("面板隐藏时降到 5 分钟", isOn: $model.hideWhenIdle)
                toggleRow("显示分模型明细", isOn: $model.showModels)
                toggleRow("开机自启", isOn: $model.launchAtLogin)
            }
        }
    }

    // MARK: - 提醒

    private var alertSection: some View {
        Card {
            VStack(alignment: .leading, spacing: 9) {
                SectionLabel(text: "余额提醒")
                toggleRow("余额过低时发系统通知", isOn: $model.notificationsEnabled)
                    .onChange(of: model.notificationsEnabled) { _, enabled in
                        if enabled { model.refreshNotificationStatus() }
                    }
                if model.notificationsEnabled {
                    HStack(spacing: 5) {
                        Text("通知权限：")
                            .font(.system(size: 9))
                            .foregroundStyle(DS.textTertiary)
                        Text(model.notificationStatus)
                            .font(.system(size: 9))
                            .foregroundStyle(model.notificationStatus == "已授权" ? DS.hit : DS.miss)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        Spacer(minLength: 2)
                        // 通知是静默失败重灾区：没权限时既不报错也不弹。
                        // 给一个「我现在就要看到一条」的入口，比任何状态文字都管用。
                        pillButton("发送测试", tint: Color.white.opacity(0.16)) {
                            Notifier.postTest(threshold: model.lowBalanceThreshold)
                            model.refreshNotificationStatus()
                            flash("已发送测试通知，看有没有横幅", success: false)
                        }
                    }
                }
                HStack(spacing: 6) {
                    Text("提醒阈值").font(.system(size: 10.5)).foregroundStyle(DS.textSecondary)
                    Spacer()
                    TextField("", value: $model.lowBalanceThreshold, format: .number)
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.trailing)
                        .font(.system(size: 10.5, design: .monospaced))
                        .frame(width: 52)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.07)))
                    Text("元").font(.system(size: 10)).foregroundStyle(DS.textTertiary)
                }
            }
        }
    }

    // MARK: - 关于

    private var aboutSection: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel(text: "关于")
                Text("数据只发往 api.deepseek.com 与 platform.deepseek.com。")
                    .font(.system(size: 9.5))
                    .foregroundStyle(DS.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("凭据保存在本机 ~/Library/Application Support/DeepSeekFloat/credentials.json（权限 600），不做任何上传。")
                    .font(.system(size: 9.5))
                    .foregroundStyle(DS.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button("打开用量页") { openUsagePage() }
                    Button("退出 App") { NSApp.terminate(nil) }
                }
                .buttonStyle(.plain)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(DS.accentSoft)
                .padding(.top, 1)
            }
        }
    }

    // MARK: - 组件

    private func secretField(placeholder: String, text: Binding<String>, revealed: Binding<Bool>) -> some View {
        HStack(spacing: 4) {
            Group {
                if revealed.wrappedValue {
                    TextField(placeholder, text: text)
                } else {
                    SecureField(placeholder, text: text)
                }
            }
            .textFieldStyle(.plain)
            .font(.system(size: 10.5, design: .monospaced))
            .disableAutocorrection(true)

            Button {
                revealed.wrappedValue.toggle()
            } label: {
                Image(systemName: revealed.wrappedValue ? "eye.slash" : "eye")
                    .font(.system(size: 9.5))
                    .foregroundStyle(DS.textTertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(0.07))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(DS.stroke, lineWidth: 0.5)
        )
    }

    private func pillButton(_ title: String, tint: Color, action: @escaping () -> Void) -> some View {
        PillButton(title: title, tint: tint, action: action)
    }

    private func toggleRow(_ title: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(title).font(.system(size: 10.5)).foregroundStyle(DS.textSecondary)
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
        }
    }

    // MARK: - 动作

    private func flash(_ message: String, success: Bool = true) {
        if success {
            withAnimation(.spring(response: 0.34, dampingFraction: 0.58)) { successFlash = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                withAnimation(.easeOut(duration: 0.35)) { successFlash = false }
            }
        } else {
            // 失败/中性提示仍然用文字，因为需要说清楚原因
            withAnimation(.easeOut(duration: 0.2)) { toast = message }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) {
                withAnimation(.easeOut(duration: 0.3)) { toast = nil }
            }
        }
    }

    private func openUsagePage() {
        if let url = URL(string: "https://platform.deepseek.com/usage") {
            NSWorkspace.shared.open(url)
        }
    }
}
