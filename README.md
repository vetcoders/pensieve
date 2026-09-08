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
- **Fast Native Core:** Built on Swift 6, SwiftUI, and AppKit's `NSTextView` with TextKit 2.
- **Staged Opens for Large Files:** documents over ~1 MB are read in the background. The window or tab appears immediately with an `Opening …` placeholder, the visible text is coloured first and the rest of the document follows in frame-sized chunks, so a multi-megabyte note never freezes the app.
- **Dictation:** Capture speech locally, review continuous transcript text, and insert it at the active Markdown selection with natural spacing and undo.
- **Agent-Aware Writing:** Current-document dispatch and local AI autocomplete are wired into the native editor.
- **Word/PDF Transfer Bridge:** Export Markdown to `.docx`; open or import `.docx` and text-based `.pdf` files as editable Markdown drafts.

## Word and PDF transfer

Pensieve keeps Markdown as the source of truth while making exchange with Word-first collaborators practical:

- **Markdown → Word:** choose **File → Export Word (.docx)…**. Headings, paragraphs, emphasis, links, and lists remain structured in the Word document.
- **Word → Markdown:** choose **File → Import Word or PDF…**, use **Open File…**, or open a `.docx` with Pensieve from Finder. The source stays untouched and the conversion opens as an unsaved `.md` draft.
- **PDF → Markdown:** text-based PDFs follow the same import path. Scanned PDFs without a text layer are rejected with an OCR-required message instead of opening a blank document.

The existing HTML and PDF export options remain available in the File menu.

## Agent dispatch lifecycle

Dispatch asks Vibecrafted to start a detached worker and returns a run ID. The
launch receipt is not a completion result: the run can continue after the
dispatch sheet closes, and closing the optional Terminal status window does not
stop it. Pensieve resolves the installed uv-managed Vibecrafted entrypoint by
absolute path and supplies the standard agent binary directories that a
Finder/Dock launch omits from `PATH`; custom version-manager layouts can use
`PENSIEVE_VIBECRAFTED_PATH` to select a wrapper that establishes their required
environment. The override chooses the Vibecrafted executable; it does not add
version-manager shim directories to an agent's `PATH` by itself.

A positive worker PID in Vibecrafted metadata is shown as **Run started**. It is
a spawn record, not a promise that the worker is still alive. If Vibecrafted
exits successfully with a valid run ID but that spawn record does not arrive
within the bounded confirmation window, Pensieve shows **Run accepted · launch
unconfirmed**, preserves the run ID and any report path, and does not call the
run failed or encourage a duplicate dispatch. **Reveal report** appears only
when the launcher returned a report path. **Check status in Terminal** appears
only when the observer agent is authoritative: either the receipt names it or
the dispatch explicitly selected one positional agent. Pensieve does not guess
an observer for a default swarm. A genuinely rejected launch keeps its real exit
code, run ID and report path when available, and shows the final actionable
launcher error without offering a status check for a run that never started.
The status action requests one snapshot; the worker itself remains owned by its
Vibecrafted/vc-frame session.

## Requirements

- macOS 15 or newer.
- Apple Silicon is the daily-driver target; Intel compatibility is not the current release gate.

## Download

Download the latest signed and notarized release from
[GitHub Releases](https://github.com/vetcoders/pensieve/releases/latest/download/Pensieve.dmg),
open the DMG, and drag Pensieve to Applications.

## Build from source

Source builds require Swift 6.2 or newer (Xcode 26+). Both the app and tests use Swift 6 language mode with complete concurrency checking; macOS 15 remains the deployment minimum.

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

## Runtime testing

`dist/Pensieve.app` and `make run-release` use Pensieve's production bundle
identity and the operator's existing state. `make run` is also non-isolated: its
unbundled executable uses the normal support and Keychain fallbacks. These lanes
are appropriate only when that state is intentionally under test; they are not
fresh smoke environments.

Use a repository-owned isolated lane for runtime checks:

```bash
make manual-smoke          # new clean interactive experiment
make manual-smoke-reopen   # reopen that same experiment with its state intact
make manual-smoke-verify   # read-only identity and scope verification
make manual-smoke-clean    # retire only that experiment
make ui-smoke              # automated ephemeral smoke with a unique identity
```

Every new manual or automated smoke receives a unique, manifest-scoped runtime
identity and must fail closed rather than read, reset, or delete production
Pensieve state. Trusted build provenance and exact executable/FFI payloads are
verified before launch; historical or dirty-source experiments are explicitly
labelled and are not release evidence. The complete identity, cleanup,
compatibility and evidence contract has one canonical home:
[`docs/runtime-testing.md`](docs/runtime-testing.md). Read it before adding or
changing a runtime test.

The Mac App Store packaging lane exists as `make release-appstore`, but App Store Connect submission, signing identities, and the final MAS truth-clicks stay with the human operator.

## Product contract

The canonical definition of keyboard shortcuts and the lifecycle of files,
tabs, windows, and recovery is
[`docs/keyboard-shortcuts-and-file-lifecycle-contract.md`](docs/keyboard-shortcuts-and-file-lifecycle-contract.md).
Implementations, tests, reports, and external mirrors do not override it.

## Background & Heritage

Pensieve is the spiritual successor to an older Objective-C markdown editor (by Satoshi Iwaki) that served as our daily driver for over a year. We kept the essence (and the CSS) but rebuilt the engine entirely in modern Swift to drop legacy debt and gain native Apple Silicon performance.

---

Created by Vetcoders.
