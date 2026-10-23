#!/bin/bash
# Downloads the pinned browser libraries from npm and copies their prebuilt
# files into web/vendor. The app ships these files as-is; no npm install is
# needed to build or run it. To upgrade a library, change its version here,
# run `make vendor`, then `make test`.
set -euo pipefail

MARKDOWN_IT=15.0.3
MARKDOWN_IT_FOOTNOTE=4.0.0
DOMPURIFY=3.4.17
HIGHLIGHT_JS=11.12.0

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/web/vendor"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/mdv-vendor.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

fetch() { # fetch <package@version> <dir>
  mkdir -p "$TMP/$2"
  (cd "$TMP/$2" && npm pack "$1" --silent >/dev/null && tar -xzf ./*.tgz)
}

fetch "markdown-it@$MARKDOWN_IT" md
fetch "markdown-it-footnote@$MARKDOWN_IT_FOOTNOTE" fn
fetch "dompurify@$DOMPURIFY" purify
fetch "@highlightjs/cdn-assets@$HIGHLIGHT_JS" hljs

rm -rf "$OUT"
mkdir -p "$OUT/licenses"
cp "$TMP/md/package/dist/browser/markdown-it.umd.min.js" "$OUT/markdown-it.min.js"
cp "$TMP/fn/package/dist/markdown-it-footnote.min.js"    "$OUT/markdown-it-footnote.min.js"
cp "$TMP/purify/package/dist/purify.min.js"              "$OUT/purify.min.js"
cp "$TMP/hljs/package/highlight.min.js"                  "$OUT/highlight.min.js"
cp "$TMP/hljs/package/styles/github.min.css"             "$OUT/hljs-light.min.css"
cp "$TMP/hljs/package/styles/github-dark.min.css"        "$OUT/hljs-dark.min.css"

cp "$TMP/md/package/LICENSE"     "$OUT/licenses/markdown-it.txt"
cp "$TMP/fn/package/LICENSE"     "$OUT/licenses/markdown-it-footnote.txt"
cp "$TMP/purify/package/LICENSE" "$OUT/licenses/dompurify.txt"
cp "$TMP/hljs/package/LICENSE"   "$OUT/licenses/highlight.js.txt"

cat > "$OUT/VERSIONS.txt" <<EOF
markdown-it           $MARKDOWN_IT   MIT
markdown-it-footnote  $MARKDOWN_IT_FOOTNOTE    MIT
dompurify             $DOMPURIFY  MPL-2.0 OR Apache-2.0
highlight.js          $HIGHLIGHT_JS  BSD-3-Clause
EOF

echo "Vendored libraries into $OUT"
