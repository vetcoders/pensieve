Perform the vc-justdo skill on this repository.

Primary input file: /Users/maciejgad/.vibecrafted/artifacts/VetCoders/markdown-editor-mac-objc/2026_0522/operator/briefs/C-2-editor-gemini.md

```md
---
prompt_id: vcnotes-editor-20260522
wave: C
position: 2
mandate: /vc-implement
recommended_agent: gemini
parent_branch: feat/vc-notes-mvp01-foundation
result_branch: feat/vcnotes-editor
depends_on: []
parallel_with: [vcnotes-storage-20260522, vcnotes-preview-20260522]
blocks: [vcnotes-integration-d1-20260522]
report_path: ~/.vibecrafted/artifacts/VetCoders/markdown-editor-mac-objc/2026_0522/operator/reports/vcnotes-editor_<ts>_gemini.md
authored_by: gemini <agents@vetcoders.io>
---

# Wave C-2 — Editor view (gemini)

## 2. Mission

You're tasked with replacing the placeholder `EditorRepresentable` in `VCNotes/Sources/VCNotes/Editor/EditorView.swift` with a production-grade source markdown editor built on **TextKit 2** (NSTextLayoutManager + NSTextContentStorage), not legacy TextKit 1. The editor must show **line numbers in a gutter**, **markdown syntax highlighting** (headings, bold, italic, code blocks, links), and **language-aware code block coloring** for fenced code blocks (\`\`\`json, \`\`\`swift, \`\`\`python, \`\`\`rust, \`\`\`bash, \`\`\`yaml at minimum). Font size must respond to `appState.fontSize` (Cmd+/-/0 already wired in Commands). Editor mode toggling (Cmd+1/2/3) is also already wired — your job is just to make the source view itself beautiful and responsive. After this lands, Maciej can paste a JSON debug log into a fenced \`\`\`json block and see it highlighted as he types.

## 3. Context

Read before editing:
- `docs/specs/2026-05-22-vc-notes-design.md` — sections 2 (stack), 4 (modes), 5 (MVP scope)
- `VCNotes/Sources/VCNotes/Editor/EditorView.swift` — current placeholder (NSTextView with TextKit 1)
- `VCNotes/Sources/VCNotes/App/AppState.swift` — `activeDocumentText`, `fontSize`, `mode`, `activeDocumentDirty`
- `VCNotes/Sources/VCNotes/App/Commands.swift` — Notification.Name `.vcDocumentChanged`
- Apple WWDC 2021 session "What's new in TextKit and text views" (TextKit 2 introduction)
- Apple Developer docs: `NSTextLayoutManager`, `NSTextContentStorage`, `NSTextElement`, `NSTextLayoutFragment`
- swift-markdown (in deps) — you may use it for AST-based highlighting OR roll a regex tokenizer for MVP (your call)

Parent branch `feat/vc-notes-mvp01-foundation` has the placeholder + dependency wired.

## 4. Files to create / edit

```text
Create:
  VCNotes/Sources/VCNotes/Editor/MarkdownTextView.swift        — NSTextView subclass with TextKit 2 stack
  VCNotes/Sources/VCNotes/Editor/MarkdownTextStorage.swift     — NSTextContentStorage subclass with attribute application
  VCNotes/Sources/VCNotes/Editor/SyntaxHighlighter.swift       — markdown tokenizer (regex or swift-markdown AST)
  VCNotes/Sources/VCNotes/Editor/CodeBlockHighlighter.swift    — language-aware code block colorizer
  VCNotes/Sources/VCNotes/Editor/LineNumberGutter.swift        — NSRulerView subclass

Modify (KEEP PUBLIC API):
  VCNotes/Sources/VCNotes/Editor/EditorView.swift
    - REPLACE EditorRepresentable internals with TextKit 2 stack
    - KEEP the SwiftUI EditorView struct (its env injection + binding shape)
    - C-3 preview agent depends on `appState.activeDocumentText` two-way binding
