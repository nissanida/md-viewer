#!/bin/bash
# Builds the download for a GitHub release, MD-Viewer-<version>.zip, from the
# committed code (HEAD) rather than this folder, so files kept only in the
# owner's copy, such as the Claude symbol (D-014), never ship. Prints the zip's
# SHA-256 for the release notes. Publishing it is a separate step (STATUS.md).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-$HOME/Library/Caches/md_html_reader}/release-zip"
VERSION="${VERSION:-0.1.0}"
SOURCE="$BUILD_DIR/source"
APP="$BUILD_DIR/dist/MD Viewer.app"
ZIP="$BUILD_DIR/MD-Viewer-$VERSION.zip"

if [[ -n "$(git -C "$ROOT" status --porcelain --untracked-files=no)" ]]; then
  echo "Commit your changes first: the zip is built from HEAD." >&2
  exit 1
fi
if [[ "$(git -C "$ROOT" rev-parse HEAD)" != "$(git -C "$ROOT" rev-parse '@{upstream}' 2>/dev/null)" ]]; then
  echo "Note: HEAD isn't pushed yet; push it before publishing the release." >&2
fi

echo "==> Exporting $(git -C "$ROOT" rev-parse --short HEAD) to $SOURCE"
rm -rf "$SOURCE"
mkdir -p "$SOURCE"
git -C "$ROOT" archive HEAD | tar -x -C "$SOURCE"

BUILD_DIR="$BUILD_DIR" VERSION="$VERSION" "$SOURCE/scripts/build-app.sh"

if [[ -e "$APP/Contents/Resources/web/claude-symbol.svg" ]]; then
  echo "The Claude symbol is in the app, and it must not ship (D-014)." >&2
  exit 1
fi
if grep -r -a -q -F "$HOME" "$APP"; then
  echo "The app contains a path from this Mac ($HOME), which would publish your user name." >&2
  exit 1
fi
codesign --verify --deep --strict "$APP"

rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "==> Built $ZIP"
shasum -a 256 "$ZIP"
