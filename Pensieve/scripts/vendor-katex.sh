#!/usr/bin/env bash
# Vendor the KaTeX runtime into Pensieve preview resources.
#
# The preview composes self-contained HTML (loadHTMLString / innerHTML updates),
# so external font files cannot be referenced at render time. This script
# downloads a pinned KaTeX release and produces:
#   Resources/katex.min.js          - runtime, inlined into <script> like mermaid
#   Resources/katex.inline.min.css  - stylesheet with woff2 fonts embedded as
#                                     data: URIs (woff/ttf fallbacks stripped)
set -euo pipefail

KATEX_VERSION="${KATEX_VERSION:-0.17.0}"
CDN="https://cdn.jsdelivr.net/npm/katex@${KATEX_VERSION}/dist"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESOURCES="$(cd "$SCRIPT_DIR/.." && pwd)/Sources/Pensieve/Resources"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "Vendoring KaTeX ${KATEX_VERSION}"
curl -fsSL "$CDN/katex.min.js" -o "$WORK/katex.min.js"
curl -fsSL "$CDN/katex.min.css" -o "$WORK/katex.min.css"

mkdir -p "$WORK/fonts"
# Fetch only the woff2 fonts the CSS references.
grep -o 'fonts/[A-Za-z0-9_-]*\.woff2' "$WORK/katex.min.css" | sort -u | while read -r font; do
  curl -fsSL "$CDN/$font" -o "$WORK/$font"
done

python3 - "$WORK" "$RESOURCES" <<'PY'
import base64, pathlib, re, sys

work = pathlib.Path(sys.argv[1])
resources = pathlib.Path(sys.argv[2])
css = (work / "katex.min.css").read_text()

# Collapse each src list to the woff2 entry only, embedded as a data: URI.
def inline(match: re.Match) -> str:
    fonts = re.findall(r"url\(fonts/([A-Za-z0-9_-]+\.woff2)\)", match.group(0))
    if not fonts:
        return match.group(0)
    payload = base64.b64encode((work / "fonts" / fonts[0]).read_bytes()).decode()
    return f"src:url(data:font/woff2;base64,{payload}) format('woff2')"

css = re.sub(r"src:[^;}]*", inline, css)
assert "url(fonts/" not in css, "unresolved font reference left in CSS"

(resources / "katex.inline.min.css").write_text(css)
(resources / "katex.min.js").write_bytes((work / "katex.min.js").read_bytes())
print(f"katex.min.js          {(resources / 'katex.min.js').stat().st_size:>9,} B")
print(f"katex.inline.min.css  {(resources / 'katex.inline.min.css').stat().st_size:>9,} B")
PY

echo "Done. Remember: Package.swift must copy both resources."
