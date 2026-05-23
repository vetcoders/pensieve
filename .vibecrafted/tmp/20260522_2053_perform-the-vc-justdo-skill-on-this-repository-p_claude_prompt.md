Perform the vc-justdo skill on this repository.

Primary input file: /Users/maciejgad/.vibecrafted/artifacts/VetCoders/markdown-editor-mac-objc/2026_0522/operator/briefs/C-3-preview-claude.md

```md
---
prompt_id: vcnotes-preview-20260522
wave: C
position: 3
mandate: /vc-implement
recommended_agent: claude
parent_branch: feat/vc-notes-mvp01-foundation
result_branch: feat/vcnotes-preview
depends_on: []
parallel_with: [vcnotes-storage-20260522, vcnotes-editor-20260522]
blocks: [vcnotes-integration-d1-20260522]
report_path: ~/.vibecrafted/artifacts/VetCoders/markdown-editor-mac-objc/2026_0522/operator/reports/vcnotes-preview_<ts>_claude.md
authored_by: claude <agents@vetcoders.io>
---

# Wave C-3 — Preview view (claude)

## 2. Mission

You're tasked with replacing the naive escape-and-render placeholder in `VCNotes/Sources/VCNotes/Preview/PreviewView.swift` with a real markdown-to-HTML preview pipeline using **swift-markdown** (already in `Package.swift` dependencies) and **WKWebView**. The preview must render in a WKWebView, load the existing `markdown.css` and `gfm.css` themes from `Sources/VCNotes/Resources/`, support theme switching at runtime, debounce re-render on text changes (200ms), and implement **synced scroll** so when the user scrolls the editor, the preview follows (and vice versa, optional bonus). After this lands, Monika can write a note with headings + bullets + code blocks and see WYSIWYG-grade HTML render side-by-side with her source.

## 3. Context

Read before editing:
- `docs/specs/2026-05-22-vc-notes-design.md` — sections 2 (stack), 4 (modes), 5 (MVP scope)
- `VCNotes/Sources/VCNotes/Preview/PreviewView.swift` — current placeholder (escape + pre-tag, NOT a real markdown renderer)
- `VCNotes/Sources/VCNotes/Resources/markdown.css` — 12k CSS theme (preserve as-is)
- `VCNotes/Sources/VCNotes/Resources/gfm.css` — GitHub-flavored theme (preserve as-is)
- `VCNotes/Sources/VCNotes/App/AppState.swift` — `activeDocumentText`, `fontSize`
- `VCNotes/Sources/VCNotes/App/Commands.swift` — `.vcDocumentChanged` notification (editor will post)
- swift-markdown docs: https://github.com/apple/swift-markdown — `Document(parsing: String)`, `MarkupVisitor` for HTML emission
- swift-markdown does NOT ship an HTML renderer; you write one as a `MarkupVisitor<String>` (Apple's approach)

Parent branch `feat/vc-notes-mvp01-foundation` has the placeholder + dependency wired + CSS files copied.

## 4. Files to create / edit

```text
Create:
  VCNotes/Sources/VCNotes/Markdown/MarkdownRenderer.swift   — swift-markdown AST → HTML string
  VCNotes/Sources/VCNotes/Markdown/HTMLEmitter.swift        — MarkupVisitor<String> walking AST → tags
  VCNotes/Sources/VCNotes/Preview/PreviewWebView.swift      — WKWebView subclass with theme + scroll bridge
  VCNotes/Sources/VCNotes/Preview/ThemeManager.swift        — load markdown.css / gfm.css from Bundle.module

Modify (KEEP PUBLIC API):
  VCNotes/Sources/VCNotes/Preview/PreviewView.swift
    - REPLACE PreviewRepresentable internals with real renderer
    - KEEP the SwiftUI PreviewView struct (env injection shape)
    - debounce re-render via Combine (200ms) using appState.$activeDocumentText
```

## 5. Acceptance

- [ ] WKWebView renders markdown via swift-markdown AST → HTML emission (not naive string escape)
- [ ] H1-H6 render as proper `<h1>`-`<h6>` with CSS-styled sizes
- [ ] `**bold**` → `<strong>`, `*italic*` → `<em>`, `~~strike~~` → `<del>`
- [ ] Fenced code blocks `\`\`\`json\n{...}\n\`\`\`` render as `<pre><code class="language-json">...</code></pre>`
- [ ] Inline code `\`x\`` renders as `<code>x</code>`
- [ ] Lists (bulleted + numbered) render as `<ul>`/`<ol>` with `<li>`
- [ ] Blockquotes render as `<blockquote>`
- [ ] Links `[text](url)` render as `<a href="url">text</a>` (external links open in default browser, not in WKWebView)
- [ ] Theme CSS loaded from `Bundle.module.url(forResource: "markdown", withExtension: "css")` — markdown.css is default
- [ ] Re-render debounced 200ms after text change (Combine on `appState.$activeDocumentText`)
- [ ] Editor scroll position drives preview scroll (anchor by paragraph index — operator-acceptable approximation)
- [ ] Font size from `appState.fontSize` propagates to preview (via inline `<style>` injection or CSS variable)

