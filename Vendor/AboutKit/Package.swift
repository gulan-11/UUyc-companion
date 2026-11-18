// swift-tools-version: 5.9
// 本地替代 AboutKit（上游 aoyamashou/AboutKit 已不可访问，404）。
// 只实现本项目用到的三个接口：AboutApp / AboutWindowController / DebugLabels / OpenSourceCredit。
// 行为：一个原生「关于」面板 + 窗口 Debug 编号前缀（写入 ui-labels.txt）。
import PackageDescription

let package = Package(
    name: "AboutKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AboutKit", targets: ["AboutKit"]),
    ],
    targets: [
        .target(name: "AboutKit"),
    ]
)
