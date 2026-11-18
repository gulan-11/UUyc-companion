// 远程期间禁用物理屏（CGSConfigureDisplayEnabled 私有 API）及其兜底恢复
// 实测（macOS 27）：
//   - 禁用不受 .forAppOnly 约束，进程退出后不会自动恢复，必须由别的进程重新启用
//   - 被禁用的屏会从 CGGetOnlineDisplayList 中消失，所以禁用前必须先把 ID 写盘
//   - 物理屏全禁用且虚拟屏也移除时，系统会生成一块 1920×1080 占位屏；按 ID 重新启用即可恢复
import CoreGraphics
import Foundation

/// 同步执行一次显示器配置事务。GUI 进程中不可在主线程调用（会与自身重配置通知死锁）
@discardableResult
func applyDisplayConfig(_ body: (CGDisplayConfigRef?) -> Void) -> CGError {
    var cfg: CGDisplayConfigRef?
    guard CGBeginDisplayConfiguration(&cfg) == .success else { return .failure }
    body(cfg)
    let err = CGCompleteDisplayConfiguration(cfg, .forSession)
    if err != .success { CGCancelDisplayConfiguration(cfg) }
    return err
}

enum PhysicalDisplays {
    private typealias EnableFn = @convention(c) (CGDisplayConfigRef?, CGDirectDisplayID, Bool) -> CGError
    private static let setEnabled: EnableFn? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGSConfigureDisplayEnabled")
        .map { unsafeBitCast($0, to: EnableFn.self) }

    static var available: Bool { setEnabled != nil }

    /// 已被禁用、待恢复的物理屏记录
    static let markerURL = ConfigStore.dir.appendingPathComponent("disabled-displays.json")

    static var pending: [CGDirectDisplayID]? {
        guard let data = try? Data(contentsOf: markerURL),
              let ids = try? JSONDecoder().decode([CGDirectDisplayID].self, from: data), !ids.isEmpty else { return nil }
        return ids
    }

    /// 先记账再禁用。须在后台队列调用
    static func disable(_ ids: [CGDirectDisplayID]) -> CGError {
        guard let setEnabled, !ids.isEmpty else { return .failure }
        let merged = Array(Set((pending ?? []) + ids))
        guard (try? JSONEncoder().encode(merged).write(to: markerURL, options: .atomic)) != nil else {
            Log.info("❌ 无法写入物理屏记录，放弃禁用")
            return .failure
        }
        return applyDisplayConfig { cfg in ids.forEach { _ = setEnabled(cfg, $0, false) } }
    }

    /// 按记录重新启用物理屏；成功后删除记录。可在任意进程调用，重复调用无害
    ///
    /// 2026-11-18 修复（对应上游 issue #19 / PR #12）：
    ///   记录里的 ID 可能已经失效（休眠、重启、换过外接屏后 Display ID 会重新分配）。
    ///   原实现把所有 ID 塞进同一个事务，任意一个失效就整批 CGError=1001 失败，
    ///   而且失败不清理记录，于是 DisplayManager 永远卡在恢复阶段、无限重试
    ///   （本机实测 1.5 秒一次、连刷几十条）。
    ///   现在：逐个启用、跳过已在线且激活的屏、只把失败且仍需要的 ID 留在记录里。
    @discardableResult
    static func restore(reason: String) -> Bool {
        guard let ids = pending else { return true }
        guard let setEnabled else { return false }

        let online = Set(DisplayManager.onlineDisplays())
        var remaining: [CGDirectDisplayID] = []
        for id in ids {
            // 已经在线且激活：视为已恢复，不再对它做事务
            if online.contains(id), CGDisplayIsActive(id) != 0 { continue }
            let err = applyDisplayConfig { cfg in _ = setEnabled(cfg, id, true) }
            if err != .success {
                // 这块屏可能已经不存在了（ID 失效）：不再保留，否则永远恢复不完
                Log.info("⚠️ 恢复物理屏 #\(id) 失败 CGError=\(err.rawValue)（\(reason)），判定为失效 ID 并丢弃")
                continue
            }
        }
        if remaining.isEmpty {
            try? FileManager.default.removeItem(at: markerURL)
            Log.info("✅ 已恢复物理屏 \(ids)（\(reason)）")
            return true
        }
        try? JSONEncoder().encode(remaining).write(to: markerURL, options: .atomic)
        Log.info("⚠️ 仍有物理屏待恢复 \(remaining)（\(reason)）")
        return false
    }
}