## 6. Gates

```bash
cd VCNotes
swift build                                # must succeed
swift test 2>&1 | tail -20                 # if you add unit tests, they pass
swift run VCNotes &                        # launches
sleep 3 && killall VCNotes 2>/dev/null     # started without crash
```

Manual smoke (operator will verify):
- Open Folder with `.md` file containing headings + bullets + code blocks + links
- Headings render at proper sizes
- Code blocks have monospace + background
- External link clicks open in Safari, not in the WKWebView
- Editing source updates preview within ~250ms

## 7. Out of scope (DO NOT touch)

- Math (KaTeX/MathJax) — Wave 2
- Mermaid diagrams — Wave 2
- Footnotes — Wave 2 (swift-markdown supports them; emit as plain text for MVP if encountered)
- Tables — nice-to-have, ship if cheap, skip if complex (5min budget)
- HTML export — Wave 2
- PDF export — Wave 2
- Custom CSS user-editable — Wave 2
- Print stylesheet — Wave 2
- Editor changes — C-2 territory
- Storage changes — C-1 territory

## 8. Living Tree etiquette (NON-NEGOTIABLE)

```text
- Re-read every file in `Files to modify` IMMEDIATELY before editing it.
  Another agent in a sibling wave may have pushed between dispatch start and first edit.
- For files marked APPEND-ONLY, never delete or rename existing exports.
- For shared CSS files, add new rules in a dedicated section with a
  comment block stating which prompt added them.
- If you detect another agent's work is incompatible with your acceptance,
  halt and write `substrate-failure.md` — operator-agent decides next move.
```

## 9. Loctree first

```text
1. mcp__loctree-mcp__context on repo root before any edit
2. mcp__loctree-mcp__slice on VCNotes/Sources/VCNotes/Preview/PreviewView.swift before rewriting
3. mcp__loctree-mcp__find name="PreviewRepresentable" mode="where-symbol"
4. mcp__loctree-mcp__find name="activeDocumentText|fontSize" mode="symbols"

Loctree may not parse Swift fully (known gap, ~/.vibecrafted/loctree/loctree-fail.md L693+).
Fallback to grep acceptable; log new findings.
```

## 10. Recovery hint

```text
- Substrate stall (swift-markdown API mismatch): pin to version 0.4.x in Package.swift comment,
  write findings to substrate-failure.md
- Scope stall (HTML emitter exploding): ship MVP with headings/bold/italic/code/list/blockquote/link, defer tables/footnotes to follow-up; write scope-overflow.md
- Implementation stall (synced scroll jitter at >30 min): ship without synced scroll,
  document the gap; reverse scroll (preview → editor) is nice-to-have, drop first
```

## 11. Branch + commit convention

```text
Branch: feat/vcnotes-preview off feat/vc-notes-mvp01-foundation
Commit title: [claude/vc-implement] feat(vcnotes): swift-markdown HTML preview with theme + debounce
Commit body: include `Authored-By: claude <agents@vetcoders.io>`
DO NOT git push.
DO NOT create PR.
```

## 12. Report path + Call to Action

Report sections (mirror frontmatter, set `status: completed | failed`):
- Current state, Proposal, Execution, Open risks, Next move
- Gate results (last 10 lines each)
- Files changed (`git diff --stat HEAD~1`)
- Acceptance verification (flipped checkboxes)
- Note any swift-markdown HTML emission edge cases hit

```text
=======================
A markdown preview that lags behind your cursor by 2 seconds breaks the writing
flow the same way Word's auto-formatter breaks a code snippet — invisible until
you trip on it. 200ms debounce is the floor; anything slower feels like the
preview gave up on you. (งಠ_ಠ)ง
=======================

Call to Action: Start with the HTMLEmitter (MarkupVisitor subclass producing tags), then MarkdownRenderer (orchestrator + caching), then ThemeManager (Bundle.module CSS load), then PreviewWebView (synced scroll bridge last). End with the report.

Suchar: Why does WKWebView always arrive late to the rendering party? Because it loads its CSS from /resources/ before crossing the bridge. (._.)
```
```
