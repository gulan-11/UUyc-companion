// 推流信号：UURemoteServer 真正在采集屏幕，是「远程仍在进行」最硬的一路证据
// 依据（本机 2026-11-18 实测）：远程期间 ScreenCaptureKit 会打
//   -[SCDisplay initWithDict:] displayID=50 …  与  -[SCStream startCaptureWithCompletionHandler:]
// 停流时打 stopCaptureWithCompletionHandler / Stopping stream due to …
// 这些行与窗口开关、辅助功能权限、显示器开关都无关，因此关掉 UU 主窗口后仍能判断远程是否还在。
// 实现照搬 Snug 的成熟做法：`log stream` 子进程实时收，启动时用 `log show` 回看最近 4 小时。
import CoreGraphics
import Foundation

/// 一次推流的观测结果
struct StreamState {
    /// 最近一次「开始采集」的时间
    var lastStart: Date?
    /// 最近一次「停止采集」的时间
    var lastStop: Date?
    /// 最近一次采集的屏幕 ID（UU 正在推的那块）
    var display: CGDirectDisplayID?
    /// 状态来自哪个 UURemoteServer 进程
    var serverPID: pid_t?

    /// 正在推流：最后一次开始晚于最后一次停止
    var active: Bool {
        guard let start = lastStart else { return false }
        guard let stop = lastStop else { return true }
        return start > stop
    }
}

final class CaptureLogWatcher {
    /// log 子进程按这几个关键字过滤，回看几小时也只有几百行
    private static let keywords = [
        "SCDisplay initWithDict:",
        "startCaptureWithCompletionHandler:]",
        "stopCaptureWithCompletionHandler:]:",
        "Stopping stream due to",
    ]
    private static let predicate = "process == \"UURemoteServer\" AND ("
        + keywords.map { "eventMessage CONTAINS \"\($0)\"" }.joined(separator: " OR ") + ")"

    private static let replayWindow = "4h"

    private var process: Process?
    private var pipe: Pipe?
    private var buffer = Data()
    private var state = StreamState()
    private var replaying = false
    private var wanted = false
    private var generation = 0
    private var failures = 0
    private var lastNote = Date.distantPast

    private let queue = DispatchQueue(label: "uudisplay.capture-log", qos: .utility)

    var isRunning: Bool { process?.isRunning ?? false }

    /// 此刻是否在推流。回看未完成时返回 nil（未知），调用方据此不要下「断开」结论
    func sample() -> Bool? {
        guard isRunning, !replaying else { return nil }
        return state.active
    }

    func start() {
        guard !wanted else { return }
        wanted = true
        replay()
        launch()
    }

    func stop() {
        wanted = false
        generation += 1
        if let p = process, p.isRunning { p.terminate() }
        process = nil
        pipe = nil
    }

    // MARK: - 回看

    /// 远程中途启动本程序时，实时流里不会再出现「开始」，必须先回看
    private func replay() {
        replaying = true
        queue.async { [weak self] in
            guard let self else { return }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/log")
            p.arguments = ["show", "--last", Self.replayWindow, "--style", "ndjson", "--predicate", Self.predicate]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            do { try p.run() } catch {
                self.replaying = false
                return
            }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            var st = StreamState()
            for line in data.split(separator: UInt8(ascii: "\n")) {
                Self.apply(String(decoding: line, as: UTF8.self), to: &st)
            }
            DispatchQueue.main.async {
                self.state = st
                self.replaying = false
                Log.info("推流回看完成：\(st.active ? "远程进行中" : "当前未推流")，屏 #\(st.display.map(String.init) ?? "-")")
            }
        }
    }

    // MARK: - 实时

    private func launch() {
        generation += 1
        let gen = generation
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        p.arguments = ["stream", "--style", "ndjson", "--predicate", Self.predicate]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else { return }
            DispatchQueue.main.async { self.feed(data) }
        }
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.exited(gen) }
        }
        do { try p.run() } catch {
            Log.info("⚠️ 推流监听启动失败：\(error.localizedDescription)")
            out.fileHandleForReading.readabilityHandler = nil
            return
        }
        process = p
        pipe = out
        buffer.removeAll()
    }

    private func exited(_ gen: Int) {
        guard wanted, gen == generation else { return }
        pipe?.fileHandleForReading.readabilityHandler = nil
        pipe = nil
        process = nil
        failures += 1
        let delay = min(pow(2, Double(max(0, failures - 1))), 60)
        Log.info("推流监听退出，\(Int(delay)) 秒后重启")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.wanted, gen == self.generation else { return }
            self.launch()
        }
    }

    /// 一行常被切在两块数据里，按字节攒到换行再解码
    private func feed(_ data: Data) {
        buffer.append(data)
        while let nl = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            let before = state.active
            Self.apply(String(decoding: line, as: UTF8.self), to: &state)
            if before != state.active, Date().timeIntervalSince(lastNote) > 2 {
                lastNote = Date()
                Log.info("推流状态：\(state.active ? "进行中" : "已停止")（屏 #\(state.display.map(String.init) ?? "-")）")
            }
        }
        // 防御：万一没有换行，别让缓冲无限增长
        if buffer.count > 1 << 20 { buffer.removeAll() }
    }

    // MARK: - 解析

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let plain: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSSZ"
        return f
    }()

    private static func date(_ s: String) -> Date? {
        if let d = iso.date(from: s) { return d }
        return plain.date(from: s)
    }

    private static func apply(_ line: String, to state: inout StreamState) {
        guard line.hasPrefix("{") else { return }
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let message = object["eventMessage"] as? String,
              let stamp = object["timestamp"] as? String,
              let date = date(stamp) else { return }
        if let path = object["processImagePath"] as? String, !path.hasSuffix("/UURemoteServer") { return }
        if let pid = (object["processID"] as? Int).flatMap(pid_t.init(exactly:)) {
            if let known = state.serverPID, known != pid {
                // 换了进程：旧的推流状态作废（崩溃重启时不会留停流日志）
                state = StreamState(lastStart: nil, lastStop: nil, display: nil, serverPID: pid)
            } else {
                state.serverPID = pid
            }
        }
        if message.contains("SCDisplay initWithDict:") {
            if let r = message.range(of: "displayID=") {
                let digits = message[r.upperBound...].prefix { $0.isNumber }
                if let id = CGDirectDisplayID(digits) { state.display = id }
            }
            return
        }
        if message.contains("startCaptureWithCompletionHandler:]") {
            state.lastStart = date
            return
        }
        if message.contains("stopCaptureWithCompletionHandler:]:") || message.contains("Stopping stream due to") {
            state.lastStop = date
        }
    }
}
