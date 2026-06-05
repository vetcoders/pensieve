# SCAFFOLD — Pensieve: per-window documents + native macOS window tabs

> **Frame:** vc-scaffold (WRITE entry). State column is machine-readable for vc-operator dispatch.
> A cut reaches `[x]` ONLY when its delivery-verifier is green — never on a claim.
> **Orientation gate:** PASSED (vc-init 2026-06-04 — Loctree context atlas `feat_pensieve-mvp3-machete2@92d7d1b`, structure mapped via tree/focus, blast radius measured via `rg` fallback since the Swift target is a single module with no Loctree import edges).

**Goal:** Make each document live in its own window so macOS native window-tabbing is the single tab surface; remove our home-grown `DocumentTabStrip`; keep the workspace sidebar in every window backed by shared workspace state.

**Architecture (decisions that matter):**
1. **State split.** `AppState` (426 LOC, today holds BOTH) splits into:
   - `WorkspaceStore` — app-wide singleton/`@StateObject`: `workspaceRoots, workspaceTree, documents, openFiles, excludedWorkspacePaths, workspaceSearchQuery/Results, sidebarSortOrder, sidebarFocusedURL, pendingSidebarRenameURL, workspaceActivity, bookmarkData, folderURL`, `allDocuments` cache + sort/search/prune helpers.
   - `DocumentWindowModel` — per-window `@StateObject`: `documentSession, selectedDocumentID, mode, fontSize, richMarkdownEnabled, find* (query/replaceQuery/focusToken/barVisible/replaceMode/pendingCommand), pendingMarkdownFormatCommand, previewAutoReload, previewRefreshToken, sidebarVisible, lastError`.
   - **`documentTabs` is DELETED** — native window tabs replace it.
2. **Per-window controller.** `AppController` is instantiated per WindowGroup root, bound to the shared `WorkspaceStore` + its own `DocumentWindowModel` + the existing singletons (`DocumentStore.shared`, `IndexDatabase.shared`, `FolderManager.shared`). Workspace ops mutate the shared store; document ops mutate the window model.
3. **Native tabbing on.** Reverse `allowsAutomaticWindowTabbing = false` (added in Cut-0 finding-25 fix — it was the opposite direction). `WindowGroup` windows tab natively; `openWindow`/scene plumbing opens or activates a window per document.
4. **Sidebar everywhere.** Each window/tab = `NavigationSplitView { Sidebar } detail: { Editor }`, sidebar reads shared `WorkspaceStore`, rendered independently per window.

**Tech Stack:** Swift 5.9, SwiftUI (`WindowGroup`, `openWindow`), AppKit (`NSWindow` tabbing), macOS 13. Gates: `make build` / `make test` (242 baseline) / `make lint` / `make ui-smoke`.

**Supersession note:** Cut-0 already shipped 6 findings. Two of them — `DocumentTabStrip` "+"-pinned-right (21) and `HorizontalWheelRedirector` vertical-scroll (24) — and the `allowsAutomaticWindowTabbing=false` (25) are **intentionally superseded** by this refactor: the programmatic strip they polish is being removed in favor of native tabs. Toolbar (5–8), Replace disclosure (10–12), Share (27) are unaffected and stay.

---

## Measure key

`Vector`: stabilize | implement | recon | e2e — `state`: `[ ]` todo · `[~]` in-progress · `[?]` unverified · `[!]` blocked · `[x]` verifier-green.
Delta per cut: **intent | baseline | claim | delivery-verifier**.

---

## Cuts

### Cut 0 — Findings 5–8, 10–12, 21, 24, 25, 27  ·  `[x]`
- **Vector:** implement
- **intent:** land the 6 clean ScreenScribe regressions/features.
- **baseline:** toolbar unmounted, no in-bar Replace, "+" scrolls away, no vscroll, native tab dup, no Share.
- **claim:** all 6 landed.
- **delivery-verifier:** `make build` ✅ · `swift test` 242/242 ✅ · `make lint` ✅ · `make release-clean` → notarized+stapled+Gatekeeper-accepted ✅ (DONE).

### Cut 1 — Extract `WorkspaceStore` (shared) out of `AppState`  ·  `[ ]`
- **Vector:** implement
- **Files:** Create `App/WorkspaceStore.swift`; Modify `App/AppState.swift`, `App/AppController.swift`, `Storage/DocumentStore.swift`, `Storage/IndexDatabase.swift`, `Sidebar/SidebarView.swift`, `App/PensieveApp.swift`; Tests `Tests/PensieveTests/PensieveTests.swift`, `WorkspaceSubstrateTests.swift`.
- **intent:** workspace state lives once, app-wide; document state stays in `AppState` for now.
- **baseline:** `AppState` holds both; `documentSession` 83 src/51 test refs, workspace fields ~120 refs.
- **claim:** workspace fields moved to `WorkspaceStore`; FolderManager/IndexDatabase write workspace into it; sidebar reads it.
- **delivery-verifier:** `swift test` green (tests retargeted) **AND** manual: launch, Open Folder → sidebar populates, workspace search returns hits. NOT `[x]` until both.
- **risk:** linchpin cut, widest blast radius. If it overflows 120 min, decompose by consumer (FolderManager → IndexDatabase → DocumentStore → SidebarView) into sub-cuts, each `swift build`-green.

