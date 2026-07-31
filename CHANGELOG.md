# Changelog

All notable changes to Pensieve will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- The workspace import banner counted the whole corpus: every cold open announced "Indexing N Markdown files" with `N` = every document in the workspace, so editing three notes and relaunching claimed thousands of files were being reindexed. The banner now names the reindex queue the open actually writes, and an open with no index work ahead makes no import claim at all.
- A cold open in the background import path compared the persisted `.md` signature against itself, so its incremental reindex always saw an empty delta and never ran. The comparison now uses the freshly measured signature from the open's own tree walk, so edits made while the app was closed are indexed (and the persisted baseline advances) on the next launch.

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
