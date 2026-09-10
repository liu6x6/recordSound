#!/bin/bash
# VoiceScribe Release 构建 + DMG 打包（+ 可选公证）
# 用法:
#   ./scripts/release.sh              # Release 构建 + DMG
#   NOTARIZE=1 ./scripts/release.sh   # 构建 + DMG + 公证（需 Developer ID 证书与 App Store Connect API Key）
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="VoiceScribe"
VERSION=$(grep 'MARKETING_VERSION' project.yml | head -1 | sed -E 's/.*"([^"]+)".*/\1/')
DIST_DIR="dist"
APP_PATH="$DIST_DIR/$APP_NAME.app"
DMG_PATH="$DIST_DIR/$APP_NAME-$VERSION.dmg"

echo "==> 版本: $VERSION"

# 1. 生成工程 + Release 构建
echo "==> 构建 Release…"
xcodegen generate
rm -rf "$DIST_DIR/build"
xcodebuild -project "$APP_NAME.xcodeproj" -scheme "$APP_NAME" \
  -configuration Release \
  -derivedDataPath "$DIST_DIR/build" \
  -clonedSourcePackagesDirPath "build/SourcePackages" \
  build

BUILT_APP="$DIST_DIR/build/Build/Products/Release/$APP_NAME.app"
[ -d "$BUILT_APP" ] || { echo "构建产物不存在: $BUILT_APP"; exit 1; }

rm -rf "$APP_PATH"
cp -R "$BUILT_APP" "$APP_PATH"

# 2. 检查签名（如有 Developer ID 证书则重签，否则保持 Apple Development）
DEV_ID=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | sed -E 's/.*"(.*)".*/\1/' || true)
if [ -n "${DEV_ID:-}" ]; then
  echo "==> 使用 Developer ID 重签: $DEV_ID"
  codesign --force --options runtime --timestamp \
    --sign "$DEV_ID" "$APP_PATH"
else
  echo "⚠️  未找到 Developer ID 证书，保持当前签名（仅本机/开发测试用，无法公证分发）"
fi
codesign --verify --deep --strict "$APP_PATH" && echo "==> 签名验证通过"

# 3. 公证（可选）
if [ "${NOTARIZE:-0}" = "1" ]; then
  if [ -z "${DEV_ID:-}" ]; then echo "公证需要 Developer ID 证书"; exit 1; fi
  echo "==> 提交公证…"
  ditto -c -k --keepParent "$APP_PATH" "$DIST_DIR/notarize.zip"
  xcrun notarytool submit "$DIST_DIR/notarize.zip" --keychain-profile "voicescribe-notary" --wait
  xcrun stapler staple "$APP_PATH"
  rm "$DIST_DIR/notarize.zip"
  echo "==> 公证完成并已 staple"
fi

# 4. 打包 DMG
echo "==> 生成 DMG…"
rm -f "$DMG_PATH"
STAGING="$DIST_DIR/dmg-staging"
rm -rf "$STAGING" && mkdir -p "$STAGING"
cp -R "$APP_PATH" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -ov -format UDZO "$DMG_PATH" -quiet
rm -rf "$STAGING"

echo ""
echo "✅ 完成: $DMG_PATH"
ls -lh "$DMG_PATH"
