# Legacy MarkdownEditor (Satoshi Iwaki, 2018)

This directory preserves the original Objective-C implementation of
**MarkdownEditor** by [Satoshi Iwaki](https://github.com/satoshi-iwaki),
forked here as the starting reference for our rewrite into
**VCNotes** (native macOS Swift/SwiftUI/TextKit 2).

## Why kept

- **Daily driver heritage:** used daily for over a year.
- **Architectural reference:** split-source-preview pattern, converter strategy.
- **Resources still in use:** `markdown.css`, `gfm.css`, `sample.md` were
  promoted into `../VCNotes/Resources/` as the starting CSS theme.

## Status

- **Untouched.** No edits planned. This is a frozen artifact.
- **MIT licensed** (see `../LICENSE` — Iwaki's MIT copyright preserved).
- **Not built or referenced** by the new app.

## What we kept vs rewrote

- ✅ Kept (verbatim): `Resources/markdown.css`, `Resources/gfm.css`, `Resources/sample.md`
- ❌ Rewrote from scratch: every `.h`/`.m` source file (36 files, ~2200 LOC ObjC)
- ❌ Dropped: `GCDWebServer`, `AppAuth`, pandoc shell-out (security risks)

See `../docs/specs/2026-05-22-vc-notes-design.md` for the new architecture.

---

*𝚅𝚒𝚋𝚎𝚌𝚛𝚊𝚏𝚝𝚎𝚍. with AI Agents by Vetcoders (c)2024-2026 LibraxisAI*
