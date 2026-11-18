// 修饰键卡住的检测与修复（issue #17：Windows 远控 Mac 时偶发 Command 被按住）
//
// 现象：Windows 端通过 UU远程 控制 Mac 时，偶发 Command 收不回来，
//       点 Docker 图标弹出文件夹、菜单栏点不动，WPS 里更常见。
//
// 根因（实测 2026-11-18，macOS 27.3 / M5）：
//   修饰键的「按下」由 keyDown 建立、「松开」由 keyUp 清除。
//   远控链路里 keyUp 会丢（切窗口、网络抖动、控制端焦点变化），
//   UU 发了 keyDown 却没发 keyUp，HID 状态就永远停在按下。
//   实测：注入一个只有 keyDown 的 Command 后
//     CGEventSource.flagsState(.hidSystemState) 含 maskCommand，
//     CGEventSource.keyState(.hidSystemState, key: 0x37) 为 true，
//     而真实键盘的 HID 元素值为 0；
//   补发一个 keyUp 后两者都归零 —— 与用户描述的现象、修法都吻合。
//
// 判定原则：只信「真实键盘现在到底有没有按住」。
//   事件流说按着、但真实键盘没按 → 幽灵按键，连续 3 拍（0.6 秒）确认后补 keyUp。
//   真实按着 → 一律不干预。
import AppKit
import CoreGraphics
import Foundation
import IOKit.hid

final class ModifierGuard {
    private struct Modifier {
        let name: String
        let keyCode: CGKeyCode
        let flag: CGEventFlags
        /// HID 键盘 usage（0xE0–0xE7）
        let usage: UInt32
    }

    private static let modifiers: [Modifier] = [
        Modifier(name: "Command", keyCode: 0x37, flag: .maskCommand, usage: 0xE3),
        Modifier(name: "Command", keyCode: 0x36, flag: .maskCommand, usage: 0xE7),
        Modifier(name: "Option", keyCode: 0x3A, flag: .maskAlternate, usage: 0xE2),
        Modifier(name: "Option", keyCode: 0x3D, flag: .maskAlternate, usage: 0xE6),
        Modifier(name: "Control", keyCode: 0x3B, flag: .maskControl, usage: 0xE0),
        Modifier(name: "Control", keyCode: 0x3E, flag: .maskControl, usage: 0xE4),
        Modifier(name: "Shift", keyCode: 0x38, flag: .maskShift, usage: 0xE1),
        Modifier(name: "Shift", keyCode: 0x3C, flag: .maskShift, usage: 0xE5),
    ]

    /// 连续多少拍判定为幽灵按键才动手（0.2s × 3 = 0.6s）
    private static let strikesNeeded = 3

    private var timer: Timer?
    private var strikes: [CGKeyCode: Int] = [:]
    private var lastFixAt = Date.distantPast
    private(set) var fixCount = 0
    private(set) var lastFixedModifier: String?

    /// 只在远程期间启用
    var isEnabled: () -> Bool = { false }

    // MARK: - 生命周期

    func start() {
        guard timer == nil else { return }
        let t = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        strikes.removeAll()
    }

    // MARK: - 核对

    private func tick() {
        guard isEnabled() else {
            strikes.removeAll()
            return
        }
        let flags = CGEventSource.flagsState(.hidSystemState)
        for m in ModifierGuard.modifiers {
            let eventSaysDown = flags.contains(m.flag)
                || CGEventSource.keyState(.hidSystemState, key: m.keyCode)
            guard eventSaysDown else {
                strikes[m.keyCode] = 0
                continue
            }
            if ModifierGuard.realKeyDown(usage: m.usage) {
                strikes[m.keyCode] = 0        // 真实按住：不干预
                continue
            }
            let n = (strikes[m.keyCode] ?? 0) + 1
            strikes[m.keyCode] = n
            if n >= ModifierGuard.strikesNeeded {
                release(m)
                strikes[m.keyCode] = 0
            }
        }
    }

    /// 补发 keyUp，把卡住的修饰键状态清掉
    private func release(_ m: Modifier) {
        guard Date().timeIntervalSince(lastFixAt) > 1.0 else { return }   // 冷却，避免与真实按键打架
        lastFixAt = Date()
        fixCount += 1
        lastFixedModifier = m.name

        let src = CGEventSource(stateID: .hidSystemState)
        if let up = CGEvent(keyboardEventSource: src, virtualKey: m.keyCode, keyDown: false) {
            up.flags = []                  // 明确清掉修饰位
            up.post(tap: .cghidEventTap)
        }
        // 再补一个空的 flagsChanged，部分情况下只发 keyUp 不够
        if let flagsEvent = CGEvent(source: src) {
            flagsEvent.type = .flagsChanged
            flagsEvent.flags = []
            flagsEvent.post(tap: .cghidEventTap)
        }
        Log.info("⌨️ 检测到 \(m.name) 幽灵按下（真实键盘未按），已补发 keyUp 清除（第 \(fixCount) 次）")
    }

    // MARK: - 真实键盘状态（IOKit HID）

    private static let hidManager: IOHIDManager = {
        let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matches: [[String: Any]] = [
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_Keyboard],
        ]
        IOHIDManagerSetDeviceMatchingMultiple(m, matches as CFArray)
        IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeNone))
        return m
    }()

    /// 真实键盘上这个修饰键是否按着（按 HID usage 查）
    static func realKeyDown(usage: UInt32) -> Bool {
        guard let devices = IOHIDManagerCopyDevices(hidManager) as? Set<IOHIDDevice> else { return false }
        for device in devices {
            guard let elements = IOHIDDeviceCopyMatchingElements(device, nil, IOOptionBits(kIOHIDOptionsTypeNone)) as? [IOHIDElement] else {
                continue
            }
            for el in elements {
                guard IOHIDElementGetUsagePage(el) == UInt32(kHIDPage_KeyboardOrKeypad),
                      IOHIDElementGetUsage(el) == usage else { continue }
                let buffer = UnsafeMutablePointer<Unmanaged<IOHIDValue>>.allocate(capacity: 1)
                defer { buffer.deallocate() }
                guard IOHIDDeviceGetValue(device, el, buffer) == kIOReturnSuccess else { continue }
                if IOHIDValueGetIntegerValue(buffer.pointee.takeUnretainedValue()) != 0 { return true }
            }
        }
        return false
    }

    /// 当前是否有任何修饰键被事件流认为按着（供状态显示）
    static func stuckModifiers() -> [String] {
        let flags = CGEventSource.flagsState(.hidSystemState)
        var out: [String] = []
        if flags.contains(.maskCommand) { out.append("Command") }
        if flags.contains(.maskAlternate) { out.append("Option") }
        if flags.contains(.maskControl) { out.append("Control") }
        if flags.contains(.maskShift) { out.append("Shift") }
        return out
    }
}
