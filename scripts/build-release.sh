#!/bin/bash
# 正式打包：编译 + 构建 App Bundle + Developer ID 签名 + DMG
set -e

# 日志输出到文件（同时显示在终端）
LOG_FILE="/tmp/build-release.log"
exec > >(tee -a "$LOG_FILE") 2>&1
echo ""
echo "[$(date '+%H:%M:%S')] 构建开始，日志: $LOG_FILE"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_DIR="$REPO_ROOT/app"
BUILD_DIR="$APP_DIR/build"
APP="$HOME/Desktop/Yanyun.app"
DMG="$HOME/Desktop/Yanyun.dmg"
SIGN_ID="${SIGN_ID:-Developer ID Application}"  # 可通过环境变量覆盖，或直接填写你的签名身份
ENTITLEMENTS="$APP_DIR/Simulator/Simulator.entitlements"
STAGE="/tmp/dmg-stage"

mkdir -p "$BUILD_DIR"

# ---- 前置检查 ----
echo "=== 0. 前置检查 ==="

# 检查签名身份是否存在
if ! security find-identity -v -p codesigning | grep -q "$SIGN_ID"; then
    echo ""
    echo "❌ 未找到签名身份: $SIGN_ID"
    echo ""
    echo "   请通过以下方式指定："
    echo "   SIGN_ID=\"Developer ID Application: Your Name (TEAMID)\" bash scripts/build-release.sh"
    echo ""
    echo "   可用的签名身份："
    security find-identity -v -p codesigning | grep "Developer ID" | sed 's/^/   /'
    exit 1
fi
echo "   签名身份: $SIGN_ID ✅"

# 检查 wine-release 是否存在
if [ ! -d "$REPO_ROOT/output/wine-release" ]; then
    echo "❌ output/wine-release 不存在"
    echo "   请先准备 Wine 运行时（从 Releases 页面下载 wine-release.tar.gz 并解压到 output/）"
    exit 1
fi
echo "   wine-release: ✅"

# 检查 create-dmg 是否安装
if ! command -v create-dmg &>/dev/null; then
    echo "❌ create-dmg 未安装"
    echo "   请执行: brew install create-dmg"
    exit 1
fi
echo "   create-dmg: ✅"
echo ""

echo "============================================"
echo "  燕云模拟器 - 正式打包"
echo "============================================"
echo ""

# ---- Step 1: 编译 ----
echo "=== 1. 编译 Universal Binary ==="
cd "$APP_DIR"
swiftc -O -o "$BUILD_DIR/Simulator-arm64" \
  -target arm64-apple-macosx14.0 \
  Simulator/main.swift \
  -framework Cocoa -framework AppKit

swiftc -O -o "$BUILD_DIR/Simulator-x86_64" \
  -target x86_64-apple-macosx14.0 \
  Simulator/main.swift \
  -framework Cocoa -framework AppKit

lipo -create "$BUILD_DIR/Simulator-arm64" "$BUILD_DIR/Simulator-x86_64" \
  -output "$BUILD_DIR/Simulator"

file "$BUILD_DIR/Simulator"

echo "=== 2. 编译 winecompat ==="
bash "$REPO_ROOT/wine/winecompat/build.sh"

# ---- Step 2: 构建 App Bundle ----
echo "=== 3. 构建 App Bundle ==="
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

cp "$BUILD_DIR/Simulator" "$APP/Contents/MacOS/Simulator"
cp "$APP_DIR/Simulator/Info.plist" "$APP/Contents/"
cp "$APP_DIR/Simulator/AppIcon.icns" "$APP/Contents/Resources/"
cp "$APP_DIR/Simulator/logo.png" "$APP/Contents/Resources/"

# LGPL 合规：将 LICENSE + THIRD_PARTY 文件打入 App bundle
cp "$REPO_ROOT/LICENSE" "$APP/Contents/Resources/"
cp "$REPO_ROOT/THIRD_PARTY.md" "$APP/Contents/Resources/"

echo "   复制 Wine 运行时..."
rsync -a "$REPO_ROOT/output/wine-release/" "$APP/Contents/Resources/wine-release/"

# 覆盖 winecompat（确保是最新编译的）
cp "$REPO_ROOT/output/wine-release/lib/wine/x86_64-unix/cxcompatdb.so" \
   "$APP/Contents/Resources/wine-release/lib/wine/x86_64-unix/cxcompatdb.so"

