import Foundation

/// 合并三路信号（覆盖窗口 / 控制端表格 / 推流）判断远程是否在场，并保留切屏期间的断开防抖。
///
/// 变更背景（本机 2026-11-18 实测）：
///   1. 覆盖窗口不可靠——远程正在推流时，CGWindowList 里也常常一个 UURemoteServer 窗口都没有；
///      原实现只靠它，于是「关闭 UU 远程的窗口后虚拟屏就失效」（用户反馈第 4 条）与
///      「断开后马上又连入」的抖动都出在这里。
///   2. 控制端表格依赖 UU 主窗口开着，关窗口就没了。
///   3. 因此新增第三路：UURemoteServer 的推流日志（ScreenCaptureKit），与窗口无关。
/// 判定原则：任一路在场即视为在场；三路同时缺席超过 debounce 才算断开。
/// 推流信号「未知」（监听刚起、回看未完成、子进程重启中）时不下断开结论，只有持续未知超过
/// unknownLimit 才降级为「不在场」，避免监听挂掉后再也判不出断开。
struct UUConnectionState {
    enum Event: Equatable { case connected, controllerChanged, disconnected }
    private(set) var connected = false
    private var lastSeen = Date.distantPast
    private var controller: String?
    private let debounce: TimeInterval = 1.5
    /// 推流信号为真时记下时间；未知时用它兜住短暂的监听空窗
    private var lastStreamSeen = Date.distantPast
    /// 推流信号连续未知的起点
    private var unknownSince: Date?
    /// 未知持续这么久就当作不在场（监听进程真的挂了）
    private let unknownLimit: TimeInterval = 120
    /// 自己刚改过屏幕组合后的静默期：期间不判断开（改屏会让 UU 停流重开）
    private var quietUntil = Date.distantPast
    private(set) var lastDisconnectAt = Date.distantPast

    /// 三路信号合成。stream == nil 表示「未知」（监听刚起、回看未完成）。
    /// streamReliable == false：调用方没有推流这一路（只有两路信号），nil 按「不在场」处理。
    mutating func update(overlay: Bool, controllers: [String]?, stream: Bool?, now: Date,
                         streamReliable: Bool = true) -> Event? {
        let name = controllers?.first

        // 推流这一路：真 / 假 / 未知
        let streamPresent: Bool
        switch stream {
        case .some(true):
            lastStreamSeen = now
            unknownSince = nil
            streamPresent = true
        case .some(false):
            unknownSince = nil
            streamPresent = false
        case .none:
            if !streamReliable {
                streamPresent = false
            } else {
                if unknownSince == nil { unknownSince = now }
                let stuck = now.timeIntervalSince(unknownSince ?? now) > unknownLimit
                streamPresent = !stuck && now.timeIntervalSince(lastStreamSeen) <= 8
            }
        }

        let present = overlay || name != nil || streamPresent
        let streamUnknown = streamReliable && (stream == nil)
            && (now.timeIntervalSince(unknownSince ?? now) <= unknownLimit)

        if present {
            lastSeen = now
            if !connected {
                connected = true
                controller = name
                return .connected
            }
            if let name, name != controller {
                controller = name
                return .controllerChanged
            }
        } else if connected, !streamUnknown, now > quietUntil, now.timeIntervalSince(lastSeen) > debounce {
            connected = false
            controller = nil
            lastDisconnectAt = now
            return .disconnected
        }
        return nil
    }

    /// 兼容旧签名（只有两路信号）
    mutating func update(overlay: Bool, controllers: [String]?, now: Date) -> Event? {
        update(overlay: overlay, controllers: controllers, stream: nil, now: now, streamReliable: false)
    }

    /// 自己动过屏幕组合：给一段静默期，避免把 UU 的重连当成断开
    mutating func holdQuiet(for seconds: TimeInterval, now: Date = Date()) {
        quietUntil = now.addingTimeInterval(seconds)
        lastSeen = now
    }

    /// 刚断开多久（用于「快速重连视为同一次远程」）
    func secondsSinceDisconnect(now: Date = Date()) -> TimeInterval {
        now.timeIntervalSince(lastDisconnectAt)
    }
}
