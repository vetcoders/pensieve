# Changelog

All notable changes to Pensieve will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Dictation panel with automatic, Polish, and English recognition; continuous Preview/Final transcript assembly; and selection-aware insertion into the active Markdown editor.

### Changed

- AI Autocomplete is discoverable from the editor toolbar and now cancels stale or IME-composition requests without leaking provider internals into user-facing errors.

### Fixed

- Signed Developer ID builds carry the microphone entitlement, Dictation drains the engine's final result without duplication, and failed or stale capture sessions are cleaned up before retry.

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
