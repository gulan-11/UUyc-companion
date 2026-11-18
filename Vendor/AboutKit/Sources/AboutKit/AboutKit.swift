// AboutKit 的本地替代实现（上游仓库已 404）。
// 只覆盖 UUDisplay 实际用到的接口，界面用纯 AppKit，不依赖 SwiftUI 宏。
import AppKit

public struct OpenSourceCredit {
    public let name: String
    public let url: String
    public let author: String
    public let license: String
    public let usage: String

    public init(name: String, url: String, author: String, license: String, usage: String) {
        self.name = name
        self.url = url
        self.author = author
        self.license = license
        self.usage = usage
    }
}

public struct AboutApp {
    public let name: String
    public let summary: String
    public let repository: String
    public let credits: [OpenSourceCredit]
    public let disclaimer: String

    public init(name: String, summary: String, repository: String, credits: [OpenSourceCredit], disclaimer: String) {
        self.name = name
        self.summary = summary
        self.repository = repository
        self.credits = credits
        self.disclaimer = disclaimer
    }
}

public final class AboutWindowController {
    private let app: AboutApp
    private var window: NSWindow?

    public init(app: AboutApp) { self.app = app }

    public func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
                         styleMask: [.titled, .closable],
                         backing: .buffered, defer: false)
        w.title = "关于 \(app.name)"
        w.isReleasedWhenClosed = false
        w.contentView = makeContentView()
        w.center()
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 调试：渲染为 PNG
    public func render(to url: URL) {
        let view = makeContentView()
        view.frame = NSRect(origin: .zero, size: view.fittingSize)
        view.layoutSubtreeIfNeeded()
        if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
        }
    }

    private func makeContentView() -> NSView {
        let text = NSMutableAttributedString()
        func line(_ s: String, _ size: CGFloat, _ weight: NSFont.Weight = .regular, spacing: CGFloat = 6) {
            text.append(NSAttributedString(string: s + "\n", attributes: [
                .font: NSFont.systemFont(ofSize: size, weight: weight),
                .foregroundColor: NSColor.labelColor,
            ]))
            text.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: spacing)]))
        }
        line(app.name, 20, .bold)
        line(app.summary, 12)
        line(app.repository, 11)
        for c in app.credits {
            line("\(c.name) · \(c.author) · \(c.license) · \(c.usage)", 11)
        }
        line(app.disclaimer, 10)

        let label = NSTextField(labelWithAttributedString: text)
        label.isSelectable = true
        label.preferredMaxLayoutWidth = 480
        label.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -24),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 24),
            label.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -24),
            container.widthAnchor.constraint(equalToConstant: 520),
        ])
        container.layoutSubtreeIfNeeded()
        container.frame = NSRect(origin: .zero, size: container.fittingSize)
        return container
    }
}

/// 窗口标题前缀编号，便于对照文案（写入 ui-labels.txt）
public enum DebugLabels {
    public static var fileURL: URL?
    public static var windowPrefix: ((NSWindow) -> String?)?

    private static var timer: Timer?

    public static func start() {
        timer?.invalidate()
        let t = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in dump() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        dump()
    }

    public static func decorate(_ menu: NSMenu) {}

    private static func dump() {
        guard let fileURL, let prefix = windowPrefix else { return }
        var lines: [String] = []
        for w in NSApp.windows where w.isVisible {
            if let p = prefix(w) { lines.append("\(p)\t\(w.title)") }
        }
        try? lines.joined(separator: "\n").write(to: fileURL, atomically: true, encoding: .utf8)
    }
}
