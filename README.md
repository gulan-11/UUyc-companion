# UUyc companion · 修复版

> 本项目基于 [aoyamashou/UUyc-companion](https://github.com/aoyamashou/UUyc-companion) v1.1.3（MIT，2026-10 停更）二次修改，
> 完整保留原作者的版权声明与提交历史。原作者：AoyamaShou。
> 本仓库只修 bug，不加新功能。

改善 Mac 版 UU远程 的使用体验：远程开始时自动提供与设备同分辨率的虚拟屏幕，告别上下大黑边；可选自动关闭其他屏幕。

---

## 这个分支修了什么

上游 v1.1.3 在 macOS 27 / UU远程 4.42.0 上存在 6 个问题，全部已定位到具体代码行并修复。

### 1. 首次远程分辨率很低，需要手动切到 2560×1440

**根因**：`CGVirtualDisplay` 只登记一个模式，但 macOS 会为它生成整张标准模式表，并在「屏幕组合变化」时套用 WindowServer 记住的那一档。实测本机
`~/Library/Preferences/ByHost/com.apple.windowserver.displays.*.plist` 里 173 组配置中，虚拟屏大量被记成 `1280×720 scale 1.0`。

**修复**：新增 `ModePin.swift`。建屏后、以及每次 `didChangeScreenParametersNotification` 后核对当前模式，漂移就设回目标值。
切换由短命帮手进程完成（主进程亲自切模式会让虚拟屏释放后拖 40 秒才下线）。

### 2. 再次远程仍低分辨率，且 Mac 屏幕亮着不关

**根因**：看门狗把「UURemoteServer 覆盖窗口不在屏」当成「UU 已断开」，每 5 秒点亮物理屏，主程序又立刻关掉，两者来回拉锯。每次开关都是一次屏幕组合变化，正好触发问题 1。

原版日志：

```
18:34:49  ✅ 已关闭物理屏 [1]
18:34:50  ✅ 已恢复物理屏 [1]（看门狗：UU 已断开但物理屏未恢复）
18:34:51  ✅ 已关闭物理屏 [1]
18:34:55  ✅ 已恢复物理屏 [1]（看门狗：UU 已断开但物理屏未恢复）
```

**修复**：看门狗改用三路在场判定（覆盖窗口 / 电源断言 / 推流日志），断开需连续确认 25 秒，主程序关屏后 20 秒内不动作。

### 3. 点开设置窗口不出现，且分辨率被拉到很低

**根因**：`NSWindow(contentViewController:)` 之后再改 `styleMask` 会把内容尺寸清成 0×0。对照实测：

```
旧写法 contentView 尺寸: (0.0, 0.0)    窗口: (0.0, 32.0)     ← 只剩一条标题栏
新写法 contentView 尺寸: (720.0, 300.0) 窗口: (720.0, 332.0)
```

窗口「一直不出现」是因为它根本没有内容区，不是被挡住。

**修复**：先按最终 styleMask 建窗口再挂内容，显式设置尺寸。

### 4. 关闭 UU 远程的窗口后虚拟屏失效

**根因**：原判定只认 `UURemoteServer` 的覆盖窗口。实测远程推流期间连续采样 30 次，`overlay` **全程 false** —— 旧代码唯一依赖的信号在实际环境下不存在。

**修复**：新增两路独立信号：

| 信号 | 来源 | 特点 |
|---|---|---|
| 推流断言 | `IOPMCopyAssertionsByProcess` 里 `UURemote Disable Display Sleep` | 与窗口、辅助功能权限都无关 |
| 推流日志 | `log stream` 解析 ScreenCaptureKit 的启停事件 | 关掉 UU 主窗口仍有效 |

推流日志监听还带回看（`log show --last 4h`），远程中途启动本程序也能正确识别。

### 5. 设置窗口唤出后一直置顶

**根因**：修问题 3 时用了 `w.level = .floating`，那是**永久层级**。

**修复**：只在唤出瞬间抬到 floating 盖住远程全屏画面，0.4 秒后回落 `.normal`。

```
唤出瞬间 level=3 (floating=3)
1 秒后   level=0 (normal=0)
```

### 6. 已授权却一直提示未授权

**根因**：ad-hoc 签名没有证书，而 TCC 记录绑的是「证书叶子哈希」。tccd 日志：

```
Failed to match existing code requirement for subject com.corndog.uudisplay
    and service kTCCServiceAccessibility
    identifier "com.corndog.uudisplay" and certificate leaf = H"253abdadb6531b8ea36e61e413781f606d8370cc"
```

每次重新编译 CDHash 都变，系统认定「不是授权过的那个程序」，用户手动打开开关也匹配不上。

**修复**：改用固定代码签名证书，签名要求固定为：

```
designated => identifier "com.corndog.uudisplay" and certificate root = H"4191e32649300c7603ebe8e29d8c86180e51e0b0"
```

故意 `touch` 源文件后重建，该哈希不变 —— 升级不再掉授权。

### 顺带修的

- **`CGError=1001` 死循环**（上游 issue #19）：`disabled-displays.json` 残留失效 Display ID 时，`restore` 永远失败、1.5 秒重试一次刷屏。改为逐个启用、跳过已在线屏、丢弃失效 ID。
- **AboutKit 404**：上游依赖 `aoyamashou/AboutKit` 已不可访问，源码无法构建。新增 `Vendor/AboutKit` 本地替代实现。
- **读不到控制端名称时不建屏**：辅助功能未授权、UU 主窗口关着、别的 App 全屏时，按「上次的控制端 / 唯一已配置设备」兜底。
- **构建脚本 zsh 变量展开**：`$SIGN_IDENTITY」` 会被 zsh 当成变量名，改为 `${SIGN_IDENTITY}`。
- **DMG 打包脚本**：新增 `scripts/make-dmg.sh`。

---

## 安装

从 [Releases](../../releases) 下载 `UUyc-companion-1.1.3-fix.1.dmg`，打开后把 App 拖进 Applications。

**必须授权一次**（否则无法识别是哪台设备连入）：

> 系统设置 → 隐私与安全性 → 辅助功能 → 打开「UU远程伴侣」

若列表里没有，点 `+` 添加 `/Applications/UUyc companion.app`。本版签名已固定，之后升级不会掉。

恢复屏幕的快捷键：**⌃⌥⌘9**

## 从源码构建

```bash
# 需要 macOS 14+、Swift 6 工具链（Command Line Tools 即可，不需要 Xcode）
bash scripts/build-app.sh          # 生成 build/UUyc companion.app
bash scripts/make-dmg.sh           # 生成 dist/UUyc-companion-<版本>.dmg
bash scripts/build-app.sh --install # 构建并安装到 /Applications

./scripts/test-connection.sh       # 跑回归测试
```

**关于签名**：默认用证书 `UUDisplay Signing` 签名，钥匙串路径
`~/Library/Keychains/uudisplay.keychain-db`（密码 `uudisplaysign`，可用 `SIGN_KEYCHAIN` / `SIGN_KEYCHAIN_PASSWORD` 覆盖）。
你自己的机器上没有这张证书时，用 ad-hoc 签名构建：

```bash
SIGN_IDENTITY=- bash scripts/build-app.sh
```

代价是每次重建后辅助功能授权会失效，需要重新授权。

## 测试

```bash
./scripts/test-connection.sh
```

```
PASS: Android without overlay, unchanged session, debounce, delayed name, device switch, disconnect
PASS: blocked AX keeps main thread responsiveness; no overlapping reads; overlay disconnect; stale result rejected
PASS: 三路在场信号、未知信号、静默期、快速重连与模式目标判定
```

## 已知未修

以下两个问题需要改动输入/音频路径，风险高于本次修复范围，未包含：

- **远程无声**（上游 issue #16）：物理屏全关后 ScreenCaptureKit 音频采集会停。
- **Command 键卡住**（上游 issue #17）：Windows 远控 Mac 时偶发，怀疑热键冲突。

## 许可

MIT，见 [LICENSE](LICENSE)。原作者版权声明与提交历史完整保留。

本项目与 UU远程 及其开发商没有任何直接、间接或连带关系。如果将来 UU远程 官方在 Mac 版内置了同样功能，删掉本应用即可。
