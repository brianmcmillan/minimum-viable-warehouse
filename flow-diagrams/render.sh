#!/usr/bin/env bash
# =====================================================================
# Render each flow-diagrams/mermaid/*.md to flow-diagrams/pdf/*.pdf, one
# page per diagram, with the Mermaid CLI (mmdc, version 11 or 12).
#
# Each Markdown file holds one fenced mermaid block; its "# " heading
# becomes the page title. Needs only bash and mmdc: no Python. No
# warehouse, suite or make target runs this script.
#   usage: bash flow-diagrams/render.sh
# =====================================================================
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
command -v mmdc >/dev/null 2>&1 || {
  echo "render: needs the Mermaid CLI: npm install -g @mermaid-js/mermaid-cli" >&2; exit 2; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
if mmdc --help 2>&1 | grep -q -- '--pdfFit'; then
  size="--pdfFit"                                    # Mermaid CLI 11
else
  # Mermaid CLI 12 fits the page to the diagram. The classic look keeps
  # the PDF vector-only, as er-diagrams/generate.py does.
  printf '{"look": "classic", "flowchart": {"wrappingWidth": 320}}' > "$TMP/mermaid.json"
  printf '{"defaultViewport": {"width": 1600, "height": 1000}}' > "$TMP/viewport.json"
  size="-c $TMP/mermaid.json -p $TMP/viewport.json"
fi

mkdir -p "$HERE/pdf"
for md in "$HERE"/mermaid/*.md; do
  stem="$(basename "$md" .md)"
  title="$(sed -n 's/^# //p' "$md" | head -1)"
  { printf -- '---\ntitle: "%s"\n---\n' "$title"
    awk '/^```mermaid/{f=1; next} /^```/{f=0} f' "$md"; } > "$TMP/$stem.mmd"
  # shellcheck disable=SC2086
  mmdc -i "$TMP/$stem.mmd" -o "$HERE/pdf/$stem.pdf" -b white $size >/dev/null
  echo "  $stem.pdf"
done
