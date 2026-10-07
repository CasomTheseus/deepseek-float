import AppKit
import Combine

/// 菜单栏项：实时显示余额，并提供显隐 / 刷新 / 设置 / 自启 / 退出。
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {

    private let statusItem: NSStatusItem
    private let model: AppModel
    private weak var panelController: FloatingPanelController?
    private var cancellables = Set<AnyCancellable>()
    private let menu = NSMenu()

    init(model: AppModel, panelController: FloatingPanelController) {
        self.model = model
        self.panelController = panelController
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = statusItem.button {
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .medium)
            button.image = NSImage(systemSymbolName: "water.waves", accessibilityDescription: "DeepSeek")
            button.imagePosition = .imageLeading
            button.image?.isTemplate = true
            button.toolTip = "DeepSeek 悬浮窗"
        }

        menu.delegate = self
        statusItem.menu = menu
        buildMenu()
        bind()
    }

    private func bind() {
        model.$balance
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateTitle() }
            .store(in: &cancellables)
        model.$balanceError
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateTitle() }
            .store(in: &cancellables)
        model.$isRefreshing
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateTitle() }
            .store(in: &cancellables)
        model.$alwaysOnTop
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.buildMenu() }
            .store(in: &cancellables)
        model.$launchAtLogin
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.buildMenu() }
            .store(in: &cancellables)
        updateTitle()
    }

    private func updateTitle() {
        guard let button = statusItem.button else { return }
        if let info = model.balance?.primary {
            let warn = model.statusLevel == .warning || model.statusLevel == .critical ? " ⚠︎" : ""
            button.title = Fmt.moneyCompact(info.total, currency: info.currency) + warn
        } else if model.balanceError != nil {
            button.title = " —"
        } else {
            button.title = " …"
        }
    }

    // MARK: - 菜单

    func menuNeedsUpdate(_ menu: NSMenu) { buildMenu() }

    private func buildMenu() {
        menu.removeAllItems()

        let headline: String
        if let info = model.balance?.primary {
            headline = "余额 \(Fmt.money(info.total, currency: info.currency))"
        } else if let error = model.balanceError {
            headline = "余额不可用：\(error)"
        } else {
            headline = "尚未读取余额"
        }
        menu.addItem(disabled(headline))

        if let usage = model.usage, !usage.totals.isEmpty {
            menu.addItem(disabled("\(usage.scopeNote) 命中率 \(Fmt.percent(usage.totals.cacheHitRate)) · \(Fmt.tokens(usage.totals.totalTokens)) tokens"))
        }
        if let when = model.lastRefresh {
            menu.addItem(disabled("更新于 " + Fmt.time.string(from: when)))
        }

        menu.addItem(.separator())

        menu.addItem(action("显示 / 隐藏悬浮窗", #selector(togglePanel), key: "h"))
        menu.addItem(action("立即刷新", #selector(refreshNow), key: "r"))
        menu.addItem(action("设置…", #selector(openSettings), key: ","))

        menu.addItem(.separator())

        let pin = action("窗口永远置顶", #selector(toggleAlwaysOnTop), key: "")
        pin.state = model.alwaysOnTop ? .on : .off
        menu.addItem(pin)

        let auto = action("开机自启", #selector(toggleLaunchAtLogin), key: "")
        auto.state = model.launchAtLogin ? .on : .off
        menu.addItem(auto)

        menu.addItem(.separator())

        // 测试入口：气泡只存在约 1.2 秒，等真实刷新很难观察到。
        // 这里可以随时手动触发一次，用来验收 A1/A2/A3。
        menu.addItem(action("模拟一次余额扣费（测试气泡）", #selector(simulateSpend), key: ""))
        menu.addItem(action("模拟一次充值（测试绿色气泡）", #selector(simulateTopUp), key: ""))

        menu.addItem(.separator())
        menu.addItem(action("退出 DeepSeek 悬浮窗", #selector(quit), key: "q"))
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func action(_ title: String, _ selector: Selector, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = self
        return item
    }

    // MARK: - 动作

    @objc private func togglePanel() { panelController?.toggle() }

    @objc private func refreshNow() {
        Task { await model.refresh(force: true) }
    }

    @objc private func openSettings() { panelController?.showSettings() }

    @objc private func toggleAlwaysOnTop() { model.alwaysOnTop.toggle() }

    @objc private func toggleLaunchAtLogin() { model.launchAtLogin.toggle() }

    @objc private func simulateSpend() {
        // 还没读到余额时先把真实刷新跑起来，否则没有基线可减
        if !model.simulateBalanceChange(-0.07) {
            Task { await model.refresh(force: true) }
        }
    }

    @objc private func simulateTopUp() {
        if !model.simulateBalanceChange(100) {
            Task { await model.refresh(force: true) }
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
