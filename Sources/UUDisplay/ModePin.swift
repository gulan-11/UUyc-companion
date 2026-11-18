// 把虚拟屏钉在指定分辨率上。
//
// 问题（用户反馈第 1、3 条，本机实测确认）：
//   CGVirtualDisplay 只登记一个模式，但 macOS 会为它生成一整张标准模式表，
//   并在「屏幕组合变化」时套用 WindowServer 记住的那一档——本机
//   ~/Library/Preferences/ByHost/com.apple.windowserver.displays.*.plist 里
//   173 组配置中，虚拟屏大量被记成 1280×720 scale 1.0。
//   于是第一次连入、每次断开重连、以及打开设置窗口触发组合变化时，虚拟屏都会掉到低分辨率。
// 解决：建屏后主动把模式设回目标值，并在每次显示器配置变化后核对、漂移就设回。
//
// 为什么要用子进程：主进程亲自切过模式的虚拟屏，释放后要拖 40 秒以上才下线（Snug 两次实测），
// 交给短命的帮手进程切完就退出，释放照样 0.1 秒下线。
import CoreGraphics
import Foundation

enum ModePin {
    /// 帮手进程入口：--set-mode <displayID> <宽> <高> [hiDPI]
    static func runHelper(_ args: [String]) -> Never {
        // 参数顺序：<displayID> <宽> <高> [hiDPI]
        guard args.count >= 3,
              let id = CGDirectDisplayID(args[0]),
              let w = Int(args[1]), let h = Int(args[2]) else { exit(2) }
        let hiDPI = args.count > 3 ? args[3] == "1" : true
        let ok = apply(id, width: w, height: h, hiDPI: hiDPI)
        exit(ok ? 0 : 1)
    }

    /// 找出这块屏上宽高匹配（HiDPI 时要求 2 倍像素）的模式并设上去
    @discardableResult
    static func apply(_ id: CGDirectDisplayID, width: Int, height: Int, hiDPI: Bool) -> Bool {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        let modes = (CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode]) ?? []
        let logicalW = hiDPI ? width / 2 : width
        let logicalH = hiDPI ? height / 2 : height
        let candidates = modes.filter { $0.width == logicalW && $0.height == logicalH }
        guard !candidates.isEmpty else { return false }
        let target = candidates.first { m in
            hiDPI ? (m.pixelWidth == 2 * logicalW) : (m.pixelWidth == logicalW)
        } ?? candidates.first!

        if let current = CGDisplayCopyDisplayMode(id),
           current.width == target.width, current.height == target.height,
           current.pixelWidth == target.pixelWidth {
            return true   // 已经是目标模式，不做多余事务
        }
        var cfg: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&cfg) == .success else { return false }
        guard CGConfigureDisplayWithDisplayMode(cfg, id, target, nil) == .success else {
            CGCancelDisplayConfiguration(cfg)
            return false
        }
        let err = CGCompleteDisplayConfiguration(cfg, .forSession)
        if err != .success { CGCancelDisplayConfiguration(cfg) }
        return err == .success
    }

    /// 起一个短命帮手进程去切模式（避免主进程切模式后虚拟屏迟迟不下线）
    static func pinViaHelper(_ id: CGDirectDisplayID, width: Int, height: Int, hiDPI: Bool, done: @escaping (Bool) -> Void) {
        guard let exe = Bundle.main.executableURL else { done(false); return }
        let p = Process()
        p.executableURL = exe
        p.arguments = ["--set-mode", "\(id)", "\(width)", "\(height)", hiDPI ? "1" : "0"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { proc in
            DispatchQueue.main.async { done(proc.terminationStatus == 0) }
        }
        do { try p.run() } catch { done(false) }
    }
}