```

## 5. Acceptance

- [ ] NSTextView uses TextKit 2 stack (NSTextLayoutManager + NSTextContentStorage), not TextKit 1
- [ ] Line numbers visible in left gutter, updated as text changes
- [ ] Markdown syntax highlighting visible for: H1-H6 (color + size delta), bold (bold weight), italic (italic), inline code (monospace + bg), links (color + underline), blockquotes (left border indent or color)
- [ ] Fenced code blocks with language hint (\`\`\`json) get language-aware coloring for at minimum: json, swift, python, rust, bash, yaml. Plain \`\`\` (no language) renders as monospaced gray
- [ ] `appState.fontSize` change via Cmd+/-/0 updates editor font in real time
- [ ] Typing updates `appState.activeDocumentText` and posts `.vcDocumentChanged` notification (preview will subscribe)
- [ ] `activeDocumentDirty` flips to true on first edit, back to false after autosave (storage agent's job, you only set it true)
- [ ] No regressions in mode toggle Cmd+1/2/3 (source/split/preview)

## 6. Gates

```bash
cd VCNotes
swift build                                # must succeed
swift test 2>&1 | tail -20                 # if you add unit tests, they pass
swift run VCNotes &                        # launches
sleep 3 && killall VCNotes 2>/dev/null     # started without crash
```

Manual smoke (operator will verify):
- Open Folder with `.md` file containing headings + code blocks
- Headings are colored differently from body
- \`\`\`json block shows JSON-style coloring (keys/strings/numbers distinct)
- Cmd+= bumps font; gutter line numbers stay aligned

## 7. Out of scope (DO NOT touch)

- WYSIWYG mode / Rich Markdown layer — Wave 2 (just toggle field exists in AppState, don't wire visuals)
- Focus mode (sentence/paragraph dimming) — Wave 2
- Typewriter mode (caret-centered scroll) — Wave 2
- Floating toolbar on selection — Wave 2
- Markdown autoconversion (# → heading transform) — Wave 2
- Wikilink autocomplete — Wave 2
- Preview pane changes — C-3 territory
- Storage / autosave logic — C-1 territory
- File loading / saving — C-1 territory

## 8. Living Tree etiquette (NON-NEGOTIABLE)

```text
- Re-read every file in `Files to modify` IMMEDIATELY before editing it.
  Another agent in a sibling wave may have pushed between dispatch start and first edit.
- For files marked APPEND-ONLY, never delete or rename existing exports.
- If you detect another agent's work is incompatible with your acceptance,
  halt and write `substrate-failure.md` — operator-agent decides next move.
```

## 9. Loctree first

```text
1. mcp__loctree-mcp__context on repo root before any edit
2. mcp__loctree-mcp__slice on VCNotes/Sources/VCNotes/Editor/EditorView.swift before rewriting
3. mcp__loctree-mcp__find name="EditorRepresentable" mode="where-symbol"
4. mcp__loctree-mcp__find name="activeDocumentText|fontSize" mode="symbols"

Loctree may not parse Swift fully (known gap, ~/.vibecrafted/loctree/loctree-fail.md L693+).
Fallback to grep acceptable; log new findings.
```

## 10. Recovery hint

```text
- Substrate stall (TextKit 2 API change in macOS 14+ vs 13): document the gap, target macOS 13 minimum,
  add `@available(macOS 13, *)` guards if needed
- Scope stall (syntax highlighter explodes in scope): ship MVP with H1-H6 + bold + italic + code,
  defer link/blockquote to follow-up commit, write `scope-overflow.md`
- Implementation stall (TextKit 2 layout glitches at >30 min): consider TextKit 1 fallback,
  write `wrong-cut.md` with TextKit 2 attempt + reason for fallback. Operator decides.
```

## 11. Branch + commit convention

```text
Branch: feat/vcnotes-editor off feat/vc-notes-mvp01-foundation
Commit title: [gemini/vc-implement] feat(vcnotes): TextKit 2 source editor with line numbers + syntax HL
Commit body: include `Authored-By: gemini <agents@vetcoders.io>`
DO NOT git push.
DO NOT create PR.
```

## 12. Report path + Call to Action

Report sections (mirror frontmatter, set `status: completed | failed`):
- Current state, Proposal, Execution, Open risks, Next move
- Gate results (last 10 lines each)
- Files changed (`git diff --stat HEAD~1`)
- Acceptance verification (flipped checkboxes)
- TextKit 2 vs TextKit 1 decision rationale (if any unexpected gotchas)

```text
=======================
A code editor where line numbers drift out of sync with text is haunted by a
typographic poltergeist — every off-by-one breaks the user's mental map. TextKit 2
fragments are your friend here; let them carry the gutter math. (งಠ_ಠ)ง
=======================

Call to Action: Start with the TextKit 2 stack (MarkdownTextStorage + MarkdownTextView), then plug in the gutter (LineNumberGutter), then layer the syntax highlighter, then add code block language detection last. End with the report.

Suchar: Why did the markdown tokenizer break up with regex? Because it wanted commitment to an AST. (._.)
```
```
