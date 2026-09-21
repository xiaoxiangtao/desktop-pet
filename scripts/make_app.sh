#!/bin/bash
# 把 SwiftPM 的产物组装成 DesktopPet.app。
#
# **为什么必须打成 .app 而不是直接跑二进制**：TCC（麦克风/辅助功能/屏幕录制）
# 认的是 bundle 及其 Info.plist 里的用途说明。裸二进制没有 plist，
# macOS 会**直接拒绝而不弹授权框**——表现是字幕一个字都不出，且没有任何报错。
#
#   scripts/make_app.sh              只组装到暂存区
#   scripts/make_app.sh --run        组装并前台运行
#   scripts/make_app.sh --install    组装并装到 /Applications 再启动
#
# 组装目标放在 /tmp 而不是仓库里：仓库里留一个 .app，Spotlight 会把它和
# /Applications 那份一起索引，搜出来两个一模一样的图标，分不清在用哪个。

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="${PET_APP_NAME:-DesktopPet}"
APP="${PET_STAGE:-/tmp/desktop-pet-stage}/$APP_NAME.app"
VERSION="$(cat "$ROOT/VERSION" 2>/dev/null || echo 0.0.0)"

bash "$ROOT/scripts/build.sh" >/dev/null
BIN_DIR="$(bash "$ROOT/scripts/build.sh" bin-path)"
BIN="$BIN_DIR/DesktopPet"
[ -x "$BIN" ] || { echo "构建产物不在 $BIN——SwiftPM 的输出布局变了？"; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/DesktopPet"

# SwiftPM 的资源 bundle 要一起带上，否则精灵图和 CEFR 词表加载不到。
# 按 macOS 的规矩放在 Contents/Resources：**不要往 .app 根目录放**，
# 那会让 codesign 报 `unsealed contents present in the bundle root`、签名直接失效。
# 代码侧不依赖 SwiftPM 生成的 Bundle.module 去找它们（那东西的查找顺序随工具链变），
# 自己的查找逻辑在 Sources/PetCore/ResourceBundle.swift。
for b in "$BIN_DIR"/*.bundle; do
    [ -e "$b" ] && cp -R "$b" "$APP/Contents/Resources/"
done

# **硬校验：素材必须真的在包里。**
# 没有这一段的话，缺素材的表现是"包打出来了、CI 全绿、用户双击闪退"——
# 2026-09-21 就是这么发出去一个起不来的 0.1.0。
find "$APP/Contents/Resources" -name "cat-anim.json" | grep -q . \
    || { echo "✗ 找不到 cat-anim.json，精灵图加载不了，app 会在启动时崩"; exit 1; }
find "$APP/Contents/Resources" -name "cat-poses.webp" | grep -q . \
    || { echo "✗ 找不到 cat-poses.webp"; exit 1; }
find "$APP/Contents/Resources" -name "cefr_a1_words.txt" | grep -q . \
    || { echo "✗ 找不到 cefr_a1_words.txt，查词判定会退化"; exit 1; }
echo "✓ 资源校验通过"

ICNS="$ROOT/DesktopPet/Sources/PetAnimation/Resources/icon.icns"
[ -f "$ICNS" ] && cp "$ICNS" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>app.desktoppet.DesktopPet</string>
    <key>CFBundleExecutable</key><string>DesktopPet</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <!-- .accessory 应用：不进 Dock、不抢焦点 -->
    <key>LSUIElement</key><true/>
    <!-- 没有这几条，macOS 直接拒绝而**不弹授权框**，对应功能会静默失灵 -->
    <key>NSMicrophoneUsageDescription</key>
    <string>用于把你正在听的英文实时转成字幕。音频只在本机处理，不上传。</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>用于把语音转成文字字幕，识别由 macOS 在本机完成。</string>
    <key>NSScreenCaptureUsageDescription</key>
    <string>用于采集电脑正在播放的声音做实时字幕。只取声音，不截取画面。</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>用于在划选文字后读取选中的内容送去查词。</string>
</dict>
</plist>
PLIST

# 签名。有 Developer ID 就用（设 PET_SIGN_IDENTITY），否则 ad-hoc。
# **ad-hoc 签名是必需的，不是可选项**：完全没签名的 bundle 在 Apple Silicon 上
# 根本起不来。ad-hoc 的代价是 TCC 权限跟着 cdhash 走，每次重建都要重新授权。
IDENTITY="${PET_SIGN_IDENTITY:--}"
codesign --force --deep --options runtime --sign "$IDENTITY" "$APP" 2>/dev/null \
    || codesign --force --deep --sign "$IDENTITY" "$APP"
if [ "$IDENTITY" = "-" ]; then
    echo "✓ 已 ad-hoc 签名（未公证；分发时用户需右键「打开」一次）"
else
    echo "✓ 已用「$IDENTITY」签名"
fi
# **必须验签名。** 软链或多余文件落在 bundle 根会让签名失效，而这在
# `codesign --sign` 那一步是不报错的，只有 --verify 才看得出来。
codesign --verify --strict "$APP" 2>&1 | grep -q . \
    && { echo "✗ 签名校验不过，Gatekeeper 会拒绝这个包"; codesign --verify --verbose=2 "$APP"; exit 1; }
echo "✓ 签名校验通过"
echo "✓ $APP"

case "${1:-}" in
    --run)
        exec "$APP/Contents/MacOS/DesktopPet"
        ;;
    --install)
        pkill -f "$APP_NAME.app/Contents/MacOS/DesktopPet" 2>/dev/null || true
        sleep 1
        rm -rf "/Applications/$APP_NAME.app"
        cp -R "$APP" "/Applications/$APP_NAME.app"
        # 拷贝会破坏签名，重签一次
        codesign --force --deep --sign "$IDENTITY" "/Applications/$APP_NAME.app" >/dev/null 2>&1 || true
        # 让 LaunchServices 重新认一遍，图标和 Spotlight 才会刷新
        /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
            -f "/Applications/$APP_NAME.app" >/dev/null 2>&1 || true
        echo "✓ 已安装到 /Applications/$APP_NAME.app"
        open "/Applications/$APP_NAME.app"
        ;;
esac
