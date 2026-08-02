# Changelog

All notable changes to Pensieve will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- The source panel is now set in each theme's own monospace family — Sometype Mono (Parchment), JetBrains Mono (Graphite, Ink), IBM Plex Mono (Porcelain), Spline Sans Mono (Typewriter) — across body text, bold/semibold spans, inline code, the caret's typing attributes, the autocomplete ghost, and the line-number gutter. `Default` and `Raw` keep the system monospaced face.
- Task lists gained a third checkbox state: `- [~]` ("in progress") is highlighted in the source panel like `- [ ]` / `- [x]` and renders in preview as a diamond inside an accent-coloured frame.

### Changed

- **Typewriter now follows your Mac's light/dark setting**, and it does it with two palettes of its own rather than by turning into a system theme. Set your Mac to dark and the window is the dark one — `#171717` titlebar over a dark source panel; set it to light and the same skin turns the window and the source panel white. The **page stays white either way**: the sheet is what you are reading, and it is paper in both halves, so the preview never follows the window into dark. Switching the system setting re-dresses open windows live, and an exported PDF is always the light sheet — exporting from a dark Mac no longer produced a dark document. Both halves stay on Typewriter's one grey ramp with no colour at all. A theme saved as Typewriter stays Typewriter; there is nothing to re-pick.
- The toolbar's active toggles — Rich Markdown, Auto Reload Preview, Scroll Sync, Dictation, AI Autocomplete — now fill from the active theme instead of the system accent: sienna on Parchment, deep slate-teal on Graphite, iris on Ink, clinical teal on Porcelain, mid grey on Typewriter — which stays achromatic, one step up its own grey ramp. `Default` and `Raw` keep the accent chosen in System Settings.

### Fixed

- **A window is never closed out from under the work it is holding.** A background sweep tidies away empty "Pensieve" launcher windows a fifth of a second after they appear, and it decided what was empty from its own window bookkeeping — which cannot see what a window is actually showing. The window holding an unsaved draft recovered from a previous session was invisible to it (there is no file behind that draft, so the window never stopped looking like an empty launcher), and so was a window still resolving what it would show at launch. Whichever lost that race was closed, taking the work with it. The sweep now asks each window what it is holding, leaves anything with unsaved work or an unresolved launch alone, and still clears away launchers that really are empty.

- **The toolbar's active toggles carry the theme's colour on every window, and they keep it after you switch themes.** Picking Typewriter left Auto Reload Preview and Scroll Sync lit in system blue on a window with no document open, and near-white on a window with one — the theme's grey never arrived on either. The colour was written by the editor pane and by the preview, so a window showing neither (the launcher, an empty workspace, a new window) was never painted at all; and on a window that does show them, switching themes rebuilds the toolbar right after the paint and takes the colour back off, with nothing to put it on again until the next edit. The chips are now painted by the window itself — every window, on every theme switch, and again whenever macOS hands the toolbar back. `Default` and `Raw` looked correct throughout only because their chip colour IS the system accent.

- **A native window tab stays on the window's own light or dark, wherever it happens to sit.** With two tabs open over a split editor and preview, the tab sitting above the white page could turn light and cream while its neighbour above the editor stayed dark — and it came and went as you clicked around, so the same two tabs looked right one moment and mismatched the next. macOS builds the tab strip out of the same glass the toolbar is made of, and glass told nothing picks light or dark from whatever happens to be underneath it: above the page, that is white paper. Stating the window's scheme fixed the toolbar, but the tab strip is a separate piece of chrome that the statement never reached, and macOS rebuilds it from scratch every time you switch tabs — so anything set once was gone by the next click. Each window now puts its tab strip back on its own side, and does it again every time macOS hands it a new one.

- **What you type goes into the tab you are looking at.** After switching to another tab, an edit could land in the tab you had just left: its text was replaced with what you meant to put somewhere else, while the tab you were actually looking at sat unchanged. The menu keeps a note of which window to act on, and it only updated that note at the moment a window came to the front — but a tab created for a document is regularly brought to the front _before_ it knows which window is its own, so the note was never updated for it and kept pointing at the previous tab. The note is now also brought up to date the moment a tab learns its own window, so it always names the tab in front.

