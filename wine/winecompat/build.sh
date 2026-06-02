#!/bin/bash
# 编译 winecompat.c → output/wine-release/lib/wine/x86_64-unix/cxcompatdb.so
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
OUTPUT_DIR="$REPO_ROOT/output"
SRC="$SCRIPT_DIR/winecompat.c"
OUT="$OUTPUT_DIR/wine-release/lib/wine/x86_64-unix/cxcompatdb.so"

if [ ! -d "$OUTPUT_DIR/wine-release/lib/wine/x86_64-unix" ]; then
  echo "错误: output/wine-release/ 不存在，请先准备 Wine 运行时"
  exit 1
fi

# 是否为 DEBUG 构建
DEBUG_FLAG=""
if [ "$1" = "--debug" ]; then
  DEBUG_FLAG="-DDEBUG"
  echo "=== 编译 winecompat (DEBUG) ==="
else
  echo "=== 编译 winecompat (RELEASE) ==="
fi

echo "源码: $SRC"
echo "输出: $OUT"

arch -x86_64 clang -arch x86_64 \
    -shared -o "$OUT" \
    -O2 \
    -fvisibility=hidden \
    -finline-functions \
    -fstack-protector-all \
    -ffile-prefix-map="$SCRIPT_DIR"=. \
    -mmacosx-version-min=10.15 \
    -install_name "win64/cxcompatdb.so" \
    -Wl,-no_compact_unwind \
    $DEBUG_FLAG \
    -lobjc \
    -framework CoreFoundation \
    -framework CoreGraphics \
    "$SRC"

strip -x "$OUT"
xattr -d com.apple.quarantine "$OUT" 2>/dev/null || true
codesign --force -s - "$OUT"

echo "=== 编译完成 ==="
ls -la "$OUT"

# === 发布检查 ===
echo ""
echo "=== 发布检查 ==="

FAIL=0

# DEBUG 模式下检查调试字符串是否存在
if [ -n "$DEBUG_FLAG" ]; then
  COMPAT_STR=$(strings "$OUT" | grep "\[compat\]" || true)
  if [ -n "$COMPAT_STR" ]; then
    echo "✅ DEBUG 构建: 调试字符串存在 (预期行为)"
  else
    echo "⚠️  DEBUG 构建: 未找到调试字符串"
  fi
else
  # RELEASE 模式下确认无调试输出
  COMPAT_STR=$(strings "$OUT" | grep "\[compat\]" || true)
  if [ -n "$COMPAT_STR" ]; then
    echo "❌ RELEASE 构建中发现调试字符串:"
    echo "$COMPAT_STR"
    FAIL=1
  else
    echo "✅ RELEASE 构建: 无调试字符串"
  fi
fi

if [ "$FAIL" -ne 0 ]; then
  echo ""
  echo "❌ 发布检查未通过"
  exit 1
fi

echo ""
echo "✅ 发布检查通过"
