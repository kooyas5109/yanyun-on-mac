#!/bin/bash
set -euo pipefail

if [ "$#" -ne 1 ] || [ -z "${SOURCE_APP:-}" ]; then
  echo "Usage: SOURCE_APP=/path/to/existing.app $0 <yanyun|ywzh>" >&2
  exit 64
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_DIR="$REPO_ROOT/app"
TARGET="$1"
TARGET_DIR="$APP_DIR/targets/$TARGET"
SOURCE_APP="$(cd "$(dirname "$SOURCE_APP")" && pwd)/$(basename "$SOURCE_APP")"
SOURCE_RUNTIME="$SOURCE_APP/Contents/Resources/wine-release"
CANDIDATE_OUTPUT_DIR="${CANDIDATE_OUTPUT_DIR:-$REPO_ROOT/../yanyun-candidates}"

if [ ! -d "$TARGET_DIR" ]; then
  echo "Unknown target: $TARGET" >&2
  exit 64
fi
if [ ! -d "$SOURCE_APP/Contents" ]; then
  echo "Source application not found: $SOURCE_APP" >&2
  exit 66
fi
for file in config.plist Info.plist AppIcon.icns game-icon.png faq.txt; do
  if [ ! -f "$TARGET_DIR/$file" ]; then
    echo "Target is missing required file: $TARGET_DIR/$file" >&2
    exit 66
  fi
done

PRODUCT_NAME=$(/usr/libexec/PlistBuddy -c "Print :productName" "$TARGET_DIR/config.plist")
APP_IDENTIFIER=$(/usr/libexec/PlistBuddy -c "Print :appIdentifier" "$TARGET_DIR/config.plist")
SOURCE_APP_IDENTIFIER=$(/usr/libexec/PlistBuddy \
  -c "Print :appIdentifier" \
  "$SOURCE_APP/Contents/Resources/config.plist")
BASE_BUNDLE_IDENTIFIER=$(/usr/libexec/PlistBuddy \
  -c "Print :CFBundleIdentifier" \
  "$TARGET_DIR/Info.plist")

if [ "$APP_IDENTIFIER" != "$SOURCE_APP_IDENTIFIER" ]; then
  echo "Source runtime target mismatch: source=$SOURCE_APP_IDENTIFIER target=$APP_IDENTIFIER" >&2
  exit 65
fi

echo "Verifying source runtime without modifying it..."
bash "$SCRIPT_DIR/runtime/verify-runtime.sh" "$SOURCE_RUNTIME"

mkdir -p "$CANDIDATE_OUTPUT_DIR"
BUILD_DIR="$(mktemp -d "${TMPDIR:-/private/tmp}/yanyun-candidate-build.XXXXXX")"
STAGING_APP="$CANDIDATE_OUTPUT_DIR/.${PRODUCT_NAME}-candidate-$RANDOM.app"
CANDIDATE_APP="$CANDIDATE_OUTPUT_DIR/${PRODUCT_NAME}-候选版.app"
BACKUP_APP=""

cleanup() {
  rm -rf "$BUILD_DIR"
  if [ -d "$STAGING_APP" ]; then rm -rf "$STAGING_APP"; fi
  if [ -n "$BACKUP_APP" ] && [ -d "$BACKUP_APP" ] && [ ! -d "$CANDIDATE_APP" ]; then
    mv "$BACKUP_APP" "$CANDIDATE_APP"
  fi
}
trap cleanup EXIT

