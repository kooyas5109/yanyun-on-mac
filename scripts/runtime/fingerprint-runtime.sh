#!/bin/bash
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "Usage: $0 <wine-release-directory> <output.sha256>" >&2
  exit 64
fi

RUNTIME_DIR="$(cd "$1" && pwd)"
OUTPUT_FILE="$2"
TEMP_FILE="$(mktemp "${TMPDIR:-/private/tmp}/yanyun-runtime-fingerprint.XXXXXX")"
trap 'rm -f "$TEMP_FILE"' EXIT

if [ ! -f "$RUNTIME_DIR/bin/wineserver" ] ||
   [ ! -f "$RUNTIME_DIR/lib/wine/x86_64-unix/wine" ]; then
  echo "Not a complete wine-release directory: $RUNTIME_DIR" >&2
  exit 65
fi

UNSUPPORTED_ENTRY="$(find "$RUNTIME_DIR" -mindepth 1 ! -type d ! -type f -print -quit)"
if [ -n "$UNSUPPORTED_ENTRY" ]; then
  echo "Runtime contains a symlink or unsupported entry: $UNSUPPORTED_ENTRY" >&2
  exit 65
fi

(
  cd "$RUNTIME_DIR"
  # cxcompatdb.so and wineserverfix.so are project-owned shims rebuilt from the
  # checked-in C sources. They are validated by CI, not by the upstream runtime baseline.
  find . -type f \
    ! -path './lib/wine/x86_64-unix/cxcompatdb.so' \
    ! -path './lib/wine/x86_64-unix/wineserverfix.so' \
    -print0 |
    LC_ALL=C sort -z |
    xargs -0 shasum -a 256
) > "$TEMP_FILE"

mkdir -p "$(dirname "$OUTPUT_FILE")"
mv "$TEMP_FILE" "$OUTPUT_FILE"
trap - EXIT
