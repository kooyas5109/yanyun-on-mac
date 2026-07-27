#!/bin/bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "Usage: $0 <verified-wine-release-directory>" >&2
  exit 64
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SOURCE_DIR="$(cd "$1" && pwd)"
DESTINATION="$REPO_ROOT/output/wine-release"
mkdir -p "$REPO_ROOT/output"
STAGING="$(mktemp -d "$REPO_ROOT/output/.wine-release-staging.XXXXXX")"
BACKUP=""

cleanup() {
  if [ -n "$STAGING" ]; then rm -rf "$STAGING"; fi
  if [ -n "$BACKUP" ] && [ -d "$BACKUP" ] && [ ! -d "$DESTINATION" ]; then
    mv "$BACKUP" "$DESTINATION"
  fi
}
trap cleanup EXIT

bash "$SCRIPT_DIR/verify-runtime.sh" "$SOURCE_DIR"
rsync -a "$SOURCE_DIR/" "$STAGING/"
bash "$SCRIPT_DIR/verify-runtime.sh" "$STAGING"

if [ -e "$DESTINATION" ]; then
  BACKUP="$(mktemp -d "$REPO_ROOT/output/.wine-release-backup.XXXXXX")"
  rmdir "$BACKUP"
  mv "$DESTINATION" "$BACKUP"
fi
mv "$STAGING" "$DESTINATION"
STAGING=""

if [ -n "$BACKUP" ]; then
  rm -rf "$BACKUP"
  BACKUP=""
fi
trap - EXIT
echo "Prepared verified runtime: $DESTINATION"