- **Recovered work comes back under its own name.** Unsaved work rescued from a previous session always reappeared as "Recovered Untitled.md", whatever it had been called — the name was recorded when the work was stashed and then thrown away when it was read back. The name is now kept alongside it. Work stashed before this change still comes back under the generic name; there is nothing to recover it from.

- **Opening a Word or PDF file no longer takes over the document you have open.** Every other way of opening a file gives it its own tab when the current window is busy, but importing did not: converting a Word or PDF document replaced whatever that window was showing with the converted draft, leaving the original file's name on a tab that no longer held it. The file on disk was never harmed, but the document you had open vanished from the window. An import now opens in its own tab whenever the window is already showing something.

- **Closing a file from the Open Files list can no longer skip its "save first?" prompt.** The close asks the window that owns the file whether it has unsaved work; when it could not tell which window that was, it asked the window you clicked in instead — which, not holding the file, truthfully answered that there was nothing to save, and the close went ahead unprompted. When no owning window can be identified the close is now refused outright, so nothing is closed unasked.

- **The toolbar's Mode picker answers a click again.** It was drawn as a single greyed-out "Mode" chip that opened nothing while the diamond next to it still worked. A segmented picker cannot live inside a segmented control: declaring it inside the family's `ControlGroup` made macOS fold the whole picker into one disabled segment carrying its title. The picker is now declared directly in its toolbar group and comes back as one live segment per mode.
- **The toolbar's format buttons edit the document again.** Bold, Italic, Strike, Quote, Code, Link and the two list actions shared a control group with the Rich Markdown toggle, which put the whole control into on/off tracking — a click lit the segment like a sticky state instead of running a one-shot action. The format actions now sit in a group of their own and stay momentary, matching the floating selection bar and the Format menu.
- **The whole toolbar fits an ordinary window again.** The Mode picker was drawn as four titled segments behind a 300 pt width floor — 300 pt of a 1096 pt toolbar for one control — and macOS answered by pushing the three trailing families (Mode, Reload/Auto Reload/Scroll Sync, Dictation/AI Autocomplete/Rewrite) behind the "»" chevron at a 1450 pt window. Mode now shows icon segments, each naming itself on hover, which brings the toolbar to 944 pt and the point where macOS starts hiding families from ~1366 pt down to ~1200 pt.
- **The "»" overflow menu lists every control it hides, exactly once.** Its entries come only from what each toolbar family can describe about itself, and a family bridged into a segmented control describes nothing — so Auto Reload Preview, Scroll Sync, Dictation and AI Autocomplete simply ceased to exist on a narrow window, while Reload Preview and Rewrite with AI appeared twice each, once as a button and once as a chevroned parent of themselves. Every family now carries a named menu of its own controls, with live check marks for the toggles and the same actions the chips run.
- A theme carried over from an older build is migrated once instead of on every launch: the retired name (`glass`, `pergament`, `klinika`, `maszynopis`, …) was mapped to its surviving skin in memory only, so the dead value stayed in preferences until you picked a theme by hand. The migrated name is now written back where it is resolved.
- `==highlight==` stays readable in the source panel on themes whose mark wash sits on top of the body text colour (Typewriter): the marked span falls back to the theme's own pane colour and reads as an inverted stamp instead of vanishing.
- Find-bar match highlights survive a live theme switch (and a font-size change, and toggling rich markdown) instead of vanishing while the bar still counts "1 of N".
- Typing with a bundled-font theme active no longer rebuilds and re-ships the theme's inlined `@font-face` payload (0.2–0.8 MB) to the preview on every debounced keystroke.
- An escaped `\[~]` stays prose in the preview instead of being promoted to an in-progress task — the same escape GFM already honours for `\[x]` / `\[ ]`.
- Preview-only windows keep the active theme's titlebar and appearance after a toolbar re-bridge or a tab-group reshuffle: chrome is re-asserted on every hosting pass and on every re-parent, instead of riding a rendered document the preview's own update dedupe may never send.
- Switching theme live no longer re-seeds the caret at heading size: on a document that opens with a `#` heading, the pane took its new base face from the font of the first character — which the highlighter has already grown to h1 size — so the next character typed (and the autocomplete ghost) came out 26 pt on a 14 pt document. The base face now follows the editor's own font size.
- **Split window on a single-mode theme:** on a Mac set to Dark, a light theme (Parchment, Porcelain, Typewriter) dressed the editor and preview but left the sidebar, the traffic lights and the mode picker dark — most visibly on the document a relaunch restores, which is the first thing you see. The editor and preview paint every pixel from the theme's own palette, but the sidebar is a system material and the window widgets are the system's, so both follow the window's appearance — and that appearance is owned by the SwiftUI scene, which discards anything written to it from outside. The theme's light/dark is now declared where the scene already reads it, so it holds on every window: restored, freshly opened, and every new tab, and it follows a live theme switch on all of them at once.
- **Typewriter follows the Mac while it is running, not only at launch.** Changing your Mac's light/dark setting with a window open moved the titlebar, the sidebar, the line numbers, the status bar and the window itself to the other half, and left the source panel painted in the previous one — a black pane inside an otherwise fully light window. Re-colouring the source panel is expensive, so it is deliberately skipped when the theme has not changed; the check asked "is it still Typewriter?", and on a flip it always is. It now asks which of the two palettes is actually on screen, so the panel turns over with everything else, and a single-mode theme still skips the work entirely. The page stays white in both halves, as before.
- **Half-lit toolbar on Typewriter:** on a Mac set to Dark, Typewriter's dark half dressed the titlebar, the sidebar and the editor dark but left the trailing toolbar families — the mode picker, the theme control, reload, the preview toggles and the assistants — light, chips included, on every window with a document open. Two things had to be said out loud to fix it. Typewriter picks its half by reading the system setting, so it told the window "no preference" and let the window read that setting a second time on its own; the theme now states the half it chose. And a toolbar on macOS 26 is glass: told nothing, each pill picks light or dark from whatever is composited beneath it — and beneath the trailing half of this toolbar sits the preview sheet, which Typewriter keeps white in _both_ halves. The toolbar is now told the same half as the window, so the pills stop reading the paper and follow the theme. The page is unaffected: it is white in both halves, as before.
- **A file closed out of Open Files stays closed.** Closing a row with its "×" removed the window and the row, but nothing told the working set the app restores from — so the file came back on the next launch, and on every launch after that, since nothing ever pruned that list. Closing a file now retires it from the restored working set as well: both the list and the saved file reference a launch reads. Quitting with files still open is unchanged and brings them all back, and cancelling at a Save/Don't Save prompt now forgets nothing.
- **Launching with nothing open opens nothing.** Quitting with an empty session and starting Pensieve again brought back a document — reliably the same one, a file that had not been touched in weeks and was in no saved list of open files. Restoring a workspace ended in "and if nothing was selected, select the first document", and on a launch nothing is ever selected. "First" is not "most recent": the scan sorts folders before files and each group alphabetically, then walks depth-first, so it was the first Markdown file inside the alphabetically-first folder — an arbitrary file, picked by the app, that nothing in the previous session had opened. A launch now opens exactly what was left open: the files in Open Files, and otherwise the launcher. Opening a workspace still shows its tree; picking something to read from it is yours.
- **Losing the document you were reading empties the editor, instead of putting a different file in it.** Deleting the open document, or hiding the folder it lives in, replaced it with whatever file the scanner reached first — a document you had not asked to open, in the pane you were just working in. The same fallback also meant that once a workspace was open, any file appearing or changing anywhere in it could open a document in a session where you had nothing open at all. A refresh now only ever keeps you where you were: the document you are reading stays and reloads, renaming or moving it keeps you in it under its new name, and creating or duplicating a file still opens the new one — but when there is nothing to keep you in, you get the empty state.
- **Start-up hang:** opening a large document (a recovered draft of ~1 MB or more) under a theme with a fixed light/dark appearance — Parchment, Porcelain, Graphite, Ink, Typewriter — pinned the main thread at 100% CPU and left the document window blank at 0×0. The window's appearance is owned by the SwiftUI scene, which puts its own value back after anyone else writes it, so the per-pass chrome check never agreed with the window, re-wrote the appearance on every pass, and each write drove another full editor update — an unbounded loop whose every cycle paid the cost of the whole document. The theme's appearance is now re-asserted from what the app last applied to that window and whenever the titlebar backing was clobbered, so a settled window writes nothing while a toolbar re-bridge or tab-group reshuffle is still healed.

