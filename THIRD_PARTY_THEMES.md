# Third-Party Preview Themes

Pensieve's reading-surface skins (`PreviewTheme` in
`Sources/Pensieve/Preview/ThemeManager.swift`, CSS in
`PreviewWebView.skinCSS(for:)`) include a few surfaces **derived from
third-party open-source Typora themes**. We do not ship the upstream CSS
verbatim: each skin is re-expressed against Pensieve's `--vc-preview-*` design
tokens and `.markdown-body` container, and upstream web-font `@import`/`url()`
dependencies are dropped in favour of system-font fallbacks. The palettes,
however, are derived from these works and credit/license terms apply.

The other skins (`default`, `paper`, `code`, `raw`, `vista`, `mla`, `jamstatic`)
are authorial Pensieve themes and are **not** listed here.

| Skin | Upstream theme | Author | License | Source |
|------|----------------|--------|---------|--------|
| `notion` | Typora Notion theme | cayxc (modified by s1m4ne) | Apache-2.0 | header in upstream `notion-style-*.css` |
| `vercel` | typora-vercel-theme | tecladochen | MIT | https://github.com/tecladochen/typora-vercel-theme |
| `themeable` | typora-themeable | John Hildenbiddle (jhildenbiddle) | MIT | https://github.com/jhildenbiddle/typora-themeable |
| `glass` | Typora Foresee theme | passwordgloo | MIT | https://github.com/passwordgloo/Typora-foresee-theme-study |

## License notices

**MIT** (vercel, themeable, glass): permits use, modification, and distribution,
including in proprietary software, provided the copyright notice and permission
notice are retained. This file, together with the per-skin credit comments in
`PreviewWebView.swift`, constitutes that retention. Full MIT text:
https://opensource.org/license/mit

**Apache-2.0** (notion): permits use, modification, and distribution, including
in proprietary software, with attribution and retention of NOTICE terms. Full
text: https://www.apache.org/licenses/LICENSE-2.0

## Excluded themes

The following were evaluated and **deliberately excluded** because their licenses
are incompatible with shipping inside a proprietary, code-signed application, or
are absent:

- **GPL-3.0** (copyleft): `github-dark` family (Typora-GitHub-Themes), `paradox`
  (seraph/phantom), `onedark` (sweatran).
- **No license declared** (all rights reserved): `typora-default-themes`
  (github / gothic / newsprint / pixyll / whitey — upstream repo `license: null`),
  and other bundle entries without a stated license (vercel was confirmed MIT
  upstream and is included; the rest remain unverified and unused).
