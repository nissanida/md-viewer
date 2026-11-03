#!/bin/bash
# Builds "MD Viewer.app": compiles the Swift code (for each architecture in
# ARCHS, merged into one universal binary), then assembles the app bundle with
# its Info.plist, web assets, icon and command-line helper, and signs it ad hoc.
#
# Everything is built in BUILD_DIR, outside iCloud Drive: iCloud would sync the
# build files and tag them with metadata that code signing rejects.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-$HOME/Library/Caches/md_html_reader}"
ARCHS="${ARCHS:-arm64 x86_64}"
VERSION="${VERSION:-0.1.1}"
APP="$BUILD_DIR/dist/MD Viewer.app"

binaries=()
for arch in $ARCHS; do
  echo "==> Compiling for $arch"
  # One build folder per architecture: SwiftPM can't switch targets within one.
  args=(-c release --package-path "$ROOT" --scratch-path "$BUILD_DIR/release-$arch" --triple "$arch-apple-macosx14.0")
  swift build "${args[@]}"
  binaries+=("$(swift build "${args[@]}" --show-bin-path)/MDViewer")
done

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create "${binaries[@]}" -output "$APP/Contents/MacOS/MDViewer"
# Drop the debug map: it lists the folders the app was built in, which include
# the builder's user name. Function names stay, so crash reports still read.
strip -S "$APP/Contents/MacOS/MDViewer"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$(date +%Y%m%d%H%M)/" \
  "$ROOT/packaging/Info.plist" > "$APP/Contents/Info.plist"
copy() { ditto --norsrc --noextattr --noqtn "$1" "$2"; } # without Finder/iCloud metadata
copy "$ROOT/web" "$APP/Contents/Resources/web"
copy "$ROOT/packaging/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
copy "$ROOT/packaging/mdviewer" "$APP/Contents/Resources/mdviewer"
chmod +x "$APP/Contents/Resources/mdviewer"
xattr -cr "$APP"

# Apple Silicon only runs signed code. An ad-hoc signature (no developer
# account) is enough for an app built on this Mac.
codesign --force --deep --sign - "$APP"
echo "==> Built $APP ($(lipo -archs "$APP/Contents/MacOS/MDViewer"))"