## [0.4.2] - 2026-07-22

### Added

- Dictation panel with automatic, Polish, and English recognition; continuous Preview/Final transcript assembly; and selection-aware insertion into the active Markdown editor.
- AI Autocomplete with native OpenAI Responses and Anthropic Messages provider runtimes, dynamic model discovery with last-known-good model caching, persistent per-document completion sessions, and a contextual rewrite preview.
- Provider settings pane (endpoint, model, API key) with a single app-wide onboarding sheet presented once.
- Native **File → Open Recent** menu backed by `NSDocumentController`, with recording rules that keep ad-hoc and workspace documents routed correctly.
- Workspace exclusions that actually prune scanning, plus per-root removal from multi-root workspaces.
- Intent-driven agent dispatch: one canonical dispatch sheet behind a single confirmation gateway, runtime workflow-capability probing that exposes real research-swarm truth, and a remembered last dispatch root.
- Release pipeline: DMG artifacts are named `Pensieve-<x.y.z>+<commit-slug>.dmg` for build traceability (a stable-named `Pensieve.dmg` copy keeps the `releases/latest` download link alive), and notarized DMGs publish to the internal team shelf with `SHA256SUMS.txt`.
- CI runs the complete release gate, with Semgrep findings bounded by a reviewed, repository-owned policy (`.semgrep-policy.json`) instead of inline suppressions.