### Cut 2 — `DocumentWindowModel` per window + per-window `AppController`  ·  `[ ]`
- **Vector:** implement
- **Files:** Create `App/DocumentWindowModel.swift`; Modify `App/AppState.swift` (becomes thin/removed), `App/AppController.swift`, `App/PensieveApp.swift`, `App/ContentView.swift`, `App/Commands.swift`, `App/EditorToolbelt.swift`, `Editor/EditorView.swift`, `Editor/FindBar.swift`, `Preview/*`; Tests across the suite.
- **intent:** each window owns its document; still one window visible.
- **baseline:** single shared `documentSession`.
- **claim:** `DocumentWindowModel` is `@StateObject` in WindowGroup root; controller per window; doc ops target the window model.
- **delivery-verifier:** `swift test` green **AND** manual single-window matrix: edit, save, Save As, find/replace, mode switch, font size, preview reload all work. NOT `[x]` until both.

### Cut 3 — Turn native window tabbing on + `openWindow` plumbing  ·  `[ ]`
- **Vector:** implement
- **Files:** Modify `App/LaunchIntentCoordinator.swift` (drop/flip `allowsAutomaticWindowTabbing`), `App/PensieveApp.swift` (`WindowGroup(for:)` / `openWindow`), `App/AppController.swift` + `Sidebar/SidebarView.swift` (selection opens/activates a window per doc).
- **intent:** native tabs are real, each showing its own document.
- **baseline:** tabbing disabled (Cut-0); selection mutates the one shared session.
- **claim:** ⌘T opens a tab; selecting a sidebar doc opens/activates its window; two tabs show different docs; drag-tab-out detaches (native, free).
- **delivery-verifier:** manual: two native tabs with two distinct documents simultaneously visible; drag-out makes a standalone window. (No unit test covers native tabbing — verifier is runtime, marked `[?]` until manually confirmed, then `[x]`.)

### Cut 4 — Remove `DocumentTabStrip` + `documentTabs`  ·  `[ ]`
- **Vector:** implement (cut dead)
- **Files:** Modify `App/ContentView.swift` (delete `DocumentTabStrip` + `HorizontalWheelRedirector`), `App/AppState.swift`/window model (`documentTabs` + `rememberDocumentTab`/`forgetDocumentTab`/`pruneDocumentTabs`), `App/AppController.swift` (`closeDocumentTab`, `selectNextTab`/`selectPreviousTab` → native `selectNextTab:`/`NSWindow` or removed), `App/Commands.swift` ("Show Next/Previous Tab" → native or removed), `Storage/DocumentStore.swift` (tab bookkeeping), `App/LaunchIntentCoordinator.swift`; Tests referencing `documentTabs`.
- **intent:** native tabs are the only tab surface.
- **baseline:** programmatic strip + native bar coexist (the bug 25 redundancy).
- **claim:** strip + `documentTabs` gone; tab commands map to native or removed; nothing references removed symbols.
- **delivery-verifier:** `rg "DocumentTabStrip|documentTabs|HorizontalWheelRedirector" Pensieve/Sources` → zero hits **AND** `swift test` green.

### Cut 5 — Per-window restore + autosave + close semantics  ·  `[ ]`
- **Vector:** stabilize
- **Files:** Modify `App/LaunchIntentCoordinator.swift`, `Storage/Autosaver.swift`, `Storage/DocumentStore.swift`, `App/AppController.swift`; Tests for restore/autosave.
- **intent:** relaunch restores previously-open docs as tabs; autosave + dirty-close work per window.
- **baseline:** single-session restore/autosave.
- **claim:** prior open docs reopen as native tabs; ⌘W closes the tab's doc; dirty prompts per window; last-window close behaves.
- **delivery-verifier:** `swift test` green **AND** manual: open 3 docs → quit → relaunch restores 3 tabs; edit+⌘W prompts save.

### Cut 6 — Regression sweep + fresh ui-smoke  ·  `[ ]`
- **Vector:** e2e
- **intent:** prove the whole surface against runtime, not types.
- **baseline:** 242 tests / ui-smoke on Cut-0 app.
- **claim:** no regressions; native multi-tab UX coherent.
- **delivery-verifier:** `make ci` green **AND** fresh `make release-local` + `make ui-smoke` green **AND** manual matrix (sidebar→tab, two docs, detach, save/restore, find/replace, toolbar, share) all pass.

---

## Scope

**In:** state split, per-window docs, native tabbing, sidebar-per-window, remove our strip, restore/autosave parity.
**Out (explicit, this plan only — NOT dropped):** Dispatch-to-Agent and polling/refresh hygiene are **undropped vectors** tracked in the Pensieve mega-meta atlas (`.vibecrafted/artifacts/VetCoders/pensieve/2026_0604/plans/pensieve-meta/`), not here. Editor-only-tab model is genuinely out (operator chose sidebar-in-every-window).
**This plan is Stream S0b of the mega-meta atlas.**

## Defend (failure modes to probe — Falsify)
- **0-byte-passes lesson:** "tests green" is not "it works" — every cut with a runtime claim carries a manual runtime verifier, not just `swift test`.
- Native tabs showing the SAME doc again → the split (Cut 1+2) is the real fix; turning tabbing on (Cut 3) BEFORE per-window state would re-introduce bug 25. Order is load-bearing.
- Shared workspace mutated from two windows concurrently → `WorkspaceStore` is `@MainActor`; confirm no re-entrancy on `openFiles`/`documents` writes.
- Autosave racing window close → verify dirty-flush ordering in Cut 5.

## Handoff
WRITE artifact complete. vc-operator reads the `state` column: Cut 0 = `[x]`; Cuts 1–6 = `[ ]`. Trigger Cut 1 first (linchpin); Cuts are sequential (each depends on prior). STOP on any `[!]`/`[?]` → recovery-vector = decompose the cut (esp. Cut 1) by consumer.
