#!/bin/bash
# 出一个可分发的 DMG：拖进 Applications 就装好。
#
#   scripts/make_dmg.sh
#   产物：dist/DesktopPet-<版本>-arm64.dmg
#
# **未签名 / 未公证**。用户第一次打开会被 Gatekeeper 拦（"已损坏"或"无法验证
# 开发者"），解法写在 README 的安装一节里——这是开源 macOS 应用的常态，
# 要去掉这一步需要 Apple Developer Program 的 Developer ID 证书和公证流程。
# 有证书的话：PET_SIGN_IDENTITY="Developer ID Application: …" scripts/make_dmg.sh

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="${PET_APP_NAME:-DesktopPet}"
VERSION="$(cat "$ROOT/VERSION")"
ARCH="$(uname -m)"
DIST="$ROOT/dist"
DMG="$DIST/$APP_NAME-$VERSION-$ARCH.dmg"
# 装配目录：DMG 的内容就是这个文件夹的快照。
STAGE="$(mktemp -d)/$APP_NAME"

bash "$ROOT/scripts/make_app.sh" >/dev/null
APP="${PET_STAGE:-/tmp/desktop-pet-stage}/$APP_NAME.app"
[ -d "$APP" ] || { echo "没找到 $APP"; exit 1; }

mkdir -p "$STAGE" "$DIST"
cp -R "$APP" "$STAGE/"
# 一个指向 /Applications 的软链，用户把图标拖过去就装好了——DMG 的标准做法。
ln -s /Applications "$STAGE/Applications"
cp "$ROOT/README.md" "$STAGE/使用说明.md" 2>/dev/null || true

rm -f "$DMG"
hdiutil create -volname "$APP_NAME $VERSION" \
    -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null

# DMG 本身也签一下：没签的磁盘映像在某些配置下会被直接拒绝挂载。
codesign --force --sign "${PET_SIGN_IDENTITY:--}" "$DMG" 2>/dev/null || true

rm -rf "$(dirname "$STAGE")"
echo "✓ $DMG"
shasum -a 256 "$DMG"
