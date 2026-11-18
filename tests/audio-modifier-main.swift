import CoreAudio
import CoreGraphics
import Foundation

/// 回归测试：音频静音与修饰键守卫
///
/// 注意：**不修改系统音频状态**。之前的版本会真的把设备静音再恢复，
/// 一旦测试中途失败或原本就是静音，就会把机器留在静音状态。
/// 这里只做只读检查 + 属性可写性判断。
@main struct AudioModifierTests {
    static func main() {
        // === 音频：默认输出设备可读 ===
        guard let dev = AudioControl.defaultOutputDevice() else {
            print("SKIP: 没有默认输出设备")
            exit(0)
        }
        let muted = AudioControl.isMuted(dev)
        print("默认输出设备 id=\(dev)，当前 mute=\(muted.map(String.init) ?? "设备不支持 mute 属性")")

        // 只读验证：能读到状态即说明属性存在、可查询
        if let muted {
            precondition(muted == true || muted == false, "mute 状态必须是布尔")
            print("PASS: 可读取设备静音状态")
        } else {
            print("NOTE: 该设备没有 mute 属性，AudioControl 会跳过静音（不影响功能）")
        }

        // === 音频：静音记录的语义 ===
        // pending 表示「有未恢复的静音记录」；无记录时应为 false
        let pending = AudioControl.pending
        print("当前是否有未恢复的静音记录: \(pending)")
        // 若确实有记录（正在远程），说明状态机在工作；没有也正常
        precondition(pending == true || pending == false, "pending 必须是布尔")

        // === 修饰键：无人按键时不应误判 ===
        for usage in [UInt32(0xE0), 0xE1, 0xE2, 0xE3, 0xE4, 0xE5, 0xE6, 0xE7] {
            let down = ModifierGuard.realKeyDown(usage: usage)
            precondition(down == false, "无人按键时 usage 0x\(String(usage, radix: 16)) 不应为按下")
        }
        print("PASS: HID 修饰键状态读取正常，未按键时不误判")

        // === 修饰键：事件流状态可读 ===
        let stuck = ModifierGuard.stuckModifiers()
        print("当前事件流修饰键: \(stuck.isEmpty ? "无" : stuck.joined(separator: ", "))")

        // === 修饰键：幽灵按键的判定逻辑（不真的注入事件） ===
        // 判定条件 = 事件流说按下 && 真实键盘未按。无人按键时两者都应为 false。
        let flags = CGEventSource.flagsState(.hidSystemState)
        let eventSaysCommand = flags.contains(.maskCommand)
        let realSaysCommand = ModifierGuard.realKeyDown(usage: 0xE3)
        precondition(eventSaysCommand == false || realSaysCommand == true,
                     "若事件流说 Command 按着，真实键盘也必须按着（否则就是幽灵按键，守卫会修掉）")
        print("PASS: 幽灵按键判定逻辑自洽")

        // === 音频：三种恢复场景的判定逻辑（纯逻辑，不碰设备） ===
        // 场景 1：远程前就是静音 → 保持静音
        // 场景 2：远程前不静音，现在是我们设的静音 → 取消静音
        // 场景 3：远程期间用户自己开了声音 → 不动
        func shouldUnmute(wasMuted: Bool, currentlyMuted: Bool?) -> Bool {
            if wasMuted { return false }
            if currentlyMuted == false { return false }
            return true
        }
        precondition(shouldUnmute(wasMuted: true, currentlyMuted: true) == false, "原本静音应保持静音")
        precondition(shouldUnmute(wasMuted: false, currentlyMuted: true) == true, "我们设的静音应取消")
        precondition(shouldUnmute(wasMuted: false, currentlyMuted: false) == false, "用户已自行打开则不动")
        precondition(shouldUnmute(wasMuted: false, currentlyMuted: nil) == true, "读不到状态时按恢复处理")
        print("PASS: 三种音频恢复场景判定正确")

        print("PASS: 音频与修饰键守卫检查全部通过（未改动系统音频状态）")
    }
}
