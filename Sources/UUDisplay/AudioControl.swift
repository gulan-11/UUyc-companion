// 本机音频输出控制：远程期间把 Mac 的扬声器静音，声音只走控制端。
//
// 实测依据（2026-11-18，macOS 27.3 / M5）：
//   把默认输出设备设成 mute 之后，ScreenCaptureKit 仍然采到完整音频
//   （SCStream capturesAudio=true，peak=0.0089、nonZero=46649），
//   说明设备级 mute 只影响「本机扬声器放不放声」，不影响系统音频采集。
//   因此「声音走控制端、本机不出声」可以靠 mute 实现，不需要动音频路由。
//
// 与「关闭物理屏」的区别：mute 不改变显示器拓扑，不会让 UU 重建推流，
// 因此不会触发 issue #16 那个「重建后丢音频输出」的竞态。
import CoreAudio
import Foundation

enum AudioControl {
    /// 默认输出设备
    static func defaultOutputDevice() -> AudioDeviceID? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        let st = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return st == noErr && id != 0 ? id : nil
    }

    /// 读当前 mute 状态；设备不支持 mute 属性时返回 nil
    static func isMuted(_ id: AudioDeviceID) -> Bool? {
        var mute = Int32(0)
        var size = UInt32(MemoryLayout<Int32>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
                                              mScope: kAudioDevicePropertyScopeOutput,
                                              mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(id, &addr) else { return nil }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &mute) == noErr else { return nil }
        return mute != 0
    }

    @discardableResult
    static func setMuted(_ id: AudioDeviceID, _ muted: Bool) -> Bool {
        var mute = Int32(muted ? 1 : 0)
        let size = UInt32(MemoryLayout<Int32>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
                                              mScope: kAudioDevicePropertyScopeOutput,
                                              mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(id, &addr) else { return false }
        return AudioObjectSetPropertyData(id, &addr, 0, nil, size, &mute) == noErr
    }

    // MARK: - 远程期间的静音

    /// 静音前的状态，用于还原（写盘，异常退出后也能恢复）
    private static let markerURL = ConfigStore.dir.appendingPathComponent("audio-mute.json")

    private struct Marker: Codable {
        let deviceID: AudioDeviceID
        /// 静音前是否本来就是静音（是的话断开后保持静音，不擅自打开）
        let wasMuted: Bool
        /// 我们动手静音的时刻：用于判断之后用户有没有自己改过
        var mutedAt: Date?
    }

    private static var marker: Marker? {
        guard let data = try? Data(contentsOf: markerURL),
              let m = try? JSONDecoder().decode(Marker.self, from: data) else { return nil }
        return m
    }

    /// 远程开始：静音默认输出设备。返回是否真的做了改动
    @discardableResult
    static func muteForRemote() -> Bool {
        guard marker == nil else { return false }   // 已经静音过，别覆盖原始状态
        guard let id = defaultOutputDevice() else { return false }
        let before = isMuted(id) ?? false
        // 先记账再静音：异常退出后看门狗/下次启动能据此恢复
        let m = Marker(deviceID: id, wasMuted: before, mutedAt: Date())
        if let data = try? JSONEncoder().encode(m) { try? data.write(to: markerURL, options: .atomic) }
        guard setMuted(id, true) else {
            try? FileManager.default.removeItem(at: markerURL)
            return false
        }
        Log.info("🔇 已静音本机输出设备 #\(id)（远程期间声音只走控制端）")
        return true
    }

    /// 远程结束：恢复原来的静音状态。
    ///
    /// 三种情况：
    ///   1. 远程前本来就是静音 → 保持静音，不擅自打开
    ///   2. 远程前不是静音，且现在仍是「我们设的静音」→ 取消静音
    ///   3. 远程期间用户自己改过（现在不是静音了）→ 尊重用户，不动
    @discardableResult
    static func restoreAfterRemote(reason: String) -> Bool {
        guard let m = marker else { return true }
        if m.wasMuted {
            try? FileManager.default.removeItem(at: markerURL)
            Log.info("🔊 远程前就是静音，保持静音（\(reason)）")
            return true
        }
        // 用户远程期间自己把声音打开了：不覆盖他的选择
        if isMuted(m.deviceID) == false {
            try? FileManager.default.removeItem(at: markerURL)
            Log.info("🔊 远程期间用户已自行取消静音，不再改动（\(reason)）")
            return true
        }
        let ok = setMuted(m.deviceID, false)
        if ok {
            try? FileManager.default.removeItem(at: markerURL)
            Log.info("🔊 已恢复本机音频（\(reason)）")
        } else {
            Log.info("⚠️ 恢复本机音频失败（\(reason)），稍后重试")
        }
        return ok
    }

    /// 有未恢复的静音记录（用于启动时兜底）
    static var pending: Bool { marker != nil }
}
