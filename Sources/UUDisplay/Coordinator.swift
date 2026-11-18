// 连入/断开 → 选设备配置 → 建屏/还原
// 只处理 UU 设备列表里、且填了分辨率的设备；读不到名字或认不出就不调整，交给 UU远程 自己处理
import AppKit

final class Coordinator {
    let monitor = UUMonitor()
    let display = DisplayManager()
    let modifierGuard = ModifierGuard()
    private let store = ConfigStore.shared

    /// 状态变化时通知菜单栏刷新
    var onChange: (() -> Void)?

    private(set) var controllerName: String?
    private var namePoll: Timer?
    private var connectedAt = Date.distantPast
    private var openedUUWindow = false
    /// 断开延迟拆除的令牌：期间重连则作废
    private var disconnectToken = 0

    /// 调试：模拟连入的控制端名称（不读 UU）
    var simulatedName: String?

    var connected: Bool { monitor.connected || simulatedName != nil }

    func start() {
        display.shouldDisablePhysical = { [weak self] in self?.physicalDisableAllowed ?? false }
        display.startObservingReconfig()
        display.recoverIfNeeded()
        monitor.onConnect = { [weak self] in self?.handleConnect() }
        monitor.onDisconnect = { [weak self] in self?.handleDisconnect() }
        monitor.start()

        // 修饰键守卫只在远程期间工作：本机自己用的时候不插手
        modifierGuard.isEnabled = { [weak self] in
            guard let self else { return false }
            return self.connected && self.store.config.shouldFixStuckModifiers
        }
        modifierGuard.start()

        // 上次异常退出留下的静音记录：先恢复，避免本机一直没声音
        if AudioControl.pending {
            Log.info("发现上次异常退出的静音记录，先恢复本机音频")
            AudioControl.restoreAfterRemote(reason: "启动时恢复")
        }
    }

    /// 开关打开且私有 API 可用时关闭物理屏；看门狗是可选兜底（快捷键 ⌃⌥⌘9 始终可用）
    var physicalDisableAllowed: Bool {
        store.config.shouldDisablePhysical && PhysicalDisplays.available
    }

    var statusText: String {
        if display.wedged { return "⛔️ 屏幕设置无响应，请重启 Mac" }
        if store.config.paused { return "虚拟屏已暂停：连接时不做调整" }
        guard connected else { return "等待其它设备连接中" }
        let who = controllerName ?? "未知设备"
        if let c = display.current, display.isActive {
            let audio = AudioControl.pending ? " · 本机已静音" : ""
            return "\(who) 已连接 · 虚拟屏已匹配 \(c.sizeLabel)\(display.physicalOff ? " · 物理屏幕已软关闭" : "")\(audio)"
        }
        return "\(who) 已连接 · 虚拟屏没有调整"
    }

    // MARK: - 事件

