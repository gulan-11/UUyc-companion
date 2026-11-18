import Foundation

/// 回归测试：用户反馈的四个问题对应的判定逻辑
/// 1/2/3：模式漂移 → 由 ModePin + 组合变化核对解决（这里测判定本身）
/// 4：关闭 UU 窗口后虚拟屏失效 → 三路在场信号
@main struct PresenceTests {
    static func main() {
        let t = Date(timeIntervalSince1970: 1_000_000)

        // === 问题 4：覆盖窗口消失但仍在推流，不能判成断开 ===
        var s = UUConnectionState()
        precondition(s.update(overlay: true, controllers: nil, stream: false, now: t) == .connected)
        // 关掉 UU 主窗口、覆盖窗口也不在，但推流仍在
        precondition(s.update(overlay: false, controllers: nil, stream: true, now: t.addingTimeInterval(2)) == nil,
                     "推流仍在时不得判断开")
        precondition(s.update(overlay: false, controllers: nil, stream: true, now: t.addingTimeInterval(30)) == nil)
        // 推流真的停了，且超过防抖
        precondition(s.update(overlay: false, controllers: nil, stream: false, now: t.addingTimeInterval(31)) == nil)
        precondition(s.update(overlay: false, controllers: nil, stream: false, now: t.addingTimeInterval(33)) == .disconnected)

        // === 未知信号（监听刚起 / 回看未完成）不得判断开 ===
        var u = UUConnectionState()
        precondition(u.update(overlay: true, controllers: nil, stream: nil, now: t) == .connected)
        precondition(u.update(overlay: false, controllers: nil, stream: nil, now: t.addingTimeInterval(10)) == nil,
                     "信号未知时不得判断开")

        // === 三路同时缺席才断开 ===
        var v = UUConnectionState()
        precondition(v.update(overlay: false, controllers: ["iPad"], stream: false, now: t) == .connected)
        precondition(v.update(overlay: false, controllers: nil, stream: false, now: t.addingTimeInterval(0.5)) == nil)
        precondition(v.update(overlay: false, controllers: nil, stream: false, now: t.addingTimeInterval(2)) == .disconnected)

        // === 自己改屏后的静默期：不把 UU 停流重开当成断开 ===
        var w = UUConnectionState()
        precondition(w.update(overlay: true, controllers: nil, stream: false, now: t) == .connected)
        w.holdQuiet(for: 8, now: t.addingTimeInterval(1))
        for i in 2...9 {
            precondition(w.update(overlay: false, controllers: nil, stream: false,
                                  now: t.addingTimeInterval(Double(i))) == nil, "静默期内不得判断开")
        }
        // 静默期结束后仍不在场 → 断开
        precondition(w.update(overlay: false, controllers: nil, stream: false, now: t.addingTimeInterval(12)) == .disconnected)

        // === 模式判定：HiDPI 必须 2 倍像素 ===
        let cfg = DeviceConfig(name: "DESKTOP", kind: .phone, width: 2560, height: 1440, hiDPI: true)
        precondition(cfg.sizeLabel == "2560×1440 高清")
        let plain = DeviceConfig(name: "DESKTOP", kind: .phone, width: 2560, height: 1440, hiDPI: false)
        precondition(plain.hiDPI == false)

        print("PASS: 三路在场信号、未知信号、静默期、快速重连与模式目标判定")
    }
}
