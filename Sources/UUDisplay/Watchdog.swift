// 看门狗：由 launchd 托管（KeepAlive）的独立进程，兜底恢复被禁用的物理屏
// 触发条件（存在禁用记录时）：主程序不在 / 心跳超时（卡死，先强杀再恢复）/ UU 确已断开
//
// 2026-11-18 修复（用户反馈第 2 条「Mac 的屏幕启动了，不会关闭」）：
//   原判定只看覆盖窗口 UURemoteServer 是否在屏。实测远程推流期间该窗口经常一个都没有，
//   于是看门狗每 5 秒就认定「UU 已断开」并把物理屏点亮；主程序又立刻关掉，两者来回拉锯
//   （日志中 17:34:49 关闭 → 17:34:50 恢复 → 17:34:51 关闭 → 17:34:55 恢复）。
//   每次开关都是一次屏幕组合变化，WindowServer 顺手把虚拟屏拨回它记住的 1280×720，
//   这就是「每次都要手动切到 2560×1440」的直接原因。
//   现在：① 用三路信号（覆盖窗口 / 推流断言 / 推流日志）判在场；
//        ② 主程序刚关屏后的宽限期内一律不动；
//        ③ 连续多拍都确认不在场才恢复，避免一次误判就点亮屏幕。
import CoreGraphics
import Foundation
import ServiceManagement

enum Heartbeat {
    static let appURL = ConfigStore.dir.appendingPathComponent("heartbeat-app")
    static let watchdogURL = ConfigStore.dir.appendingPathComponent("heartbeat-watchdog")

    static func beat(_ url: URL) {
        try? "\(getpid())".write(to: url, atomically: true, encoding: .utf8)
    }

    /// (pid, 距上次心跳秒数)
    static func read(_ url: URL) -> (pid: pid_t, age: TimeInterval)? {
        guard let s = try? String(contentsOf: url, encoding: .utf8), let pid = pid_t(s.trimmingCharacters(in: .whitespacesAndNewlines)),
              let m = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date else { return nil }
        return (pid, Date().timeIntervalSince(m))
    }

    static func alive(_ url: URL, maxAge: TimeInterval) -> Bool {
        guard let hb = read(url) else { return false }
        return kill(hb.pid, 0) == 0 && hb.age < maxAge
    }
}

enum Watchdog {
    /// 旧版用 SMAppService 注册的标识，迁移时注销
    static let legacyLabel = "com.corndog.uudisplay.watchdog"
    /// 检查间隔（实测 1 秒间隔时 CPU 约 0.2%，改为 5 秒进一步降低开销，代价是恢复最多慢几秒）
    static let interval: TimeInterval = 5
    static let appMaxAge: TimeInterval = 10
    /// 判定 UU 确实离开所需的持续时间：跨过多次采样，单次误判不会点亮屏幕
    static let uuGoneLimit: TimeInterval = 25
    /// 物理屏刚被主程序关闭后的宽限期：期间不判离开（关屏本身会让 UU 短暂停流）
    static let graceAfterDisable: TimeInterval = 20

    /// 心跳超时须大于检查间隔，留出一个间隔的余量
    static var isRunning: Bool { Heartbeat.alive(Heartbeat.watchdogURL, maxAge: interval * 2 + 2) }

    private static let assumeUU = ProcessInfo.processInfo.environment["UUDISPLAY_WATCHDOG_ASSUME_UU"] == "1"

    static func run() -> Never {
        try? FileManager.default.createDirectory(at: ConfigStore.dir, withIntermediateDirectories: true)
        Log.info("[看门狗] 启动 pid=\(getpid())")
        var uuGoneSince: Date?
        var disabledSince = Date()
        var lastPending: [CGDirectDisplayID]?
        var audioGoneSince: Date?
        while true {
            autoreleasepool {
                Heartbeat.beat(Heartbeat.watchdogURL)

                // 音频兜底：主程序崩溃/被杀后，本机不该一直静音
                if AudioControl.pending {
                    let hbAudio = Heartbeat.read(Heartbeat.appURL)
                    let appAlive = hbAudio.map { kill($0.pid, 0) == 0 } ?? false
                    let healthy = appAlive && (hbAudio?.age ?? .infinity) < appMaxAge
                    if !healthy {
                        AudioControl.restoreAfterRemote(reason: "看门狗：主程序\(appAlive ? "卡死" : "不在")")
                        audioGoneSince = nil
                    } else if !(assumeUU || UUPresence.any() || UUPresence.servingAssertion()) {
                        audioGoneSince = audioGoneSince ?? Date()
                        if Date().timeIntervalSince(audioGoneSince!) > uuGoneLimit {
                            AudioControl.restoreAfterRemote(reason: "看门狗：UU 确已断开但本机仍静音")
                            audioGoneSince = nil
                        }
                    } else {
                        audioGoneSince = nil
                    }
                }

                guard let pending = PhysicalDisplays.pending else {
                    uuGoneSince = nil
                    lastPending = nil
                    return
                }
                // 禁用记录换了（新一次关屏）：重新计宽限期
                if pending != lastPending {
                    lastPending = pending
                    disabledSince = Date()
                    uuGoneSince = nil
                }

                let hb = Heartbeat.read(Heartbeat.appURL)
                let appExists = hb.map { kill($0.pid, 0) == 0 } ?? false
                let appHealthy = appExists && (hb?.age ?? .infinity) < appMaxAge
                // 测试开关：假定 UU 一直连着，用于单独验证心跳超时
                let uu = assumeUU || UUPresence.any() || UUPresence.servingAssertion()

                if !appHealthy {
                    if appExists, let pid = hb?.pid {
                        Log.info("[看门狗] 主程序心跳超时 \(Int(hb?.age ?? 0)) 秒，强制结束 pid=\(pid)")
                        kill(pid, SIGKILL)
                    }
                    PhysicalDisplays.restore(reason: "看门狗：主程序\(appExists ? "卡死" : "不在")")
                    uuGoneSince = nil
                    return
                }

                // 主程序健康：只在「宽限期已过 + 连续多拍确认不在场」时才恢复
                guard Date().timeIntervalSince(disabledSince) > graceAfterDisable else {
                    uuGoneSince = nil
                    return
                }
                uuGoneSince = uu ? nil : (uuGoneSince ?? Date())
                if let t = uuGoneSince, Date().timeIntervalSince(t) > uuGoneLimit {
                    PhysicalDisplays.restore(reason: "看门狗：UU 确已断开但物理屏未恢复")
                    uuGoneSince = nil
                }
            }
            Thread.sleep(forTimeInterval: interval)
        }
    }
}

