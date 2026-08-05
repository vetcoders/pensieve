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

Implemented from build 665: `Cmd+N` routes through the same
`DocumentWindowRegistry.newUntitledTab` seam the tab bar's `+` button uses,
whenever the window holds live work. Until then it replaced the current window's
session in place, so `Cmd+N` over an open document dropped that document out of
the tab chain and out of the sidebar's Open Files list. An **idle** window still
takes the new draft in place — a tab beside an empty launcher would be a window
leak, not a second document.

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

### Clicking a file — same route as `Cmd+O`

`click = tab` (decision 26.07) is not only about `Cmd+O`. Every single-open
gesture — a row in the workspace tree, a search result, the context-menu
**Open**, a RECENT row on the launcher — lands where a Finder "Open with
Pensieve" lands: as a native tab in the current window's tab group. A click is
an explicit open, so it never replaces the document the window is reading;
files stay visible in parallel and switching between them is switching tabs.

- A file that already has a tab is **activated**, never opened a second time —
  neither a re-click nor a click from another window may render the same
  document twice.
- An **empty, idle window** (launcher / empty state) is reused in place instead
  of spawning a tab beside itself: no stray launcher tab, no flash. The single
  exception is the rule above — a file that already has a tab is activated
  there even when the clicking window is idle.
- Clicking the document the window already shows is a no-op.
- Because every open lands as a tab, there is **no separate "Open in New
  Window"** item: it would be a second button for the same action. A detached
  (non-tabbed) window is not part of v1 and is tied to the open multi-window
  decision below.

### `Cmd+S` — Save

Saves the active tab:

- a tab with a path — saves to the existing file;
- an untitled/unsaved tab — triggers Save As;
- saving must not trigger a self-write reindex loop or lose the dirty buffer state.

#### Who may CREATE a file (05.08)

A write to a document's own path may **update** the file it names. Only a write
the user **asked for** may bring one back that is no longer there.

- **Explicit** — `Cmd+S`, `Shift+Cmd+S`, and **Save** answered in a close prompt.
  If the file has vanished from disk (Trash, `rm`, a sync client), these write it
  again. Putting the file back is what the user asked for.
- **Unattended** — the auto-save debounce, the window-teardown flush, and the
  close paths auto-save answers on the user's behalf. These write **only a file
  that is still there**. A missing target is refused before any write: nobody
  asked for it, so a note dragged to the Trash must not reappear where it was,
  beside the copy still sitting in the Trash.

What a refusal guarantees:

- the file is **not** recreated, and nothing else on disk is touched;
- the buffer keeps every character and stays **dirty**, so the tab's unsaved
  marker and the close question stay truthful;
- a refusal is reported exactly like any other save that did not happen, and
  every caller already handles that: a close driven by auto-save is **aborted**
  and the window goes on holding the text, and a window tearing down anyway
  stashes the buffer as a recovery draft, exactly as an auto-save-OFF close
  does. A write that was **attempted and failed** (permissions, full disk)
  behaves identically and is unchanged by this rule — this cut adds a reason to
  refuse a write, not a new way to close a document.

Where the guarantee lives: in the **write**, not in a check before it. An
unattended save publishes through a replace-existing-only step
(`DocumentStore.replaceExistingItem`) that requires its target to exist inside
the same atomic operation, so there is no window in which the file can go and
be recreated. The `fileExists` check ahead of it is a fast path that chooses a
human-readable message; deleting it would change wording, never whether the
file comes back. Any future rewrite of the write layer must keep this
property — a plain atomic write reintroduces the bug.

**Integration requirement for #45 (error surface).** When this line is
integrated with #45, "the file is gone and the buffer is dirty" must **not**
reach the UI as an ordinary `lastError` / `.status` notice. Under the 45.1a
contract this is a **data-loss** class: the user's text now exists in no file,
and the only copy is in a window they may close. It must be classified and
surfaced as such — persistent, not auto-dismissing, and naming the recovery
action (Save As…). Losing this classification during integration turns a
data-loss warning into a toast.

Known limits, deliberately not claimed:

- while a document sits in the refused state, its buffer is durable only in
  memory until the window tears down — the same guarantee a dirty file-backed
  buffer has today with auto-save OFF, or after a save that failed;
- the refusal is not announced in the UI. `AppState.lastError` is set, but it
  has no renderer, so the observable signal is that the file does not come back
  and the document stays dirty. A visible surface for it is a separate cut.

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

### `Shift+Cmd+T` — Reopen Closed Tab (reserved, decision 05.08)

