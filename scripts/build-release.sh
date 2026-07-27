#!/bin/bash
# 正式打包：编译 + 构建 App Bundle + Developer ID 签名 + DMG
set -euo pipefail

# 日志输出到文件（同时显示在终端）
LOG_FILE="$(mktemp "${TMPDIR:-/private/tmp}/yanyun-build-release.XXXXXX")"
exec > >(tee -a "$LOG_FILE") 2>&1
echo ""
echo "[$(date '+%H:%M:%S')] 构建开始，日志: $LOG_FILE"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_DIR="$REPO_ROOT/app"
BUILD_DIR="$APP_DIR/build"
TARGETS_DIR="$APP_DIR/targets"

# 输出目录由环境变量 OUTPUT_DIR 指定，未配置则报错退出
if [ -z "${OUTPUT_DIR:-}" ]; then
    echo "❌ 未配置输出目录，请设置环境变量 OUTPUT_DIR，例如："
    echo "   OUTPUT_DIR=~/Desktop bash scripts/build-release.sh"
    exit 1
fi

# ---- 解析出包目标 ----
# 第一个位置参数为目标名（如 ywzh）；未指定则列出 targets/ 下的目录交互选择
TARGET="${1:-}"
if [ -z "$TARGET" ]; then
    echo "未指定出包目标，请选择（对应 app/targets/ 下的目录）："
    avail=()
    for d in "$TARGETS_DIR"/*/; do [ -d "$d" ] && avail+=("$(basename "$d")"); done
    if [ ${#avail[@]} -eq 0 ]; then echo "❌ $TARGETS_DIR 下没有任何 target"; exit 1; fi
    select t in "${avail[@]}"; do
        if [ -n "$t" ]; then TARGET="$t"; break; fi
    done
fi

TARGET_DIR="$TARGETS_DIR/$TARGET"
if [ ! -d "$TARGET_DIR" ]; then
    echo "❌ target 不存在: $TARGET_DIR"
    exit 1
fi
# 校验必需文件齐全
for f in config.plist Info.plist AppIcon.icns game-icon.png faq.txt; do
    if [ ! -f "$TARGET_DIR/$f" ]; then
        echo "❌ target [$TARGET] 缺少必需文件: $f"
        exit 1
    fi
done

# 产物名来自 target 配置（App / DMG / 卷名统一使用）
PRODUCT_NAME=$(/usr/libexec/PlistBuddy -c "Print :productName" "$TARGET_DIR/config.plist" 2>/dev/null || true)
if [ -z "$PRODUCT_NAME" ]; then
    echo "❌ $TARGET_DIR/config.plist 缺少 productName"
    exit 1
fi
echo "   出包目标: $TARGET  →  $PRODUCT_NAME"

APP="$OUTPUT_DIR/$PRODUCT_NAME.app"
DMG="$OUTPUT_DIR/$PRODUCT_NAME.dmg"
SIGN_ID="${SIGN_ID:-Developer ID Application}"  # 可通过环境变量覆盖，或直接填写你的签名身份
ENTITLEMENTS="$APP_DIR/Simulator/Simulator.entitlements"
STAGE="$(mktemp -d "${TMPDIR:-/private/tmp}/yanyun-dmg-stage.XXXXXX")"
DMG_BUILD_DIR=""
cleanup() {
    rm -rf "$STAGE"
    if [ -n "$DMG_BUILD_DIR" ]; then rm -rf "$DMG_BUILD_DIR"; fi
}
trap cleanup EXIT

mkdir -p "$BUILD_DIR"
mkdir -p "$OUTPUT_DIR"

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
if ! bash "$REPO_ROOT/scripts/runtime/verify-runtime.sh" "$REPO_ROOT/output/wine-release"; then
    echo "❌ wine-release 与锁定的 v0.1.1 SHA-256 基线不一致"
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
echo "  $PRODUCT_NAME - 正式打包"
echo "============================================"
echo ""

# ---- Step 1: 编译 ----
echo "=== 1. 编译 Universal Binary ==="
cd "$APP_DIR"
swiftc -O -o "$BUILD_DIR/Simulator-arm64" \
  -target arm64-apple-macosx14.0 \
  -file-prefix-map "$REPO_ROOT=." \
  SimulatorCore/*.swift Simulator/main.swift \
  -framework Cocoa -framework AppKit

swiftc -O -o "$BUILD_DIR/Simulator-x86_64" \
  -target x86_64-apple-macosx14.0 \
  -file-prefix-map "$REPO_ROOT=." \
  SimulatorCore/*.swift Simulator/main.swift \
  -framework Cocoa -framework AppKit

lipo -create "$BUILD_DIR/Simulator-arm64" "$BUILD_DIR/Simulator-x86_64" \
  -output "$BUILD_DIR/Simulator"

file "$BUILD_DIR/Simulator"

echo "=== 2. 编译 winecompat ==="
bash "$REPO_ROOT/wine/winecompat/build.sh"

echo "=== 2.1 编译 wineserverfix ==="
bash "$REPO_ROOT/wine/wineserverfix/build.sh"

# ---- Step 2: 构建 App Bundle ----
echo "=== 3. 构建 App Bundle ==="
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

cp "$BUILD_DIR/Simulator" "$APP/Contents/MacOS/Simulator"
cp "$TARGET_DIR/Info.plist" "$APP/Contents/"
cp "$TARGET_DIR/AppIcon.icns" "$APP/Contents/Resources/"
cp "$TARGET_DIR/game-icon.png" "$APP/Contents/Resources/"
cp "$TARGET_DIR/config.plist" "$APP/Contents/Resources/"
cp "$TARGET_DIR/faq.txt" "$APP/Contents/Resources/"
cp "$REPO_ROOT/runtime/components.lock.json" \
   "$APP/Contents/Resources/runtime-components.lock.json"

# LGPL 合规：将 LICENSE + THIRD_PARTY 文件打入 App bundle
cp "$REPO_ROOT/LICENSE" "$APP/Contents/Resources/"
cp "$REPO_ROOT/THIRD_PARTY.md" "$APP/Contents/Resources/"

echo "   复制 Wine 运行时..."
rsync -a "$REPO_ROOT/output/wine-release/" "$APP/Contents/Resources/wine-release/"

# 覆盖 winecompat（确保是最新编译的）
cp "$REPO_ROOT/output/wine-release/lib/wine/x86_64-unix/cxcompatdb.so" \
   "$APP/Contents/Resources/wine-release/lib/wine/x86_64-unix/cxcompatdb.so"
# 覆盖 wineserverfix（确保是最新编译的；后续 .so 签名循环会用 Wine.entitlements 签它）
cp "$REPO_ROOT/output/wine-release/lib/wine/x86_64-unix/wineserverfix.so" \
   "$APP/Contents/Resources/wine-release/lib/wine/x86_64-unix/wineserverfix.so"

# ---- Step 3: Developer ID 签名 ----
echo "=== 4. Developer ID 签名 ==="
chmod -R u+w "$APP"
# 只清除 quarantine 隔离标记（仅从互联网下载的文件才有此属性）
# Info.plist 等已签名文件会报 Operation not permitted，属于正常现象，忽略即可
find "$APP" -exec xattr -d com.apple.quarantine {} \; 2>/dev/null || true

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
bash "$REPO_ROOT/scripts/verify-signature.sh" "$APP"

# ---- Step 4: 制作 DMG（带拖拽安装提示）----
echo "=== 5. 制作 DMG ==="
rm -f "$DMG"
mkdir -p "$STAGE"
cp -a "$APP" "$STAGE/"

# LGPL 合规：DMG 根目录放一份 LICENSE，用户挂载后直接看到
# 不设 --icon 位置，让 Finder 自动排列，避免遮挡背景
cp "$REPO_ROOT/LICENSE" "$STAGE/"

# 使用 create-dmg 生成带拖拽箭头提示的安装 DMG。
# 在隔离的临时目录构建后再移动到输出位置：create-dmg 会在输出目录创建临时
# 可写镜像并由 Finder 写入窗口布局状态，隔离构建可保持输出目录整洁、布局可复现。
DMG_BUILD_DIR="$(mktemp -d "${TMPDIR:-/private/tmp}/yanyun-dmg-build.XXXXXX")"
DMG_TMP="$DMG_BUILD_DIR/$PRODUCT_NAME.dmg"

create-dmg \
  --volname "$PRODUCT_NAME" \
  --background "$SCRIPT_DIR/dmg-background.png" \
  --window-pos 200 120 \
  --window-size 660 400 \
  --icon-size 100 \
  --icon "$PRODUCT_NAME.app" 160 185 \
  --app-drop-link 500 185 \
  --no-internet-enable \
  "$DMG_TMP" "$STAGE"

mv "$DMG_TMP" "$DMG"
rm -rf "$DMG_BUILD_DIR"
DMG_BUILD_DIR=""
rm -rf "$STAGE"

# 签名 DMG
codesign --force --timestamp --sign "$SIGN_ID" "$DMG"

if [ "${NOTARIZE:-0}" = "1" ]; then
    echo "=== 5.1 Apple 公证 ==="
    bash "$REPO_ROOT/scripts/notarize-release.sh" "$DMG"
fi

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
if [ "${NOTARIZE:-0}" != "1" ]; then
    echo "提示：本次未公证。设置 NOTARIZE=1 并配置 NOTARY_PROFILE 或 App Store Connect API 密钥后可自动公证。"
fi