### Changed

- AI Autocomplete is discoverable from the editor toolbar and now cancels stale or IME-composition requests without leaking provider internals into user-facing errors.
- Inline autocomplete now receives explicit text before and after the cursor and continues the authored document instead of treating questions in it as chat prompts.
- Hot workspace scans moved off the main thread with cancellable scan sessions; tree freshness and search-index freshness are tracked separately, so the sidebar stops flashing "Importing Workspace" on cached reopens.
- File watching rebuilt on FSEvents with canonical paths — deep filesystem changes (nested folders, renames) now reach the workspace tree.
- Move-to-Trash is immediate and nonblocking: workspace state mutates only after the recycle succeeds, and a failed or cancelled trash preserves tree, selection, session, windows, and search index exactly.
- Opening external files standardizes the URL once on the fast path; selected files open in the current window as native tabs.
- Editor toolbelt uses native control families and a native themes menu.
- Release DMG offers a drag-install layout with an `/Applications` shortcut; release artifacts embed the optimized (release-profile) FFI runtime; the macOS deployment target contract is aligned and SwiftUI deployment warnings are gone.
- Landing page copy rewritten as plain product truth with a real app screenshot.

### Fixed

- **Release blocker:** saving the provider API key failed on every signed build with `errSecMissingEntitlement (-34018)`. The biometry-gated `SecAccessControl` routed the item to the macOS data-protection keychain, which requires provisioning-profile-backed entitlements that Developer ID signing does not carry — and it excluded Macs without Touch ID outright. The key now stores as a plain login-keychain item whose silent access is still bound to the app's code signature; a Security-framework round-trip test guards the contract.
- ARC over-release in the FSEvents callback: the paths array is now obtained via `Unmanaged.fromOpaque(...).takeUnretainedValue()` instead of `unsafeBitCast`, preserving the callback ownership contract.
- Redundant per-entry `resolvingSymlinksInPath()` disk walks removed from workspace traversal; symlink identity is checked once before classification, cutting synchronous I/O in large workspaces.
- OOXML parser integer readers offset from `Data.startIndex`, so non-zero-index `Data` slices can no longer crash or misread imported documents.
- Signed Developer ID builds carry the microphone entitlement; Dictation drains the engine's final result without duplication, recovers from stale stop errors while keeping a live capture fail-closed, and engine-error cleanup hops to the main actor before touching observable state.
- Undo actions targeting a window's text view are cleared on window detach, ending crashes from dangling undo targets.
- Workspace and DOCX persistence hardened; AI sessions persist only opaque state; model discovery reuses the saved API key; provider endpoints are normalized to the Responses/Messages doctrine.
- Test suites no longer strand `UserDefaults` suite plists in `~/Library/Preferences` — every suite goes through an ephemeral-defaults helper that removes the domain, its backing plist, and cfprefsd's lazy write-back.
- Reviewed ATS policy keeps user-selected endpoints on Apple's system trust store without inline scanner suppressions.
- Main-thread livelock on toolbar history state: `ToolbarResponderHistoryState` subscribed to `.NSUndoManagerCheckpoint`, and reading `canUndo`/`canRedo` in the refresh handler itself posts a checkpoint notification — a self-feeding refresh cascade at run-loop speed (observed at 147% CPU and multi-GB memory growth, no crash report). The checkpoint subscription is removed (real transitions arrive via `DidUndoChange`/`DidRedoChange` and text/window notifications), availability writes are equality-guarded, and a regression test forbids re-subscribing the checkpoint.
- Closing the final document or empty workspace window with ⌘W now leaves exactly one live launcher; invisible SwiftUI placeholder scenes no longer suppress cold-start recovery or let launcher reaping leave the app windowless. ⌘Q still terminates without resurrecting a window.