A safety net for ⌘W-retire (Safari convention): restores the last closed
tab along with returning the file to Open Files. Together with Recent Files
(D5) it forms the full set of cushions against accidental closes.

**RESOLVED (Monika, 2026-08-05):** `Shift+Cmd+T` is reserved for this
Reopen Closed Tab behavior, per macOS convention. The feature itself is
**not yet implemented** — it stays on the backlog. Truthful state of this
branch today: `Shift+Cmd+T` is actually bound to **Tidy Table** (Format
menu); no reopen-tab code exists anywhere in the app yet. When Reopen
Closed Tab ships, Tidy Table loses (or is reassigned) this shortcut — the
two cannot coexist on the same binding.

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
- **Trash is dead** (decision 26.07): a file whose bookmark points into a Trash
  does not exist for the app. Membership is asked of the filesystem (every volume
  has its own Trash, a sandboxed build a container-relative one), not matched
  against a hardcoded `~/.Trash`, so a directory merely NAMED `.Trash` is not one.
  The rule holds at every point a file can become, or stay, an open document:
  - launch restore drops such an entry and its bookmark;
  - a **running** app retires it on the next scan commit, whether Pensieve or
    Finder did the trashing — the row leaves Open Files without waiting for a
    relaunch;
  - opening one is refused with "<name> is in the Trash. Put it back to open it.",
    so no route (Recents, drag, a stale sidebar row) can re-add it;
  - selecting one refuses to put its content in the editor and retires the row;
  - after Pensieve's own **Move to Trash**, bookmarks are pruned by where they
    LAND, which also covers every document inside a trashed folder.

  A file that is merely MISSING is not trashed: it keeps its bookmark (it may be
  mid-replacement, or on an unplugged volume) and only drops out of what a
  restore opens. The running app retires such a row only when the bookmark that
  turned up in the Trash is the one MINTED FOR THAT PATH — never because a file
  of the same NAME was thrown away somewhere else, which would retire a document
  still open from a disconnected volume.

  **RESOLVED (Monika, 2026-08-05):** a workspace **root** follows the same
  rule as an individual file above. A root that lands in the Trash
  disappears from the sidebar live, at the next scan commit — same as a
  trashed file leaving Open Files without waiting for a relaunch. Its
  bookmarks (the root's own and every file bookmark it granted) are pruned
  at the same time. Recovery is manual: put the folder back from the Trash,
  then re-add it as a workspace root. **[OPEN — implementation pending]**:
  this PR only implements the individual-file half of "Trash is dead"; the
  root half described here is decided but not yet built.

- **Removing one workspace root never revokes another tab's access.** The
  persisted bookmark set is rebuilt from the UNION of the working set and the
  live tab chain across every window: a document of the removed root that a
  window still has open gets a file bookmark of its own, a document covered by a
  surviving root does not (its root already grants access), and a file that is in
  neither source still loses its bookmark — nothing is resurrected.
- **The working set is durable by the time the process is gone.** Quit forces it
  out of cfprefsd's write-back queue instead of letting the system flush it on its
  own schedule (measured at up to ~14 s AFTER exit, late enough to overwrite a
  change made to those defaults in the meantime). It runs inside the quit's drain
  budget, so a stalled flush can never beachball the quit.
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
- [x] `Cmd+N` does the same as `Cmd+T` in v1 (routed through `newUntitledTab`; pinned by `testNewDocumentOverALiveBufferOpensATabInsteadOfEatingTheOpenFile`).
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
- [ ] A click in the workspace tree / a search result / context-menu "Open"
      opens a tab and leaves the current tab's document alone; re-clicking an
      open file activates its tab instead of opening a duplicate.
- [ ] Restore after restart: workspace always comes back; open files max 12;
      a file/root from Trash does not come back; a deliberately closed file does not come back.

---

## Open decisions and items to verify

0. **List of currently open items (state as of 03.08, after this morning's decisions):**
   - **[OPEN — implementation pending]** workspace ROOT in Trash: behavior
     **RESOLVED (Monika, 2026-08-05)** — same rule as files (see the
     "Trash is dead" section above); not yet built in this PR;
   - **[OPEN]** native Save sheet for untitled on close
     (Monika's 03.08 proposal, separate UX cut);
   - **[OPEN — pending multi-window decision]** splitting `Cmd+N`/`Cmd+T`;
   - **[OPEN — implementation pending]** `Shift+Cmd+T` Reopen Closed Tab:
     shortcut **RESOLVED (Monika, 2026-08-05)** — reserved for this feature
     (see the `Shift+Cmd+T` section above); the feature itself is not yet
     implemented.

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
