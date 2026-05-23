Perform the vc-justdo skill on this repository.

Primary input file: /Users/maciejgad/.vibecrafted/artifacts/VetCoders/markdown-editor-mac-objc/2026_0522/operator/briefs/C-1-storage-codex.md

```md
---
prompt_id: vcnotes-storage-20260522
wave: C
position: 1
mandate: /vc-implement
recommended_agent: codex
parent_branch: feat/vc-notes-mvp01-foundation
result_branch: feat/vcnotes-storage
depends_on: []
parallel_with: [vcnotes-editor-20260522, vcnotes-preview-20260522]
blocks: [vcnotes-integration-d1-20260522]
report_path: ~/.vibecrafted/artifacts/VetCoders/markdown-editor-mac-objc/2026_0522/operator/reports/vcnotes-storage_<ts>_codex.md
authored_by: codex <agents@vetcoders.io>
---

# Wave C-1 — Storage layer (codex)

## 2. Mission

You're tasked with replacing the placeholder `DocumentStore` + `FolderManager` in `VCNotes/Sources/VCNotes/Storage/DocumentStore.swift` with a production-grade file-first storage layer for the VC Notes markdown editor. Implement security-scoped bookmark persistence (so the app remembers the folder across launches with sandbox-ready permissions), an FSEvents-based file watcher (so external edits update the sidebar), and debounced autosave (500ms after the last edit). The `.md` file is the source of truth; SQLite is a future indexing layer (stub it cleanly but don't wire it up yet). After this lands, the editor (C-2) and preview (C-3) panes can rely on `appState.activeDocumentText` always reflecting disk truth without manual save races.

## 3. Context

Read before editing:
- `docs/specs/2026-05-22-vc-notes-design.md` — full architectural design
- `VCNotes/Sources/VCNotes/App/AppState.swift` — observable state
- `VCNotes/Sources/VCNotes/App/Commands.swift` — Notification.Name extensions
- `VCNotes/Sources/VCNotes/Sidebar/SidebarView.swift` — current Notification subscribers
- `VCNotes/Package.swift` — has GRDB.swift dependency ready (don't wire it for MVP, keep stub)
- Apple's "Persisting access to a file URL" sample (security-scoped bookmarks)
- Apple Developer docs: `DispatchSource.makeFileSystemObjectSource` (high-level FSEvents wrapper)

Parent branch `feat/vc-notes-mvp01-foundation` has Package.swift wired and a placeholder DocumentStore.

## 4. Files to create / edit

```text
Create:
  VCNotes/Sources/VCNotes/Storage/BookmarkStore.swift   — security-scoped bookmark persistence
  VCNotes/Sources/VCNotes/Storage/FileWatcher.swift     — FSEvents wrapper, notifies on dir change
  VCNotes/Sources/VCNotes/Storage/Autosaver.swift       — debounced autosave (500ms)
  VCNotes/Sources/VCNotes/Storage/IndexDatabase.swift   — GRDB stub at Application Support

Modify (KEEP PUBLIC API):
  VCNotes/Sources/VCNotes/Storage/DocumentStore.swift
    - REPLACE FolderManager + DocumentStore internals with production versions
    - KEEP public API: FolderManager.shared.open(url:into:),
      DocumentStore.shared.load(ref:into:), DocumentStore.shared.save(appState:)
    - C-2 and C-3 agents depend on this API

  VCNotes/Sources/VCNotes/App/AppState.swift  (APPEND-ONLY)
    + add @Published var bookmarkData: Data?
    + add @Published var lastError: String?
    DO NOT delete/rename existing properties

  VCNotes/Sources/VCNotes/App/VCNotesApp.swift  (APPEND-ONLY)
    + restore folder from bookmark on app launch
    Do not refactor the App struct
```

## 5. Acceptance

- [ ] Open Folder via Cmd+Shift+O persists security-scoped bookmark; relaunch re-opens the same folder
- [ ] FileWatcher detects external file changes within ~500ms and refreshes `appState.documents` on main actor
- [ ] Editing `activeDocumentText` triggers Autosaver; 500ms after last edit, file written; `activeDocumentDirty` flips to false
- [ ] Cmd+S still works as explicit save
- [ ] IndexDatabase opens SQLite db at `~/Library/Application Support/VCNotes/index.db`; no-op migration runs
- [ ] Restoring from bookmark gracefully handles deleted/moved folder (clear bookmark, set `appState.lastError`)
- [ ] Existing SidebarView call sites work without modification

## 6. Gates

```bash
cd VCNotes
swift build                                # must succeed
swift test 2>&1 | tail -20                 # if you add unit tests, they pass
swift run VCNotes &                        # launches
sleep 3 && killall VCNotes 2>/dev/null     # started without crash
```

## 7. Out of scope (DO NOT touch)

- SQLite FTS5 indexing — Wave 2
- Wikilink resolution / backlinks engine / tags — Wave 2
- iCloud sync — never
- Asset management (`Note.assets/` folders) — Wave 2
- ANY editor or preview view changes — C-2 / C-3 territory

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
2. mcp__loctree-mcp__slice on VCNotes/Sources/VCNotes/Storage/DocumentStore.swift before rewriting
3. mcp__loctree-mcp__find name="activeDocumentText" mode="where-symbol"
4. mcp__loctree-mcp__find name="vcOpenFolder|vcSaveActiveDocument" mode="symbols"

Loctree may not parse Swift fully (known gap, ~/.vibecrafted/loctree/loctree-fail.md L693+).
Fallback to grep is acceptable; log it to loctree-fail.md if used.
```

## 10. Recovery hint

```text
- Substrate stall (parent branch missing): write `substrate-failure.md` to report_path, exit non-zero
- Scope stall (acceptance #N too wide): write `scope-overflow.md`, exit 0 with partial commit
- Implementation stall (gates fail >30 min): revert branch, write `wrong-cut.md`, exit 1
```

## 11. Branch + commit convention

```text
Branch: feat/vcnotes-storage off feat/vc-notes-mvp01-foundation
Commit title: [codex/vc-implement] feat(vcnotes): file-first storage with bookmark+watcher+autosave
Commit body: include `Authored-By: codex <agents@vetcoders.io>`
DO NOT git push. Operator publishes after wave green.
DO NOT create PR.
```

## 12. Report path + Call to Action

Report sections (mirror this YAML frontmatter, set `status: completed | failed`):
- Current state, Proposal, Execution, Open risks, Next move
- Gate results (paste last 10 lines of each gate)
- Files changed (paste `git diff --stat HEAD~1`)
- Acceptance verification (paste Section 5 checkbox state, flipped)

```text
=======================
File-first storage is the load-bearing wall of this app — if save races, edits
disappear into the void, and "I lost my note" is the worst review a markdown
editor can earn. Be ruthless about debounce timing and FS observer cleanup. (งಠ_ಠ)ง
=======================

Call to Action: Start with BookmarkStore, then FolderManager rewrite (it depends on the bookmark), then FileWatcher (it needs the resolved URL), then Autosaver (it needs the active document ref). IndexDatabase last as a 5-minute stub. End with the report at the path above.

Suchar: Why does the autosaver never sleep on Saturdays? Because every 500ms it dreams of dirty bits begging to be flushed. (._.)
```
```