## [0.4.1] - 2026-07-16

### Fixed

- Selected workspace files open in the current window; external files open as native tabs instead of hijacking recovery drafts.
- Find-bar highlights are batched, ending the beachball on large documents.
- Production 0.4.0 landing page recovered; DMG checksum refreshed after the asset rebuild.

## [0.4.0] - 2026-07-15

### Added

- Word/PDF transfer bridge: import `.docx` and `.pdf` as Markdown drafts, export documents as `.docx`.
- Instant launch and workspace restore.

### Changed

- Preview code blocks drop hard frames for a subtle shadow.
- Signed-app UI smoke testing stabilized.

## [0.3.0] - 2026-07-05

### Added

- Release identity surface: app version, build number, 8-character commit slug, build date, and component version map are embedded into packaged builds and visible from the app.
- IndexDatabase v2 schema: seven-table model (`workspaces`, `documents`, `document_revisions`, `document_chunks`, `scan_sessions`, `workspace_stats`, plus the FTS5 search index) extending the single-table index. Active writers populate `workspaces` + `documents` on every workspace scan; `document_revisions` and `document_chunks` are forward-looking scaffolding for version history and vector chunking.
- FTS5 search index now syncs from the `documents` table via triggers (collapsing the previous double-write) while preserving the existing search behavior, ranking, and ad-hoc (out-of-workspace) document search.
- Per-scan operational telemetry: a `scan_sessions` append-only log plus a `workspace_stats` aggregate (file/folder counts, last scan/index timestamps, index health) — the data source for an upcoming workspace dashboard.
- App Store lane: sandbox entitlements, MAS packaging target, sandbox dispatch gating, microphone usage metadata, and bookmark coverage for security-scoped workspace access.
- Real AI autocomplete path: the native completion bridge now exposes `complete()`, and the editor constructs autocomplete with a production completion engine instead of a mock-only path.
- Current-document agent dispatch, format-selection menu routing, scroll-sync toggle, and compact Appearance/Edit toolbar menus.

### Changed

- Preview chrome now uses runtime titlebar overlap from the window instead of a hardcoded glass strip height.
- Workspace open activity is honest about cached reopen versus first import, reducing false "Importing Workspace" takeovers.
- Move-to-Trash handling closes affected open documents before recycling so the UI does not keep phantom files alive.
- Release gates now surface failing Swift test names and run Swift gate coverage through the local pre-push lane.

### Fixed

- Autocomplete no longer silently succeeds with an empty-string stub.
- Scroll sync is rebuilt as off-by-default with a re-entrancy guard.
- WebContent recovery, workspace activity teardown, ghost-text acceptance, and toolbar placement received regression guards.

## [0.1.0] - 2026-05-24

### Added

- **MVP 0.1 Release:** Minimum Viable Demonstrator.
- Native macOS `NSTextView` implementation with TextKit 2.
- Markdown parsing utilizing `swift-markdown`.
- Split view support (`SOURCE`, `SPLIT`, `PREVIEW` modes).
- Syntax highlighting for code blocks (`json`, `swift`, `python`, `rust`).
- Live HTML rendering via `WKWebView` using legacy CSS (`markdown.css`, `gfm.css`).
- FSEvents-based file watching.
- SQLite indexing framework setup via `GRDB.swift`.
- Vibecrafted documentation (README, CONTRIBUTING, CHANGELOG, CODE_OF_CONDUCT).
- Business Source License (BSL) transition.
