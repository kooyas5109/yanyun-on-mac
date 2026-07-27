#!/bin/bash
# 日常开发测试：编译 Universal Binary + 部署到桌面 App + 启动
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_DIR="$REPO_ROOT/app"
TARGETS_DIR="$APP_DIR/targets"

# 输出目录由环境变量 OUTPUT_DIR 指定，未配置则报错退出
if [ -z "${OUTPUT_DIR:-}" ]; then
  echo "❌ 未配置输出目录，请设置环境变量 OUTPUT_DIR，例如："
  echo "   OUTPUT_DIR=~/Desktop bash scripts/dev-deploy.sh"
  exit 1
fi

# ---- 解析部署目标 ----
# 第一个位置参数为目标名（如 ywzh）；未指定则列出 targets/ 交互选择
TARGET="${1:-}"
if [ -z "$TARGET" ]; then
  echo "未指定部署目标，请选择（对应 app/targets/ 下的目录）："
  avail=()
  for d in "$TARGETS_DIR"/*/; do [ -d "$d" ] && avail+=("$(basename "$d")"); done
  if [ ${#avail[@]} -eq 0 ]; then echo "❌ $TARGETS_DIR 下没有任何 target"; exit 1; fi
  select t in "${avail[@]}"; do
    if [ -n "$t" ]; then TARGET="$t"; break; fi
  done
fi

TARGET_DIR="$TARGETS_DIR/$TARGET"
if [ ! -d "$TARGET_DIR" ]; then echo "❌ target 不存在: $TARGET_DIR"; exit 1; fi
for f in config.plist Info.plist AppIcon.icns game-icon.png faq.txt; do
  if [ ! -f "$TARGET_DIR/$f" ]; then echo "❌ target [$TARGET] 缺少必需文件: $f"; exit 1; fi
done

PRODUCT_NAME=$(/usr/libexec/PlistBuddy -c "Print :productName" "$TARGET_DIR/config.plist" 2>/dev/null || true)
if [ -z "$PRODUCT_NAME" ]; then echo "❌ $TARGET_DIR/config.plist 缺少 productName"; exit 1; fi
BUNDLE_IDENTIFIER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$TARGET_DIR/Info.plist" 2>/dev/null || true)
if [ -z "$BUNDLE_IDENTIFIER" ]; then echo "❌ $TARGET_DIR/Info.plist 缺少 CFBundleIdentifier"; exit 1; fi
echo "   部署目标: $TARGET  →  $PRODUCT_NAME"

APP="$OUTPUT_DIR/$PRODUCT_NAME.app"
BUILD_DIR="$APP_DIR/build"

mkdir -p "$BUILD_DIR"

echo "=== 1. 杀掉正在运行的实例 ==="
/usr/bin/osascript -e "tell application id \"$BUNDLE_IDENTIFIER\" to quit" 2>/dev/null || true
sleep 1

bash "$REPO_ROOT/scripts/runtime/verify-runtime.sh" "$REPO_ROOT/output/wine-release"

echo "=== 2. 编译 Universal Binary ==="
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

echo "   $(file "$BUILD_DIR/Simulator" | sed 's/.*: //')"

echo "=== 3. 编译 winecompat ==="
bash "$REPO_ROOT/wine/winecompat/build.sh"

echo "=== 3.1 编译 wineserverfix ==="
bash "$REPO_ROOT/wine/wineserverfix/build.sh"

echo "=== 4. 部署到桌面 App ==="
if [ ! -d "$APP" ]; then
  echo "错误: 桌面 App 不存在: $APP"
  echo "请先用 scripts/build-release.sh 创建完整的 App Bundle"
  exit 1
fi

cp "$BUILD_DIR/Simulator" "$APP/Contents/MacOS/Simulator"
cp "$TARGET_DIR/Info.plist" "$APP/Contents/Info.plist"
cp "$TARGET_DIR/game-icon.png" "$APP/Contents/Resources/"
cp "$TARGET_DIR/config.plist" "$APP/Contents/Resources/"
cp "$TARGET_DIR/faq.txt" "$APP/Contents/Resources/"
cp "$REPO_ROOT/runtime/components.lock.json" \
   "$APP/Contents/Resources/runtime-components.lock.json"

# LGPL 合规：更新 LICENSE + THIRD_PARTY
cp "$REPO_ROOT/LICENSE" "$APP/Contents/Resources/"
cp "$REPO_ROOT/THIRD_PARTY.md" "$APP/Contents/Resources/"
cp "$REPO_ROOT/output/wine-release/lib/wine/x86_64-unix/cxcompatdb.so" \
   "$APP/Contents/Resources/wine-release/lib/wine/x86_64-unix/cxcompatdb.so"
cp "$REPO_ROOT/output/wine-release/lib/wine/x86_64-unix/wineserverfix.so" \
   "$APP/Contents/Resources/wine-release/lib/wine/x86_64-unix/wineserverfix.so"

codesign --force -s - "$APP/Contents/MacOS/Simulator"
codesign --force -s - "$APP/Contents/Resources/wine-release/lib/wine/x86_64-unix/cxcompatdb.so"
codesign --force -s - "$APP/Contents/Resources/wine-release/lib/wine/x86_64-unix/wineserverfix.so"
codesign --force --options runtime \
  --entitlements "$APP_DIR/Simulator/Simulator.entitlements" \
  -s - "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "=== 5. 启动 ==="
open "$APP"
echo "✅ 部署运行完成"