echo "Compiling Universal launcher..."
swiftc -O \
  -target arm64-apple-macosx14.0 \
  -file-prefix-map "$REPO_ROOT=." \
  "$APP_DIR"/SimulatorCore/*.swift "$APP_DIR/Simulator/main.swift" \
  -framework Cocoa -framework AppKit \
  -o "$BUILD_DIR/Simulator-arm64"
swiftc -O \
  -target x86_64-apple-macosx14.0 \
  -file-prefix-map "$REPO_ROOT=." \
  "$APP_DIR"/SimulatorCore/*.swift "$APP_DIR/Simulator/main.swift" \
  -framework Cocoa -framework AppKit \
  -o "$BUILD_DIR/Simulator-x86_64"
lipo -create \
  "$BUILD_DIR/Simulator-arm64" \
  "$BUILD_DIR/Simulator-x86_64" \
  -output "$BUILD_DIR/Simulator"

echo "Compiling native compatibility shims..."
clang -arch x86_64 -shared -O2 \
  -fvisibility=hidden \
  -finline-functions \
  -fstack-protector-all \
  -ffile-prefix-map="$REPO_ROOT/wine/winecompat=." \
  -mmacosx-version-min=10.15 \
  -install_name "win64/cxcompatdb.so" \
  -Wl,-no_compact_unwind \
  -lobjc \
  -framework CoreFoundation \
  -framework CoreGraphics \
  "$REPO_ROOT/wine/winecompat/winecompat.c" \
  -o "$BUILD_DIR/cxcompatdb.so"
clang -arch x86_64 -shared -O2 \
  -fvisibility=hidden \
  -ffile-prefix-map="$REPO_ROOT/wine/wineserverfix=." \
  -mmacosx-version-min=10.15 \
  -install_name "win64/wineserverfix.so" \
  -Wl,-no_compact_unwind \
  "$REPO_ROOT/wine/wineserverfix/wineserverfix.c" \
  -o "$BUILD_DIR/wineserverfix.so"

echo "Cloning the existing application into an isolated candidate..."
if ! cp -cR "$SOURCE_APP" "$STAGING_APP" 2>/dev/null; then
  rm -rf "$STAGING_APP"
  /usr/bin/ditto "$SOURCE_APP" "$STAGING_APP"
fi
chmod -R u+w "$STAGING_APP"
xattr -cr "$STAGING_APP"

cp "$BUILD_DIR/Simulator" "$STAGING_APP/Contents/MacOS/Simulator"
cp "$TARGET_DIR/Info.plist" "$STAGING_APP/Contents/Info.plist"
cp "$TARGET_DIR/AppIcon.icns" "$STAGING_APP/Contents/Resources/AppIcon.icns"
cp "$TARGET_DIR/game-icon.png" "$STAGING_APP/Contents/Resources/game-icon.png"
cp "$TARGET_DIR/config.plist" "$STAGING_APP/Contents/Resources/config.plist"
cp "$TARGET_DIR/faq.txt" "$STAGING_APP/Contents/Resources/faq.txt"
cp "$REPO_ROOT/LICENSE" "$STAGING_APP/Contents/Resources/LICENSE"
cp "$REPO_ROOT/THIRD_PARTY.md" "$STAGING_APP/Contents/Resources/THIRD_PARTY.md"
cp "$REPO_ROOT/runtime/components.lock.json" \
  "$STAGING_APP/Contents/Resources/runtime-components.lock.json"
cp "$BUILD_DIR/cxcompatdb.so" \
  "$STAGING_APP/Contents/Resources/wine-release/lib/wine/x86_64-unix/cxcompatdb.so"
cp "$BUILD_DIR/wineserverfix.so" \
  "$STAGING_APP/Contents/Resources/wine-release/lib/wine/x86_64-unix/wineserverfix.so"

/usr/libexec/PlistBuddy \
  -c "Set :CFBundleIdentifier ${BASE_BUNDLE_IDENTIFIER}.candidate" \
  "$STAGING_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy \
  -c "Set :CFBundleDisplayName ${PRODUCT_NAME}（候选版）" \
  "$STAGING_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy \
  -c "Set :CFBundleName ${PRODUCT_NAME}-候选版" \
  "$STAGING_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy \
  -c "Add :YanyunCandidateCommit string $(git -C "$REPO_ROOT" rev-parse --short HEAD)" \
  "$STAGING_APP/Contents/Info.plist"

echo "Applying local ad-hoc signatures..."
WINE_DIR="$STAGING_APP/Contents/Resources/wine-release"
WINE_ENTITLEMENTS="$APP_DIR/Simulator/Wine.entitlements"
while IFS= read -r -d '' file; do
  if file "$file" | grep -q "Mach-O"; then
    codesign --force --options runtime \
      --entitlements "$WINE_ENTITLEMENTS" \
      --sign - "$file"
  fi
done < <(find "$WINE_DIR" -type f \( -name "*.dylib" -o -name "*.so" \) -print0)

WINE_STUB="$WINE_DIR/bin/wine"
while IFS= read -r -d '' file; do
  if [ -x "$file" ] &&
     [[ "$file" != *.so ]] &&
     [[ "$file" != *.dylib ]] &&
     file "$file" | grep -q "Mach-O"; then
    if [ "$file" = "$WINE_STUB" ]; then
      codesign --force --options runtime --sign - "$file"
    else
      codesign --force --options runtime \
        --entitlements "$WINE_ENTITLEMENTS" \
        --sign - "$file"
    fi
  fi
done < <(find "$WINE_DIR" -type f -print0)

codesign --force --options runtime \
  --entitlements "$APP_DIR/Simulator/Simulator.entitlements" \
  --sign - "$STAGING_APP/Contents/MacOS/Simulator"
codesign --force --options runtime \
  --entitlements "$APP_DIR/Simulator/Simulator.entitlements" \
  --sign - "$STAGING_APP"
codesign --verify --deep --strict --verbose=2 "$STAGING_APP"

if [ -e "$CANDIDATE_APP" ]; then
  BACKUP_APP="$CANDIDATE_OUTPUT_DIR/.${PRODUCT_NAME}-candidate-backup-$RANDOM.app"
  mv "$CANDIDATE_APP" "$BACKUP_APP"
fi
mv "$STAGING_APP" "$CANDIDATE_APP"
STAGING_APP=""
if [ -n "$BACKUP_APP" ]; then
  rm -rf "$BACKUP_APP"
  BACKUP_APP=""
fi

trap - EXIT
rm -rf "$BUILD_DIR"

echo
echo "Candidate created without launching it:"
echo "  $CANDIDATE_APP"
echo "  bundle id: ${BASE_BUNDLE_IDENTIFIER}.candidate"
echo "  data id:   $APP_IDENTIFIER"
echo "The source app and user game data were not modified."
