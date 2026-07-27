#!/bin/bash
set -euo pipefail

DXMT_REVISION="589adb780354b461645b29999cefaf533594ee99"

if [ "$#" -ne 2 ] ||
   [ -z "${NATIVE_LLVM_PATH:-}" ] ||
   [ -z "${WINE_BUILD_PATH:-}" ]; then
  echo "Usage: NATIVE_LLVM_PATH=/path WINE_BUILD_PATH=/path $0 <dxmt-checkout> <output-directory>" >&2
  exit 64
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SOURCE_REPO="$(cd "$1" && pwd)"
OUTPUT_DIR="$2"
WORK_DIR="$(mktemp -d "${TMPDIR:-/private/tmp}/yanyun-dxmt-build.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

git -C "$SOURCE_REPO" cat-file -e "$DXMT_REVISION^{commit}"
git clone --quiet --no-hardlinks "$SOURCE_REPO" "$WORK_DIR/source"
git -C "$WORK_DIR/source" checkout --quiet --detach "$DXMT_REVISION"
git -C "$WORK_DIR/source" apply --check "$REPO_ROOT/runtime/patches/dxmt/0001-safe-resource-common-gettype.patch"
git -C "$WORK_DIR/source" apply "$REPO_ROOT/runtime/patches/dxmt/0001-safe-resource-common-gettype.patch"

pushd "$WORK_DIR/source" >/dev/null
meson setup \
  --cross-file build-win64.txt \
  -Dnative_llvm_path="$NATIVE_LLVM_PATH" \
  -Dwine_build_path="$WINE_BUILD_PATH" \
  build \
  --buildtype release
meson compile -C build
popd >/dev/null

mkdir -p "$OUTPUT_DIR"
for component in d3d11.dll d3d10core.dll dxgi.dll; do
  artifact="$(find "$WORK_DIR/source/build" -type f -name "$component" -print -quit)"
  if [ -z "$artifact" ]; then
    echo "DXMT build did not produce $component" >&2
    exit 1
  fi
  cp "$artifact" "$OUTPUT_DIR/$component"
done

(
  cd "$OUTPUT_DIR"
  shasum -a 256 d3d11.dll d3d10core.dll dxgi.dll > SHA256SUMS
)
echo "DXMT $DXMT_REVISION built with the locked source patch: $OUTPUT_DIR"
