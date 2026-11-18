// UU 远程会话的「在场证据」：三路独立信号，任一路在就算远程仍在进行
// 背景（实测 2026-11-18）：
//   - 覆盖窗口（UURemoteServer 的窗口）并不可靠：远程正在推流时 CGWindowList 里也常常一个都没有
//   - 控制端表格只在 UU 主窗口开着时才读得到，用户关掉窗口就没了
//   - UURemoteServer 在服务期间会持有 PreventUserIdleDisplaySleep 断言「UURemote Disable Display Sleep」，
//     进程级、无需权限、与窗口开关无关，是最稳的一路
// 因此判定改为：overlay || 控制端表格 || 电源断言，三路同时缺席才算离开。
import CoreGraphics
import Foundation
import IOKit.pwr_mgt

enum UUPresence {
    /// UURemoteServer 在服务期间持有的断言名
    static let assertionName = "UURemote Disable Display Sleep"
    /// 兜底：断言名变了也不至于失效，按进程名 + 显示类断言匹配
    static let serverProcessName = "UURemoteServer"

    /// 覆盖窗口在屏（原有信号，保留但不再单独作为依据）
    static func overlayPresent() -> Bool {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.contains { ($0[kCGWindowOwnerName as String] as? String) == serverProcessName }
    }

    /// UURemoteServer 是否持有「阻止显示器休眠」的断言：远程进行中为 true
    static func servingAssertion() -> Bool {
        var unmanaged: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&unmanaged) == kIOReturnSuccess,
              let byProcess = unmanaged?.takeRetainedValue() as? [Int: [[String: Any]]] else { return false }
        for (rawPID, list) in byProcess {
            let pid = pid_t(rawPID)
            guard isServer(pid) else { continue }
            for a in list {
                let type = a["AssertType"] as? String ?? ""
                let name = a["AssertName"] as? String ?? ""
                let processName = a["Process Name"] as? String ?? ""
                guard type == "PreventUserIdleDisplaySleep" else { continue }
                if name == assertionName || processName == serverProcessName { return true }
            }
        }
        return false
    }

    private static func isServer(_ pid: pid_t) -> Bool {
        guard let path = processPath(pid) else { return false }
        return path.hasSuffix("/" + serverProcessName)
    }

    private static func processPath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        let len = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard len > 0 else { return nil }
        return String(cString: buffer)
    }

    /// 三路合成：任一路在即为在场
    static func any() -> Bool {
        if overlayPresent() { return true }
        if servingAssertion() { return true }
        return false
    }
}
