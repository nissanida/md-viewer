#!/bin/bash
# Renders the icon and packs every size macOS needs into packaging/AppIcon.icns.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/mdv-icon.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

swift "$ROOT/scripts/make-icon.swift" "$TMP/icon.png"
mkdir "$TMP/AppIcon.iconset"
for size in 16 32 128 256 512; do
  sips -z $size $size "$TMP/icon.png" --out "$TMP/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z $double $double "$TMP/icon.png" --out "$TMP/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$TMP/AppIcon.iconset" -o "$ROOT/packaging/AppIcon.icns"
cp "$TMP/icon.png" "$ROOT/packaging/AppIcon.png"
echo "Wrote packaging/AppIcon.icns"
