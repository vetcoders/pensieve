# Pensieve — Keyboard Shortcuts, File & Recovery Contract v0.1

> **Author: Monika (2026-08-03). Details filled in from settled product
> decisions (dates inline).** Items marked **[OPEN]** await a decision — list
> at the end.
> Operator's Polish working copy lives outside the repo.

This document is the source of truth for keyboard shortcuts, menus, and the lifecycle of files, tabs, windows and recovery in Pensieve. Changing a command's semantics requires updating this contract.

Pensieve follows macOS conventions but has its own model: **workspace + files + tabs**.

## General rules

- All shortcuts are defined centrally, preferably in the `Commands` layer, not locally in views.
- One command has one semantics — regardless of focus and the active view (sidebar, editor, preview, search panel), unless the contract states otherwise.
- The menu bar must present the same commands that actually handle the shortcuts.
- Standard macOS shortcuts must not be overridden: `Cmd+F`, `Cmd+S`, `Cmd+W`, `Cmd+M`, `Cmd+Q`.
- Close and save operations must never lead to silent data loss.

---

## Canonical shortcuts

### `Cmd+T` — New Empty Tab

Creates an empty, editable untitled/unsaved tab in the current window and moves focus to the editor. Does not create a file on disk. `Cmd+S` triggers the Save As flow for it.

Clarifications (decisions 26.07/31.07, canon item 2):

- an untitled buffer lives only in memory until an explicit save — zero 0 B files on disk;
- the app **never creates an untitled tab on its own** (startup, restore, or any automation must never produce a new untitled/recovery buffer without a user action).

### `Cmd+N` — New

In Pensieve v1 this is an alias for `Cmd+T`: it creates a new empty tab / untitled buffer. It must not mean sometimes a new file, sometimes a window, and sometimes a workspace.

Splitting `Cmd+N` (new window/document) from `Cmd+T` (new tab) is only possible after an explicit product decision on the multi-window model.

### `Cmd+O` — Open File… / `Shift+Cmd+O` — Open Folder…

Actual state of build 528 (the launcher shows both shortcuts separately) —
the contract adopts this split:

- `Cmd+O` — native file picker; a Markdown file opens as a tab
  (click = tab, decision 26.07);
- `Shift+Cmd+O` — native folder picker; a folder opens as a workspace;
- opening should not needlessly fully reindex the current
  workspace/cache;
- opening a **large file must not block the UI silently** — the user
  gets immediate feedback (tab/progress), and expensive work must not
  freeze the main thread for minutes (lesson from bugs H/J, 03.08).

### `Cmd+S` — Save

Saves the active tab:

- a tab with a path — saves to the existing file;
- an untitled/unsaved tab — triggers Save As;
- saving must not trigger a self-write reindex loop or lose the dirty buffer state.

### `Shift+Cmd+S` — Save As…

Saves the active buffer as a new file, and on success assigns the tab a new path. This is not TextEdit's `Duplicate`, unless a separate flow is approved at the product level.

### `Cmd+W` — Close Current Tab

Closes the active tab/file, but **does not quit the application**.

- With multiple tabs, closes only the active one.
- With the last tab, the window shows the startup screen (launcher), it does not
  quit the app (decision recorded further below in "Open decisions",
  item 1 — resolved).
- For unsaved changes or recovery, displays a native prompt
  (macOS naming: **Save / Don't Save / Cancel**; for untitled —
  Monika's 03.08 proposal: a full native sheet with a "Save As" field,
  tags, and inline location, like TextEdit/Pages — separate UX cut).
- `Cancel` aborts closing; **Cancel = zero mutation** (no draft or
  buffer may be destroyed before the prompt is resolved).
