#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RUNTIME_DIR="${1:-$REPO_ROOT/output/wine-release}"
BASELINE="${2:-$REPO_ROOT/runtime/baselines/v0.1.1.sha256}"
ACTUAL="$(mktemp "${TMPDIR:-/private/tmp}/yanyun-runtime-verify.XXXXXX")"
trap 'rm -f "$ACTUAL"' EXIT

if [ ! -f "$BASELINE" ]; then
  echo "Runtime baseline not found: $BASELINE" >&2
  exit 66
fi

bash "$SCRIPT_DIR/fingerprint-runtime.sh" "$RUNTIME_DIR" "$ACTUAL"
if ! cmp -s "$BASELINE" "$ACTUAL"; then
  echo "Runtime does not match the locked baseline: $BASELINE" >&2
  diff -u "$BASELINE" "$ACTUAL" | sed -n '1,120p' >&2 || true
  exit 1
fi

echo "Runtime verified: $(wc -l < "$ACTUAL" | tr -d ' ') files"
