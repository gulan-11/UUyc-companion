#!/bin/zsh
# 版本号管理：读 / 递增 / 打 tag。
# 用法：
#   scripts/version.sh                 查看当前版本
#   scripts/version.sh bump patch      1.2.0 → 1.2.1（修 bug）
#   scripts/version.sh bump minor      1.2.0 → 1.3.0（加功能）
#   scripts/version.sh bump major      1.2.0 → 2.0.0（不兼容变更）
#   scripts/version.sh set 1.5.0       直接指定
#   scripts/version.sh tag             用当前版本打 git tag（v1.2.0）
#
# 版本号只存在仓库根目录的 VERSION 文件里；build-app.sh 与 make-dmg.sh 都读它。
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION_FILE="VERSION"
current() { cat "$VERSION_FILE" 2>/dev/null || echo "0.0.0"; }

case "${1:-show}" in
  show)
    echo "$(current)"
    ;;

  set)
    [ $# -ge 2 ] || { echo "用法：scripts/version.sh set <x.y.z>" >&2; exit 1; }
    [[ "$2" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "❌ 版本号必须是 x.y.z：$2" >&2; exit 1; }
    echo "$2" > "$VERSION_FILE"
    echo "✅ 版本号 → $2"
    ;;

  bump)
    part="${2:-patch}"
    v="$(current)"
    major="${v%%.*}"; rest="${v#*.}"; minor="${rest%%.*}"; patch="${rest#*.}"
    case "$part" in
      major) major=$((major + 1)); minor=0; patch=0 ;;
      minor) minor=$((minor + 1)); patch=0 ;;
      patch) patch=$((patch + 1)) ;;
      *) echo "❌ 只能是 major / minor / patch" >&2; exit 1 ;;
    esac
    new="$major.$minor.$patch"
    echo "$new" > "$VERSION_FILE"
    echo "✅ 版本号 $v → $new"
    ;;

  tag)
    v="$(current)"
    tag="v$v"
    if git rev-parse "$tag" >/dev/null 2>&1; then
      echo "❌ tag $tag 已存在" >&2; exit 1
    fi
    git tag -a "$tag" -m "v$v"
    echo "✅ 已打 tag $tag（推送：git push origin $tag）"
    ;;

  *)
    echo "用法：scripts/version.sh [show|bump patch|bump minor|bump major|set x.y.z|tag]" >&2
    exit 1
    ;;
esac
