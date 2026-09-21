#!/bin/bash
# 构建 / 测试 / 运行。**一律用这个脚本，不要直接 swift build**。
#
# 为什么：SwiftPM 的构建数据库是 SQLite，放在 TCC 保护目录（~/Documents、
# ~/Desktop、~/Downloads）里会报 `accessing build database ...: disk I/O error`。
# 后果**不是噪音**——构建状态记不住，于是**改了源码也不重新编译**，你会拿着
# 旧二进制反复测试而毫无察觉。解法是把 scratch path 挪到仓库之外。
#
#   scripts/build.sh            构建
#   scripts/build.sh test       跑测试
#   scripts/build.sh run        构建并前台运行（注意：裸二进制拿不到 TCC 权限，
#                               字幕和划词要测得用 make_app.sh）
#   scripts/build.sh clean      清掉构建产物

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PKG="$ROOT/DesktopPet"
SCRATCH="${PET_BUILD_DIR:-/tmp/desktop-pet-build}"
CONFIG="${PET_CONFIG:-release}"

cd "$PKG"

# 产物目录**一律问 SwiftPM 要**，不要写死。工具链换个版本产物就换个位置，
# 写死的话脚本会一直拿着上一个工具链留下的旧二进制去组装 .app。
bin_dir() { swift build -c "$CONFIG" --scratch-path "$SCRATCH" --show-bin-path; }

case "${1:-build}" in
    test)     exec swift test --scratch-path "$SCRATCH" "${@:2}" ;;
    run)      swift build -c "$CONFIG" --scratch-path "$SCRATCH"
              exec "$(bin_dir)/DesktopPet" "${@:2}" ;;
    clean)    rm -rf "$SCRATCH" /tmp/desktop-pet-stage && echo "已清理构建产物" ;;
    bin-path) exec swift build -c "$CONFIG" --scratch-path "$SCRATCH" --show-bin-path ;;
    build)    swift build -c "$CONFIG" --scratch-path "$SCRATCH" "${@:2}"
              echo "产物：$(bin_dir)/DesktopPet" ;;
    *)        exec swift "$@" --scratch-path "$SCRATCH" ;;
esac
