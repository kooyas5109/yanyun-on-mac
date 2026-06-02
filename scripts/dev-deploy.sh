#!/bin/bash
# 日常开发测试：编译 Universal Binary + 部署到桌面 App + 启动
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_DIR="$REPO_ROOT/app"
APP="$HOME/Desktop/Yanyun.app"
BUILD_DIR="$APP_DIR/build"

mkdir -p "$BUILD_DIR"

echo "=== 1. 杀掉正在运行的实例 ==="
pkill -9 -f Simulator 2>/dev/null || true
sleep 1

echo "=== 2. 编译 Universal Binary ==="
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

echo "   $(file "$BUILD_DIR/Simulator" | sed 's/.*: //')"

echo "=== 3. 编译 winecompat ==="
bash "$REPO_ROOT/wine/winecompat/build.sh"

echo "=== 4. 部署到桌面 App ==="
if [ ! -d "$APP" ]; then
  echo "错误: 桌面 App 不存在: $APP"
  echo "请先用 scripts/build-release.sh 创建完整的 App Bundle"
  exit 1
fi

cp "$BUILD_DIR/Simulator" "$APP/Contents/MacOS/Simulator"
cp "$APP_DIR/Simulator/Info.plist" "$APP/Contents/Info.plist"
cp "$APP_DIR/Simulator/logo.png" "$APP/Contents/Resources/"

# LGPL 合规：更新 LICENSE + THIRD_PARTY
cp "$REPO_ROOT/LICENSE" "$APP/Contents/Resources/"
cp "$REPO_ROOT/THIRD_PARTY.md" "$APP/Contents/Resources/"
cp "$REPO_ROOT/output/wine-release/lib/wine/x86_64-unix/cxcompatdb.so" \
   "$APP/Contents/Resources/wine-release/lib/wine/x86_64-unix/cxcompatdb.so"

codesign --force -s - "$APP/Contents/MacOS/Simulator"
codesign --force -s - "$APP/Contents/Resources/wine-release/lib/wine/x86_64-unix/cxcompatdb.so"

echo "=== 5. 启动 ==="
open "$APP"
echo "✅ 部署运行完成"