/// 看门狗的 LaunchAgent 安装（~/Library/LaunchAgents + launchctl）。
/// 不用 SMAppService.agent：自签证书（无 Team ID）签名时，BTM 生成的启动约束为空 cdhash 列表，
/// launchd 持续 spawn 失败（EX_CONFIG / OS_REASON_CODESIGNING）。
enum WatchdogAgent {
    static let label = "com.corndog.uudisplay.watchdog-agent"
    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }
    static var executable: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/UUDisplayWatchdog") }
    private static var domain: String { "gui/\(getuid())" }

    @discardableResult
    private static func launchctl(_ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }

    static var isLoaded: Bool { launchctl(["print", "\(domain)/\(label)"]) == 0 }

    private static var plistData: Data {
        let dict: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executable.path, "--watchdog"],
            "KeepAlive": true,
            // 被结束后最快 5 秒重新拉起（launchd 默认 10 秒），也避免反复崩溃时频繁重启
            "ThrottleInterval": 5,
            "RunAtLoad": true,
            "ProcessType": "Interactive",
            "LimitLoadToSessionType": "Aqua",
            // 让「登录项与扩展」把它显示为本 App（名称、图标），而不是一个陌生的可执行文件
            "AssociatedBundleIdentifiers": [Bundle.main.bundleIdentifier ?? "com.corndog.uudisplay"],
        ]
        return (try? PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)) ?? Data()
    }

    /// 写入（路径变化时更新）并加载；已加载且配置未变则不动
    static func ensureInstalled() {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            Log.info("⚠️ 找不到看门狗可执行文件，跳过安装：\(executable.path)")
            return
        }
        migrateFromSMAppService()
        let data = plistData
        let changed = (try? Data(contentsOf: plistURL)) != data
        if changed {
            try? FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: plistURL, options: .atomic)
        }
        if changed && isLoaded { launchctl(["bootout", "\(domain)/\(label)"]) }
        if !isLoaded {
            let rc = launchctl(["bootstrap", domain, plistURL.path])
            Log.info(rc == 0 ? "✅ 看门狗已加载" : "⚠️ 看门狗加载失败（launchctl 返回 \(rc)），可能被「登录项与扩展」中的后台开关关闭")
        }
    }

    /// 停止本次登录中的看门狗，保留 LaunchAgent 配置（下次打开 App 或重新登录时恢复）
    static func stopForSession() {
        guard isLoaded else { return }
        launchctl(["bootout", "\(domain)/\(label)"])
        try? FileManager.default.removeItem(at: Heartbeat.watchdogURL)
        Log.info("已停止本次登录中的看门狗")
    }

    /// 卸载：停止并移除 LaunchAgent（用户在设置里关闭看门狗，或从未开启）
    static func uninstall() {
        migrateFromSMAppService()
        let loaded = isLoaded
        if loaded { launchctl(["bootout", "\(domain)/\(label)"]) }
        let existed = FileManager.default.fileExists(atPath: plistURL.path)
        try? FileManager.default.removeItem(at: plistURL)
        if loaded || existed { Log.info("已卸载看门狗") }
        try? FileManager.default.removeItem(at: Heartbeat.watchdogURL)
    }

    /// 清理旧版 SMAppService 注册的看门狗（launchd 中仍在反复 spawn 失败）
    private static func migrateFromSMAppService() {
        guard launchctl(["print", "\(domain)/\(Watchdog.legacyLabel)"]) == 0 else { return }
        SMAppService.agent(plistName: "\(Watchdog.legacyLabel).plist").unregister { error in
            Log.info(error == nil ? "已注销旧版看门狗（SMAppService）" : "⚠️ 注销旧版看门狗：\(error!.localizedDescription)")
        }
        launchctl(["bootout", "\(domain)/\(Watchdog.legacyLabel)"])
    }
}
