#!/bin/zsh
# 生成 DMG 安装包：把 App 拖进「应用程序」即可安装。
# 用法：scripts/make-dmg.sh [输出目录=dist]
# 依赖：hdiutil（系统自带）、App 已由 build-app.sh 生成
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="UUyc companion"
APP="build/$APP_NAME.app"
VERSION="1.1.3-fix.2"
OUT_DIR="${1:-dist}"
DMG="$OUT_DIR/UUyc-companion-$VERSION.dmg"

if [ ! -d "$APP" ]; then
  echo "❌ 找不到 $APP，先运行 scripts/build-app.sh" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

# 暂存目录：App + 指向 /Applications 的快捷方式（拖拽安装）
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

# 附一份说明，打开 DMG 就能看到
cat > "$STAGE/安装说明.txt" <<'TXT'
UU远程伴侣（UUyc companion）修复版
====================================

安装
----
把「UUyc companion.app」拖到旁边的 Applications 文件夹（或 /Applications）。

首次打开
--------
若提示「无法验证开发者」，去 系统设置 → 隐私与安全性，点「仍要打开」。

必须授权（否则无法识别是哪台设备连入）
--------------------------------------
系统设置 → 隐私与安全性 → 辅助功能 → 打开「UU远程伴侣」。
若列表里没有，点「+」添加 /Applications/UUyc companion.app。

本版已改用固定证书签名，之后升级重建都不会再掉授权（只这一次需要手动授权）。

恢复屏幕的快捷键
----------------
⌃ control + ⌥ option + ⌘ command + 9   立即恢复所有物理屏

本版新增
--------
1. 远程时静音这台 Mac 的扬声器：声音只从控制端（Windows/手机）播放，
   本机不出声。实测设备静音不影响 UU 采集系统音频。远程结束自动恢复。
2. 自动修复卡住的修饰键：远控时偶发 Command 收不回来（点图标弹文件夹、
   菜单栏点不动），远程期间核对真实键盘状态，发现幽灵按下就补发 keyUp。

两项都可以在设置里单独关闭。

卸载
----
退出菜单栏里的 UU远程伴侣，把 App 移到废纸篓；
可选：rm -rf ~/Library/Application\ Support/UUDisplay
TXT

rm -f "$DMG"
hdiutil create \
  -volname "$APP_NAME $VERSION" \
  -srcfolder "$STAGE" \
  -ov -format UDZO \
  -fs HFS+ \
  "$DMG" >/dev/null

echo "✅ 已生成 $DMG"
hdiutil imageinfo "$DMG" 2>/dev/null | grep -E "Format|Total Bytes" | head -3
ls -lh "$DMG"