# ---- Step 3: Developer ID 签名 ----
echo "=== 4. Developer ID 签名 ==="
chmod -R u+w "$APP"
# 只清除 quarantine 隔离标记（仅从互联网下载的文件才有此属性）
# Info.plist 等已签名文件会报 Operation not permitted，属于正常现象，忽略即可
find "$APP" -exec xattr -d com.apple.quarantine {} \; 2>/dev/null || true

# 先解锁钥匙串（避免弹窗）
security unlock-keychain ~/Library/Keychains/login.keychain-db 2>/dev/null || true

WINE_ENTITLEMENTS="$APP_DIR/Simulator/Wine.entitlements"

echo "   签名 .so/.dylib（wine 模块带 Wine.entitlements）..."
find "$APP/Contents/Resources/wine-release" -type f \( -name "*.dylib" -o -name "*.so" \) \
  -exec codesign --force --timestamp --options runtime --entitlements "$WINE_ENTITLEMENTS" --sign "$SIGN_ID" {} \; 2>/dev/null

echo "   签名可执行文件（wine 可执行带 Wine.entitlements）..."
# wine（非 wineloader）是 stub 二进制，无法附加 entitlements，显式跳过
WINE_STUB="$APP/Contents/Resources/wine-release/bin/wine"
find "$APP/Contents/Resources/wine-release" -type f -perm +111 -not -name "*.so" -not -name "*.dylib" | while read f; do
  file "$f" | grep -q "Mach-O" || continue
  if [ "$f" = "$WINE_STUB" ]; then
    # stub 二进制：不带 entitlements 签名，避免格式不兼容错误
    codesign --force --timestamp --options runtime --sign "$SIGN_ID" "$f"
    echo "      ✓ $(basename $f) (stub, no entitlements)"
    continue
  fi
  codesign --force --timestamp --options runtime --entitlements "$WINE_ENTITLEMENTS" --sign "$SIGN_ID" "$f"
  echo "      ✓ $(basename $f)"
done

echo "   签名主 App（不用 --deep，避免覆盖 Wine 签名）..."
codesign --force --options runtime --timestamp \
  --entitlements "$ENTITLEMENTS" \
  --sign "$SIGN_ID" "$APP"

# 验证
echo "   验证签名..."
codesign -dv "$APP" 2>&1 | grep -E "Authority|TeamIdentifier"
echo "   验证 wineserver entitlements..."
codesign -d --entitlements - "$APP/Contents/Resources/wine-release/bin/wineserver" 2>/dev/null | grep -o "allow-jit\|allow-dyld\|allow-unsigned" | head -5

# ---- Step 4: 制作 DMG（带拖拽安装提示）----
echo "=== 5. 制作 DMG ==="
rm -f "$DMG"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -a "$APP" "$STAGE/"

# LGPL 合规：DMG 根目录放一份 LICENSE，用户挂载后直接看到
# 不设 --icon 位置，让 Finder 自动排列，避免遮挡背景
cp "$REPO_ROOT/LICENSE" "$STAGE/"

# 使用 create-dmg 生成带拖拽箭头提示的安装 DMG
create-dmg \
  --volname "Yanyun" \
  --background "$SCRIPT_DIR/dmg-background.png" \
  --window-pos 200 120 \
  --window-size 660 400 \
  --icon-size 100 \
  --icon "Yanyun.app" 160 185 \
  --app-drop-link 500 185 \
  --no-internet-enable \
  "$DMG" "$STAGE"

rm -rf "$STAGE"

# 签名 DMG
codesign --force --timestamp --sign "$SIGN_ID" "$DMG"

# ---- Step 5: 验证 ----
echo ""
echo "=== 6. 最终验证 ==="
echo "App 签名:"
codesign -dv "$APP" 2>&1 | grep -E "Authority|TeamIdentifier"
echo ""
echo "DMG 签名:"
codesign -dv "$DMG" 2>&1 | grep -E "Authority|TeamIdentifier" || echo "  (无签名信息)"
echo ""

echo ""
echo "============================================"
echo "✅ 打包完成"
echo "   App: $APP"
echo "   DMG: $DMG ($(du -h "$DMG" | awk '{print $1}'))"
echo "============================================"
echo ""
echo "下一步（可选）："
echo "  # Apple 公证（需要 Apple ID 和 App 专用密码）"
echo "  xcrun notarytool submit '$DMG' --apple-id <your-apple-id> --team-id <team-id> --password <app-specific-password> --wait"
echo "  xcrun stapler staple '$DMG'"
