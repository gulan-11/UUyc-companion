// 合并三路在场信号：覆盖窗口（同步查）、控制端表格（后台 AX 读）、推流日志（子进程）。
// 任一路在即为连入；三路同时缺席超过防抖才算断开。
import CoreGraphics
import Foundation

final class UUMonitor {
    var onConnect: (() -> Void)?
    var onDisconnect: (() -> Void)?
    private(set) var connected = false

    private var timer: Timer?
    private var session = UUConnectionState()
    private let readerQueue = DispatchQueue(label: "uudisplay.controller-reader", qos: .utility)
    private var readInFlight = false
    private var controllers: [String]?
    private var controllersReadAt = Date.distantPast
    private let stream = CaptureLogWatcher()

    private let trusted: () -> Bool
    private let readControllers: () -> [String]?
    private let hasOverlay: () -> Bool
    /// UURemoteServer 持有「阻止显示器休眠」断言：与窗口、辅助功能权限都无关的第二路
    private let hasAssertion: () -> Bool

    init(trusted: @escaping () -> Bool = { UUReader.isTrusted },
         readControllers: @escaping () -> [String]? = { UUReader.readControllers() },
         hasOverlay: @escaping () -> Bool = { UUPresence.overlayPresent() },
         hasAssertion: @escaping () -> Bool = { UUPresence.servingAssertion() }) {
        self.trusted = trusted
        self.readControllers = readControllers
        self.hasOverlay = hasOverlay
        self.hasAssertion = hasAssertion
    }

    static func overlayPresent() -> Bool { UUPresence.overlayPresent() }

    func start() {
        stream.start()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
        tick()
    }

    func stop() { stream.stop(); timer?.invalidate(); timer = nil }

    /// 自己刚改过屏幕组合：让判定静默一段时间，别把 UU 的停流重开当成断开
    func holdQuiet(for seconds: TimeInterval) {
        session.holdQuiet(for: seconds)
    }

    private func tick() {
        // 每次 tick 都查覆盖窗口与推流；AX 卡顿不能阻塞这条路径
        let fresh = Date().timeIntervalSince(controllersReadAt) <= 1
        apply(controllers: fresh ? controllers : nil)
        // AX 调用可能阻塞；后台串行读取且不堆积任务
        guard !readInFlight, trusted() else {
            if !trusted() {
                controllers = nil
                controllersReadAt = .distantPast
            }
            return
        }
        readInFlight = true
        let started = Date()
        let read = readControllers
        readerQueue.async { [weak self] in
            let controllers = read()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.readInFlight = false
                // 不使用延迟过久的界面快照确认连接
                self.controllers = Date().timeIntervalSince(started) <= 2 ? controllers : nil
                self.controllersReadAt = Date()
                self.apply(controllers: self.controllers)
            }
        }
    }

    private func apply(controllers: [String]?) {
        // 覆盖窗口与推流断言都不是主线程重活，每次 tick 都查
        let present = hasOverlay() || hasAssertion()
        switch session.update(overlay: present, controllers: controllers, stream: stream.sample(), now: Date()) {
        case .connected:
            connected = true
            Log.info("检测到 UU 连入（覆盖窗口 / 推流断言 / 被控设备表格 / 推流日志）")
            onConnect?()
        case .controllerChanged:
            Log.info("检测到 UU 控制端变化")
            onConnect?()
        case .disconnected:
            connected = false
            Log.info("检测到 UU 断开（三路信号同时缺席）")
            onDisconnect?()
        case nil:
            break
        }
    }
}