- **RESOLVED (Monika, 03.08):** closing a single tab
  carried through to completion (Save / Don't Save / clean close) **removes the file
  from Open Files and from the session**. Closing the whole window via the red
  button does NOT remove it (a tidying gesture — files come back). Quit, crash,
  and emergency exit NEVER remove it — files come back after restart.

### `Cmd+Z` / `Shift+Cmd+Z` — Undo / Redo

Undo operates within the scope of the active document. After a tab is closed, `Cmd+Z`
in another window/launcher is a safe no-op — it must never target
a closed editor (lesson from the 03.08 crash, PR #29: the undo stack must
be cleared of ALL targets of a dying editor during teardown).

### `Shift+Cmd+W` — Close Window

Closes the whole window with all its tabs — the equivalent of the red button.
A tidying gesture: it does NOT remove files from Open Files (they come back on restore).
For dirty tabs, the window-close flow applies (batch modal).

### `Shift+Cmd+T` — Reopen Closed Tab (03.08 proposal)

A safety net for ⌘W-retire (Safari convention): restores the last closed
tab along with returning the file to Open Files. Pending product
confirmation — together with Recent Files (D5) it forms the full set of
cushions against accidental closes.

### Tab navigation

`Ctrl+Tab` / `Ctrl+Shift+Tab` and `Cmd+Shift+[` / `Cmd+Shift+]` work
natively (system tabs). Contract: they must not be overridden or broken.

### `Cmd+G` / `Shift+Cmd+G` — Find Next / Previous

Companions to `Cmd+F`; they move through find-bar results in the active
document.

### `Cmd+M` — Minimize Window

Minimizes the active window. Must not open Settings/Preferences or trigger any other Pensieve function.

### `Cmd+F` — Find in Current Document

Opens the find bar and searches only in the active document. This is not workspace or global search and must not disappear through a `CommandGroup` override.

### `Shift+Cmd+F` — Search in Workspace

Runs a search across the workspace via the index / FTS / fallback. Does not replace `Cmd+F`, and the results must reflect the current state of the files.

### `Cmd+,` — Settings

Opens Settings/Preferences, if available.

### `Cmd+Q` — Quit Pensieve

Quits the whole application per macOS convention. If dirty buffers or recovery items requiring a decision exist, the app must protect the user from data loss.

---

## Closing windows and tabs

### System window `X` button

Closes the window, not a single tab. Must not cause a cycle of "window/app closes and immediately reopens." Such behavior is a bug to diagnose.

### `X` button on a tab

Closes only that tab and behaves analogously to `Cmd+W`, including respecting dirty buffer and recovery protection.

### `Open Files` list

Every item must have an unambiguous action to close a single file, e.g. an `X` next to the name. Single-close and close-all actions must be visually and semantically distinguished.

---

## Recovery

A recovery item exists until the user makes an explicit decision. It must not be removed just because the user:

- closed the window or the application;
- switched tabs or ended the session;
- created a new file.

Clarifications (03.08, after bug I "ghost factory"):

- **One buffer = one recovery item.** Autosaving a draft updates the existing
  item in place; it must not create a new item (a new UUID) per autosave
  tick or per close. Multiplying drafts of the same content is a bug.
- The same draft must not be adopted simultaneously by two windows
  (protection from line #21, 02.08).
- Drafts surface exclusively through an explicit launcher
  (Recovered Drafts section) — never through silent adoption into a fresh tab.

Clarification (04.08, Monika — "they don't disappear without my decision"):

- **No retention, no cap.** Neither the passage of time nor the number of stored
  drafts retires anything. The launch pass over the recovery directory is
  read-only; the app previously deleted drafts older than 30 days and trimmed the
  rest to the newest 20, and that behavior is gone.
- If the number of drafts ever needs to be surfaced, it is shown to the user as
  information — never acted on by deleting.

Clarification (05.08, after the file-backed half of bug I):

- **"One buffer" includes a FILE-BACKED buffer.** A named document whose window
  tears down without reaching disk (auto-save off — the default — or a save that
  failed) is stashed as a recovery item too, and that stash follows the same
  rule: the buffer keeps ONE item across every close, every quit flush and every
  window on the same file. It must not mint a new UUID per stash. (It did:
  `recoveryID` lived inside the untitled session shape, so a file-backed buffer
  read `nil` and its write-back was dropped, and with no sweep left to hide it a
  single unsaved document grew the recovery directory without bound.)
- A **successful save of the file** retires the stash it was standing in for —
  the same closed list as before ("being saved as a regular file"), now also
  applying to a plain ⌘S on a named document.

Creating a new document must not force a recovery decision. A recovery item can only be deleted after:

- being saved as a regular file;
- being explicitly discarded;
- being closed with confirmed rejection of changes.

When closing a recovery item, the app shows a native prompt:
**Save / Don't Save / Cancel** (macOS naming; "Discard" appears
only in the batch modal as **Discard All**). It must not be removed without asking.

---

## Batch close modal — FINAL shape (Monika, 03.08, after native-behavior analysis)

1. Default option: **Review Changes…** (step through documents one by one).
2. **Save All** — a convenience shortcut (deliberate extension; the native alert doesn't have it).
3. **Discard All** — a clear, destructive option.
4. **Cancel** — always safely aborts the operation.
5. Every untitled/recovery document gets its own native **Save As** — never
   an automatic save under a generated name.
6. Zero rollback for completed saves.
7. Recovery disappears only after a successful save or explicit rejection.

Review order: active tab first, then left to right
(predictability; macOS does not mandate this order — a deliberate choice).

Discard All requires an extra confirmation (this morning's spec; deliberately
more cautious than the native Discard Changes — relevant for recovery items).
Micro-refinement to consider during implementation: narrowing the
confirmation to only batches that contain recovery items.

## Close All Open Files

If all files are saved and no recovery item requires a decision, the app may close all files without an additional prompt.

Otherwise it shows the batch modal in its FINAL shape
(section above): **Review Changes…** (default) / **Save All** /
**Discard All** (with confirmation) / **Cancel**.

Close All must never cause silent data loss.

---

## Session and restore at launch (03.08 addendum)

- **Workspace is configuration — it always comes back** (decision 26.07, W9). The
  "Restore session on launch" toggle controls only the files that get opened
  and the auto-select.
- Startup restore opens at most **12 most recent** files of the working set
  (decision 03.08, interim pending a true session snapshot — target model:
  "tabs from the moment of quit", variant b from 31.07).
- Restore **must not undo a deliberate Close** by the user.
- **Trash is dead** (decision 26.07): a file or folder whose bookmark
  points into `~/.Trash` does not exist for the app — it does not come back on
  restore and disappears from the store. (Implemented for files in PR #30; for
  workspace roots **[OPEN]**.)
- **Single source of truth for the session: the app.** macOS's own window
  restoration (Saved Application State) must not resurrect documents alongside
  the app's session model (bug G, 03.08 — pending session-layer audit). The
  target is for the app to explicitly control the `isRestorable` state of its
  windows.

## Launcher (startup screen) — 03.08 addendum

- RECENT list: rows must have visible click affordance
  and immediate click feedback; clicking opens a file as a tab, consistent
  with "click = tab".
- Opening a large file from Recents follows the same rule as `Cmd+O`:
  zero silent UI blocking (bug J, 03.08).
- Recent Files (File → Open Recent, D5 from 26.07) is a list independent of
  Open Files and the working set; during ⌘W-retire it acts as a safety net
  ("file disappears from Open Files, stays in Recents").

## Minimal smoke check

An agent implementing or refactoring menu/commands must verify:

- [ ] `Cmd+T` creates an empty tab with no file on disk.
- [ ] `Cmd+N` does the same as `Cmd+T` in v1.
- [ ] `Cmd+O` opens the file picker, `Shift+Cmd+O` the folder picker (workspace).
- [ ] `Cmd+S` saves an existing file, and for untitled it triggers Save As.
- [ ] `Shift+Cmd+S` triggers Save As.
- [ ] `Cmd+W` and the tab's `X` close the active tab and protect dirty buffer/recovery.
- [ ] The system `X` closes the window without an automatic reopen.
- [ ] `Cmd+M` minimizes the window, `Cmd+,` opens Settings, and `Cmd+Q` quits the application.
- [ ] `Cmd+F` searches in the document, and `Shift+Cmd+F` in the workspace.
- [ ] Close All protects unsaved files and recovery items.
- [ ] `Cmd+Z` after a tab close is a safe no-op (not a crash);
      `Shift+Cmd+Z` performs redo.
- [ ] `Shift+Cmd+W` closes the window (= red button), files remain
      in Open Files.
- [ ] `Ctrl+Tab` and `Cmd+Shift+[`/`]` switch tabs; `Cmd+G`/`Shift+Cmd+G`
      walk through find-bar results.
- [ ] No shortcut is bound to two different commands.
- [ ] The menu bar and the actual shortcut handling are consistent.
- [ ] A session with a single untitled buffer after an hour of work has exactly ONE
      recovery item (zero draft multiplication).
- [ ] Clicking a RECENT row on the launcher gives immediate feedback,
      and opening a large file does not block the UI silently.
- [ ] Restore after restart: workspace always comes back; open files max 12;
      a file/root from Trash does not come back; a deliberately closed file does not come back.

---

## Open decisions and items to verify

0. **List of currently open items (state as of 03.08, after this morning's decisions):**
   - **[OPEN]** workspace ROOT in Trash on restore (same rule as
     files — does it stay);
   - **[OPEN]** native Save sheet for untitled on close
     (Monika's 03.08 proposal, separate UX cut);
   - **[OPEN — pending multi-window decision]** splitting `Cmd+N`/`Cmd+T`;
   - **[OPEN]** `Shift+Cmd+T` Reopen Closed Tab (proposal — ⌘W-retire
     safety net).

   **To be inventoried in v0.2** (exist in the UI, semantics to be written down):
   markdown formatting (`Cmd+B` / `Cmd+I` / `Cmd+K` — the toolbar has
   bold/italic/link), switching editor/split/preview mode, sidebar toggle,
   zoom `Cmd+±0`. **`Shift+Cmd+N` reserved** — nothing to be assigned to it pending
   the multi-window decision.

   RESOLVED today: ⌘W and Open Files (see the `Cmd+W` section — closing a
   tab removes the file from the session; window/quit/crash do not remove it); the
   last tab (launcher); the shape of the batch modal (the "Batch close modal" section).

1. **Last tab after `Cmd+W`** — RESOLVED: shows the startup screen
   (launcher), does not quit the app.
2. **System `X` and dirty tabs** — SPEC IN FORCE (not an open
   decision; to be moved into the "Closing windows and tabs" section for v0.2).
   03.08 implementation delta: the PR #15 line has a two-phase pass (decisions
   for all windows BEFORE any mutation, Cancel aborts the whole thing) —
   in the spirit of this flow, but WITHOUT the batch modal
   (Review Changes… / Save All / Discard All); the batch modal is a separate
   UX cut after the campaign. The following flow applies when closing a window:
   - If no tab has unsaved changes and none is a recovery item, the window closes without an additional prompt.
   - If only one tab requires a decision, the app shows the native prompt: **Save / Don't Save / Cancel**.
   - If several tabs require a decision, the app first shows the batch modal with the options:
     - **Review Changes…** — the default option; step through the files in order, with a **Save / Don't Save / Cancel** decision for each;
     - **Save All** — a quick save of all files; untitled and recovery tabs require subsequent Save As pickers;
     - **Discard All** — discarding all changes only after an additional, unambiguous confirmation;
     - **Cancel** — aborts closing and leaves the whole window unchanged.
   - In **Review Changes…** mode, files are presented in a predictable order: the active tab first, then subsequent tabs from left to right.
   - `Cancel` at any stage aborts closing the whole window. Saves already performed remain saved, but unresolved tabs are neither closed nor discarded.
   - A save error stops the process, indicates the specific file, and leaves the window open.
   - The window closes only once every dirty, untitled, and recovery item has been successfully saved or explicitly discarded. No decision never means `Discard`.
3. **Save All for untitled/recovery** — SPEC IN FORCE (not an
   open decision; key rules: paths files first, without pickers;
   untitled/recovery one at a time via native Save As — NEVER an
   automatic save under generated names; canceling any picker aborts the
   entire Close All; completed saves remain; a recovery item disappears only after a
   confirmed save).

   **Compatibility with the native model (03.08 analysis, Monika + Fable):** the
   flow is compatible with NSDocument/NSDocumentController on every safety
   rule (pathed without a picker, untitled via the native Save sheet,
   Cancel aborts the whole thing, no rollback, error blocks, Review as default).
   TWO DELIBERATE extensions relative to the native alert — not to be
   "corrected" back toward pure nativeness:
   - **Save All** — the native batch alert doesn't have it (only Review /
     Discard / Cancel); our extension, safe;
   - **Discard All with an extra confirmation** — the native Discard Changes
     deletes without a second question; we are deliberately more cautious here
     (the "zero silent data loss" principle, relevant for recovery items).

   The operation proceeds in the following order:
   - First the app saves dirty files that already have a path on disk. These saves do not require pickers.
   - Then it handles untitled and recovery tabs in order: the active tab first, then the rest from left to right.
   - For each such tab it shows a separate native **Save As** picker. Several independent buffers must not be saved automatically under generated names.
   - After a successful save, the untitled tab receives the chosen path and becomes a regular saved file. A recovery item can be removed from recovery only after the file has been confirmed saved to disk.
   - Canceling any picker **aborts the entire Close All**. The window stays open; the canceled and still-unresolved tabs keep their content and dirty/recovery status.
   - Files saved before the cancellation remain saved — the operation does not try to undo completed saves.
   - A save error stops the sequence at the specific file, shows a readable message, and leaves the window open. A recovery item cannot be removed after a failed save.
   - After resolving the error, the user can retry the save, move to **Review Changes…**, or cancel the close.
   - The window or all tabs close only once every dirty, untitled, and recovery item has been successfully saved or explicitly discarded.

**Safety rule:** `Cancel`, closing a picker, and a save error are never equivalent to `Discard`.
