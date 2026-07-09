#!/bin/bash
# 编译 wineserverfix.c → output/wine-release/lib/wine/x86_64-unix/wineserverfix.so
# 通过 DYLD_INSERT_LIBRARIES 注入 wineserver，修复发烧平台下载 IPC 死锁
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
OUTPUT_DIR="$REPO_ROOT/output"
SRC="$SCRIPT_DIR/wineserverfix.c"
OUT="$OUTPUT_DIR/wine-release/lib/wine/x86_64-unix/wineserverfix.so"

if [ ! -d "$OUTPUT_DIR/wine-release/lib/wine/x86_64-unix" ]; then
  echo "错误: output/wine-release/ 不存在，请先准备 Wine 运行时"
  exit 1
fi

# 是否为 DEBUG 构建
DEBUG_FLAG=""
if [ "$1" = "--debug" ]; then
  DEBUG_FLAG="-DDEBUG"
  echo "=== 编译 wineserverfix (DEBUG) ==="
else
  echo "=== 编译 wineserverfix (RELEASE) ==="
fi

echo "源码: $SRC"
echo "输出: $OUT"

# 只链 libSystem（无 Foundation 依赖），保持极小体积
arch -x86_64 clang -arch x86_64 \
    -shared -o "$OUT" \
    -O2 \
    -fvisibility=hidden \
    -ffile-prefix-map="$SCRIPT_DIR"=. \
    -mmacosx-version-min=10.15 \
    -install_name "win64/wineserverfix.so" \
    -Wl,-no_compact_unwind \
    $DEBUG_FLAG \
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

if [ -n "$DEBUG_FLAG" ]; then
  WSFIX_STR=$(strings "$OUT" | grep "\[wsfix\]" || true)
  if [ -n "$WSFIX_STR" ]; then
    echo "✅ DEBUG 构建: 调试字符串存在 (预期行为)"
  else
    echo "⚠️  DEBUG 构建: 未找到调试字符串"
  fi
else
  WSFIX_STR=$(strings "$OUT" | grep "\[wsfix\]" || true)
  if [ -n "$WSFIX_STR" ]; then
    echo "❌ RELEASE 构建中发现调试字符串:"
    echo "$WSFIX_STR"
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
