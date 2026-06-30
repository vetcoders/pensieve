# Changelog

All notable changes to Pensieve will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Release identity surface: app version, build number, 8-character commit slug, build date, and component version map are embedded into packaged builds and visible from the app.
- IndexDatabase v2 schema: seven-table model (`workspaces`, `documents`, `document_revisions`, `document_chunks`, `scan_sessions`, `workspace_stats`, plus the FTS5 search index) extending the single-table index. Active writers populate `workspaces` + `documents` on every workspace scan; `document_revisions` and `document_chunks` are forward-looking scaffolding for version history and vector chunking.
- FTS5 search index now syncs from the `documents` table via triggers (collapsing the previous double-write) while preserving the existing search behavior, ranking, and ad-hoc (out-of-workspace) document search.
- Per-scan operational telemetry: a `scan_sessions` append-only log plus a `workspace_stats` aggregate (file/folder counts, last scan/index timestamps, index health) — the data source for an upcoming workspace dashboard.

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
