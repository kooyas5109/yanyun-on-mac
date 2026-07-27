#!/bin/bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "Usage: $0 <signed-dmg>" >&2
  exit 64
fi

ARTIFACT="$1"
if [ ! -e "$ARTIFACT" ]; then
  echo "Artifact not found: $ARTIFACT" >&2
  exit 66
fi
if [ "${ARTIFACT##*.}" != "dmg" ]; then
  echo "This release flow notarizes a signed DMG" >&2
  exit 65
fi

codesign --verify --strict --verbose=2 "$ARTIFACT"

if [ -n "${NOTARY_PROFILE:-}" ]; then
  xcrun notarytool submit "$ARTIFACT" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait
elif [ -n "${APPLE_API_KEY_PATH:-}" ] &&
     [ -n "${APPLE_API_KEY_ID:-}" ] &&
     [ -n "${APPLE_API_ISSUER_ID:-}" ]; then
  xcrun notarytool submit "$ARTIFACT" \
    --key "$APPLE_API_KEY_PATH" \
    --key-id "$APPLE_API_KEY_ID" \
    --issuer "$APPLE_API_ISSUER_ID" \
    --wait
else
  echo "Configure NOTARY_PROFILE or APPLE_API_KEY_PATH/APPLE_API_KEY_ID/APPLE_API_ISSUER_ID" >&2
  exit 78
fi

xcrun stapler staple "$ARTIFACT"
xcrun stapler validate "$ARTIFACT"
echo "Notarization accepted and ticket stapled: $ARTIFACT"
