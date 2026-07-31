# Pensieve

Native macOS markdown writing app. File-first. Source-first.
Not Notion. Not Obsidian. Not an unwieldy monolith.
A beautiful, fast, local markdown _pisak_ — crafted for Vetcoders, and anyone who appreciates the pure joy of typing.

_𝚅𝚒𝚋𝚎𝚌𝚛𝚊𝚏𝚝𝚎𝚍. with AI Agents by Vetcoders (c)2024-2026 LibraxisAI_

## The Vibe

- **`.md` is the source of truth. Always.** No proprietary databases trapping your thoughts.
- **SQLite is an index, not a prison.** We use GRDB.swift to make search instant, but your files remain just files.
- **The feeling of writing > feature count.** It’s about the flow.
- **Round-trip safety.** We never destroy your manual formatting.
- **AI is a silent assistant**, not the center of the product.

## Key Features

- **Line Numbers & Syntax Highlighting:** Built for people who mix prose with `json`, `swift`, `python`, and `rust`.
- **Preview & Two-Way Links:** Rich markdown preview, backlinks, wikilinks, Mermaid, math, and source-first editing.
- **Split Modes:** `SOURCE` (Cmd+1), `SPLIT` (Cmd+2), `PREVIEW` (Cmd+3), and `FOCUS` (Cmd+4).
- **Fast Native Core:** Built on Swift 5.9+, SwiftUI, and AppKit's `NSTextView` with TextKit 2.
- **Dictation:** Capture speech locally, review continuous transcript text, and insert it at the active Markdown selection with natural spacing and undo.
- **Agent-Aware Writing:** Current-document dispatch and local AI autocomplete are wired into the native editor.
- **Word/PDF Transfer Bridge:** Export Markdown to `.docx`; open or import `.docx` and text-based `.pdf` files as editable Markdown drafts.

## Word and PDF transfer

Pensieve keeps Markdown as the source of truth while making exchange with Word-first collaborators practical:

- **Markdown → Word:** choose **File → Export Word (.docx)…**. Headings, paragraphs, emphasis, links, and lists remain structured in the Word document.
- **Word → Markdown:** choose **File → Import Word or PDF…**, use **Open File…**, or open a `.docx` with Pensieve from Finder. The source stays untouched and the conversion opens as an unsaved `.md` draft.
- **PDF → Markdown:** text-based PDFs follow the same import path. Scanned PDFs without a text layer are rejected with an OCR-required message instead of opening a blank document.

The existing HTML and PDF export options remain available in the File menu. **File → Export
PDF…** paginates onto real pages — A4 or US Letter depending on your region, with 0.75in
margins.

## Requirements

- macOS 15 or newer.
- Apple Silicon is the daily-driver target; Intel compatibility is not the current release gate.

## Download

Download the latest signed and notarized release from
[GitHub Releases](https://github.com/vetcoders/pensieve/releases/latest/download/Pensieve.dmg),
open the DMG, and drag Pensieve to Applications.

## Build from source

Source builds require Xcode 16 command line tools with Swift 6.0+; the package remains in Swift 5 language mode.

```bash
git clone https://github.com/vetcoders/pensieve.git
cd pensieve
make build
make run
```

To install the locally built app into `/Applications`:

```bash
make install-app
```

Developer and release checks:

```bash
make test
make lint
make gates
```

The Mac App Store packaging lane exists as `make release-appstore`, but App Store Connect submission, signing identities, and the final MAS truth-clicks stay with the human operator.

## Background & Heritage

Pensieve is the spiritual successor to an older Objective-C markdown editor (by Satoshi Iwaki) that served as our daily driver for over a year. We kept the essence (and the CSS) but rebuilt the engine entirely in modern Swift to drop legacy debt and gain native Apple Silicon performance.

---

Created by Vetcoders.
