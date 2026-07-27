#!/bin/bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "Usage: $0 <application.app>" >&2
  exit 64
fi

APP="$1"
if [ ! -d "$APP/Contents" ]; then
  echo "Application bundle not found: $APP" >&2
  exit 66
fi

codesign --verify --deep --strict --verbose=2 "$APP"
DETAILS="$(codesign -dvv "$APP" 2>&1)"
if ! grep -q "flags=.*runtime" <<<"$DETAILS"; then
  echo "Main application signature does not enable hardened runtime" >&2
  exit 1
fi

while IFS= read -r -d '' file; do
  if file "$file" | grep -q "Mach-O"; then
    codesign --verify --strict --verbose=1 "$file"
  fi
done < <(find "$APP/Contents" -type f -print0)

WINE_ENTITLEMENT_TARGET="$APP/Contents/Resources/wine-release/bin/wineserver"
if [ -f "$WINE_ENTITLEMENT_TARGET" ]; then
  ENTITLEMENTS="$(codesign -d --entitlements - "$WINE_ENTITLEMENT_TARGET" 2>/dev/null)"
  for key in \
    com.apple.security.cs.allow-jit \
    com.apple.security.cs.allow-unsigned-executable-memory \
    com.apple.security.cs.disable-library-validation; do
    if ! grep -q "$key" <<<"$ENTITLEMENTS"; then
      echo "Missing Wine entitlement on wineserver: $key" >&2
      exit 1
    fi
  done
fi

echo "Signature and hardened-runtime checks passed: $APP"