    func handleConnect() {
        connectedAt = Date()
        controllerName = nil
        openedUUWindow = false
        onChange?()
        // 远程开始：本机扬声器静音，声音只走控制端
        if store.config.shouldMuteLocally {
            AudioControl.muteForRemote()
        }
        guard !store.config.paused else { return }
        if pollName() { return }
        namePoll?.invalidate()
        namePoll = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] t in
            guard let self else { return t.invalidate() }
            if self.pollName() { t.invalidate() }
        }
    }

    func handleDisconnect() {
        namePoll?.invalidate()
        namePoll = nil
        controllerName = nil
        onChange?()
        // 远程结束：恢复本机音频
        AudioControl.restoreAfterRemote(reason: "远程结束")
        // 物理屏立刻点亮（本机要用），虚拟屏留 15 秒：
        // 快速重连视为同一次远程，避免拆建导致的模式回退与画面黑边
        display.park()
        let token = disconnectToken &+ 1
        disconnectToken = token
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self, self.disconnectToken == token, !self.connected else { return }
            self.display.remove()
            self.onChange?()
        }
    }

    /// 返回 true 表示已拿到名称、无需继续轮询
    private func pollName() -> Bool {
        guard connected, !store.config.paused else { return true }
        let elapsed = Date().timeIntervalSince(connectedAt)

        if let name = simulatedName ?? readControllerName() {
            resolve(name)
            return true
        }
        // 读不到名字（辅助功能未授权、UU 主窗口关着、别的 App 全屏）时按优先级兜底，
        // 否则用户会看到「虚拟屏不生成」
        if elapsed >= 2, let guess = guessedDevice() {
            Log.info("读不到控制端名称，按「\(guess.name)」准备虚拟屏（\(guess == singleConfiguredDevice() ? "唯一已配置设备" : "上次的控制端")）")
            controllerName = guess.name
            apply(guess)
            return true
        }
        if elapsed >= 30 {
            Log.info("30 秒内未读到控制端名称，停止等待")
            return true
        }
        return false
    }

    /// 唯一一台填了分辨率的平板/手机（电脑不算）
    private func singleConfiguredDevice() -> DeviceConfig? {
        let candidates = store.config.devices.filter { $0.kind != .computer && $0.hasSize }
        return candidates.count == 1 ? candidates[0] : nil
    }

    /// 读不到名字时的兜底设备：上次的控制端优先，其次唯一已配置的那台
    private func guessedDevice() -> DeviceConfig? {
        if let last = store.device(named: store.config.lastController),
           last.kind != .computer, last.hasSize { return last }
        return singleConfiguredDevice()
    }

    private func readControllerName() -> String? {
        guard UUReader.isTrusted else { return nil }
        switch UUReader.readControllers() {
        case .none:
            // 主窗口没开：打开一次 UU 主界面再读
            if !openedUUWindow {
                openedUUWindow = true
                Log.info("UU 主窗口未打开，尝试打开以读取控制端名称")
                UUReader.showMainWindow()
            }
            return nil
        case .some(let names):
            return names.first
        }
    }

    private func resolve(_ name: String) {
        controllerName = name
        Log.info("控制端：\(name)")
        if store.config.lastController != name { store.config.lastController = name }
        let cfg: DeviceConfig?
        if let known = store.device(named: name) {
            cfg = known
        } else if simulatedName != nil {
            // 调试模拟：未配置的名称用固定测试尺寸
            cfg = DeviceConfig(name: name, kind: .tablet, width: 2360, height: 1640)
        } else {
            cfg = nil
            Log.info("「\(name)」不在设备列表里，不调整")
        }
        apply(cfg)
    }

    private func apply(_ cfg: DeviceConfig?) {
        defer { onChange?() }
        guard let cfg, cfg.kind != .computer, cfg.hasSize else {
            if display.isActive { display.remove() }
            Log.info(cfg == nil ? "无可用配置，不切换" : "「\(cfg!.name)」不指定分辨率或还没填写，不切换")
            return
        }
        if display.matches(cfg) { return }
        display.create(cfg)
    }

    // MARK: - 菜单操作

    func setPaused(_ paused: Bool) {
        store.config.paused = paused
        if paused {
            namePoll?.invalidate()
            display.remove()
        } else if connected {
            handleConnect()
        }
        onChange?()
    }

    /// 配置变更后，若正在被控则按新配置重新应用
    func configChanged() {
        if connected, !store.config.paused {
            if let name = controllerName { resolve(name) } else { handleConnect() }
        }
        onChange?()
    }

    /// 快捷键 ⌃⌥⌘9 / 菜单：立即恢复物理屏
    func restorePhysical() {
        Log.info("手动恢复物理屏")
        display.restorePhysicalNow()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.onChange?() }
    }

    func setDisablePhysical(_ on: Bool) {
        store.config.disablePhysical = on
        if on { monitor.holdQuiet(for: 8) }
        if on { display.disablePhysicalIfNeeded() } else { display.restorePhysicalNow(override: false) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.onChange?() }
    }

    func shutdown(completion: @escaping () -> Void) {
        display.remove(completion: completion)
    }
}
