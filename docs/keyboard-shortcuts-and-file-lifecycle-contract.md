# Pensieve — Keyboard Shortcuts, File & Recovery Contract v0.1

> **Owner: Monika. Established 2026-08-03; current through 2026-08-10.**
> Settled decisions carry their dates inline. Items marked **[OPEN]** await a
> product decision; **[IMPLEMENTATION GAP]** means the decision is settled but
> the current code does not yet satisfy it.

This is the single source of truth for keyboard shortcuts, menus, and the
lifecycle of files, tabs, windows and recovery in Pensieve. A report, test,
implementation detail or external mirror cannot override it. Changing a
command's semantics requires an explicit product decision and an update here.

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

Creates an empty, editable untitled/unsaved tab in the current window and moves
focus to the editor. Does not create a file on disk. `Cmd+S` triggers the Save
As flow for it. `Cmd+N` invokes this same operation in v1 and therefore carries
the same editability and focus contract.

Clarifications (decisions 26.07/31.07, canon item 2):

- an untitled buffer lives only in memory until an explicit save — zero 0 B files on disk;
- the app **never creates an untitled tab on its own** (startup, restore, or any automation must never produce a new untitled/recovery buffer without a user action).

### `Cmd+N` — New

In Pensieve v1 this is an alias for `Cmd+T`: it creates a new empty tab with an
untitled buffer in the current window. An **idle** launcher may take that buffer
in place; an occupied window must preserve its current session and add a native
tab. A user-created empty tab is already occupied for placement purposes, even
before its editable buffer finishes attaching: another `Cmd+N` or `Cmd+T` must
add another tab, never reuse that tab in place. The macOS "Prefer tabs when
opening documents" setting does not turn this command into an
independent-window command. A later mature multi-window feature may consciously
split `Cmd+N` (New Window) from `Cmd+T` (New Tab), but that is a future contract
change — not an open ambiguity in v1 and not authority to restore the old
behavior piecemeal.

Rebuilding the workspace around that tab is configuration hydration only. Its
asynchronous completion must not clear or replace the new untitled buffer, even
while the buffer is still empty and therefore not dirty.

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
property — a plain atomic write reintroduces the bug. Because the atomic swap
publishes a new inode, Pensieve copies the existing file's filesystem metadata
(mode, ownership, ACLs, extended attributes/Finder tags and creation metadata)
onto the replacement before the swap while preserving the new content's
modification time. Failure to preserve that metadata aborts before publication.

**Integrated error and recovery behavior (10.08).** When the file is gone or an
original write otherwise fails, the dirty buffer first enters the data-loss
class because its only current copy may be in memory. Pensieve immediately
attempts a RecoveryStore snapshot. A successful fallback keeps the original
untouched, leaves the session dirty, resolves the data-loss latch and shows an
ordinary persistent status saying that the emergency copy is safe. If recovery
also fails, data loss remains latched and close/quit is vetoed. The error surface
and the explicit recovered-file actions are normative below. This applies to a
direct `Cmd+S` as well as unattended auto-save: a failed explicit original write
falls back immediately, but only a later successful original write completes the
Save and retires that recovery copy. The original-write failure and the recovery
write result remain separate conditions, so a later successful recovery tick
never repeats a resolved recovery error or implies that the original became
current.

### `Shift+Cmd+S` — Save As…

Saves the active buffer as a new file, and on success assigns the tab a new path. This is not TextEdit's `Duplicate`, unless a separate flow is approved at the product level.

### `Cmd+W` — Close Current Tab

Closes the active tab/file, but **does not quit the application**.

- With multiple tabs, closes only the active one.
- With the last tab, the window shows the startup screen (launcher), it does not
  quit the app.
- Applies the close-decision matrix below. In particular, a dirty file-backed
  buffer with auto-save OFF displays the native **Save / Don't Save / Cancel**
  prompt. For untitled documents, Monika's 03.08 proposal is a full native
  sheet with a "Save As" field, tags, and inline location, like TextEdit/Pages
  — a separate UX cut.
- `Cancel` aborts closing; **Cancel = zero mutation** (no draft or
  buffer may be destroyed before the prompt is resolved).
- **RESOLVED (Monika, 03.08):** closing a single tab
  carried through to completion (Save / Don't Save / clean close) **removes the file
  from Open Files and from the session**. Closing the whole window via the red
  button does NOT remove it (a tidying gesture — files come back). Quit, crash,
  and emergency exit NEVER remove it — files come back after restart.

#### Close-decision matrix (canonical, Monika + Maciej, 10.08.2026)

This matrix is the single per-document rule for `Cmd+W`, a tab's `X`, the
system window `X`, `Shift+Cmd+W`, and quit. Whole-window and quit flows aggregate
the same decisions across their tabs; they do not invent a second saving policy.

- A clean buffer, or an untouched empty draft, closes without a prompt.
- A dirty file-backed buffer with **Automatically save… ON** is flushed without
  a prompt. Closing proceeds only after the current bytes are durable: first in
  the original file, or — if that write fails — in RecoveryStore. If both
  destinations fail, close is vetoed and the only in-memory copy remains open.
- A dirty file-backed buffer with **Automatically save… OFF** always asks
  **Save / Don't Save / Cancel**. RecoveryStore may protect the buffer from a
  crash, but it never substitutes for this conscious question.
- A dirty untitled buffer always asks **Save As… / Don't Save / Cancel**, in
  either auto-save mode.
- A recovered file-backed buffer is never written over its original merely by
  opening or closing it. Its conscious choices are **Save to Original / Save
  As… / Don't Save / Cancel**.
- `Cancel`, a dismissed save picker, or failure to make the current bytes
  durable vetoes the close. There is no implicit discard path.
- If a conscious Don't Save cannot remove its recovery payload, document/tab
  close and **Clear Open Files** also veto teardown. The global quit path has the
  one explicit exception described under `Cmd+Q`; it does not change these
  document-level close rules.

### `Cmd+Z` / `Shift+Cmd+Z` — Undo / Redo

Undo operates within the scope of the active document. After a tab is closed, `Cmd+Z`
in another window/launcher is a safe no-op — it must never target
a closed editor (lesson from the 03.08 crash, PR #29: the undo stack must
be cleared of ALL targets of a dying editor during teardown).

### `Shift+Cmd+W` — Close Window

Closes the whole window with all its tabs — the equivalent of the red button.
A tidying gesture: it does NOT remove files from Open Files (they come back on restore).
For dirty tabs, the window-close flow applies (batch modal). After the last
window closes, the Pensieve process remains alive with zero windows; it does
not create a launcher automatically. Clicking Pensieve in the Dock later
creates exactly one empty launcher.

Opening a supported file from Finder, `open`, or another application while the
process has zero windows is a different explicit intent: Pensieve creates
exactly one document host for the queued URL and opens that file there. The
request must not remain hidden until a later Dock click, and the new host must
not restore the previous working set around the explicitly opened document.

"Zero windows" means zero DOCUMENT windows. A Settings, About or other auxiliary
window still standing does not count as a surface that can hold a file: with one
of those as the only remaining window, a Finder open still creates exactly one
document host, and a Dock click still creates exactly one empty launcher.
Treating any visible window as a live surface left the opened file parked
invisibly and made the Dock icon inert for the rest of the session.

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

Quits the whole application per macOS convention. It first collects the close
decision for every document; a `Cancel`, dismissed save picker, or true
original-plus-RecoveryStore write failure remains a hard veto with no override.

If the user already chose Don't Save but Pensieve cannot remove that document's
recovery payload, global quit presents **Keep Pensieve Open** (safe default and
Escape) and the destructive **Quit Anyway**. Keep Pensieve Open vetoes the quit
and leaves the failing session dirty and its payload claimed. Quit Anyway applies
the Don't Save decision without pretending cleanup succeeded: the session becomes
clean, the payload and its live claim remain until process exit, and the discarded
copy may appear in Recovered Drafts on the next launch. One Quit Anyway
confirmation authorizes the current and any remaining retirement failures in
that same quit pass; a later quit is a new pass and asks again.

The collect phase is atomic with respect to a later `Cancel`, but phase-two
filesystem cleanup is sequential and cannot be rolled back. If an earlier
explicit Don't Save already removed its payload before a later retirement fails,
choosing Keep Pensieve Open leaves that earlier decision applied. The failing and
not-yet-applied discard sessions remain dirty, and any existing recovery payloads
remain claimed. This narrow boundary does not weaken the hard veto for unsaved
bytes that have no durable original or recovery copy.

---

## Closing windows and tabs

### Native window ownership

Only a root document window may own Pensieve's native document tab group. A
window becoming key or main is a focus event, not proof that it is a document
host. In particular, a sheet, `NSPanel`, child window, elevated helper surface,
Settings window, or another unknown root must never be assigned the document
tabbing identifier and must never receive a document through
`addTabbedWindow`.

While any tab in a native group has an attached sheet, Pensieve does not mutate
that tab group. A file opened during that interval may appear in a separate
document window; it must not be merged through the sheet, its parent, or a
sibling as a fallback. Once the sheet ends, ordinary document-to-document tab
grouping may resume.

Startup restore is one indivisible exception to the timing above, not to its
safety rule. The restore pins the initial document host for its whole multi-turn
pass, and provider onboarding stays unpresented until every restored tab has
joined and the final tab has been selected. A sheet, Settings window or helper
surface becoming key must never redirect a later restore step or split the
working set into additional windows. Pensieve still never mutates a tab group
while it owns an attached sheet; it prevents that overlap instead. That rule
covers the host the pass ADOPTS after its original host closes mid-pass: a
survivor carrying a sheet is not merged into, the pending ref waits for the next
turn, and the pass keeps parking until the group can take it.

The pass ends with exactly one closing order, and that order activates the app
only when Pensieve is still the app the user is in. A restore that finishes
after the user has switched away orders its final tab into place without pulling
focus back across the app boundary.

Window-following UI bridges (theme chrome, toolbar overflow, command routing,
close hooks) publish only a proven document root. A queued callback belonging
to a factory window that has already closed must be dropped rather than
republishing a half-dead window as the current command target.

The close hook must protect both AppKit entry points: `performClose` /
`windowShouldClose` and the terminal `NSWindow.close()` used directly by native
tab chrome on current macOS builds. `willCloseNotification` is too late to ask
or veto and remains only a final recovery backstop. A programmatic close after
Save or Don't Save has already settled may bypass the guard exactly once; it
must not ask twice or leave a reusable bypass armed for a later gesture.

### System window `X` button

Closes the window, not a single tab. Every tab must complete the canonical
close-decision matrix before AppKit tears the window down; auto-save ON may
settle a file-backed tab without a question, while auto-save OFF, untitled and
recovery cases retain their explicit choices. Cancel or a save failure leaves
the window open. A successful close of the last window leaves the running app
windowless. It must not create a launcher, restore another document, or cause a
cycle of "window/app closes and immediately reopens." Such behavior is a bug.
The only replacement-window path is a later explicit Dock activation, which
creates exactly one empty launcher.

The close decision is atomic across the window:

- If no tab has unsaved changes and none is a recovery item, the window closes
  without a prompt.
- If exactly one tab requires a decision, Pensieve shows **Save / Don't Save /
  Cancel**.
- If several tabs require decisions, Pensieve shows the batch-close surface
  specified below. **Review Changes…** visits the active tab first, then the
  remaining tabs from left to right.
- `Cancel` at any stage aborts closing the whole window. Saves already completed
  remain saved; unresolved tabs remain open and unchanged.
- A save error stops the sequence, identifies the affected file, and leaves the
  window open.
- AppKit may close the window only after every dirty, untitled, and recovery
  item has been saved successfully or explicitly discarded. No response, a
  dismissed picker, or an error never means `Discard`.

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

Clarification (10.08, launcher pagination and test isolation):

- **Five drafts per launcher page.** The Recovered Drafts section paginates its
  presentation in groups of five and shows both the visible item range and the
  page count. Previous/Next navigation keeps every unhandled draft reachable.
  This is a UI bound only: it does not reintroduce a storage cap, retention, or
  automatic deletion. If an action removes the last item on a page, the current
  page is clamped to the new last page instead of leaving an empty surface.
- **Tests fail closed outside production Application Support.** A test should
  inject its own stores; every default fallback that otherwise derives
  `~/Library/Application Support/Pensieve` — Recovery, workspace metadata, the
  search index and document AI session state — is nevertheless process-scoped
  under one temporary directory whenever Pensieve is hosted by XCTest. An
  explicit `PENSIEVE_SUPPORT_DIR` still takes precedence for canary runs. A
  forgotten test dependency may therefore contaminate its own test process,
  never the operator's production support directory.

Final recovery contract (Monika + Maciej, 10.08.2026 — decisions 1–6 and 10: A):

- **Crash recovery is independent of auto-save.** An edited untitled draft is
  periodically written to RecoveryStore in either auto-save mode. An edited
  file-backed buffer with auto-save OFF is also periodically written there,
  while the original file remains byte-for-byte untouched.
- **Auto-save failure falls back immediately.** With auto-save ON, Pensieve
  first attempts the original file. If that write fails, the same bytes are
  written to RecoveryStore immediately. The original failure stays visible,
  the session stays dirty because the original is stale, and a successful
  recovery fallback changes the condition from data loss to ordinary status.
- **One live buffer owns exactly one recovery identity.** Repeated edits,
  debounce ticks, close flushes and quit flushes update that item in place.
  A rename/rekey of that same live buffer preserves the identity; replacing the
  buffer with another document releases its claim so the launcher can offer the
  emergency copy immediately. Content equality is never used to collapse
  different buffers. A stale launcher row may not Save As or Discard an item
  currently claimed by a live buffer.
- **File-backed recovery is self-describing.** Its record persists the
  standardized original path in a `.source` sidecar. The launcher labels it
  **Unsaved changes — <filename>**, shows the full original path and timestamp,
  and states that this is an emergency copy. A file-backed recovery entry must
  never masquerade as another ordinary `umowa.md`/`Untitled.md`. Turning a
  record into an ordinary untitled draft must remove the old source association
  successfully before publishing its new payload; a stale sidecar must never
  redirect unrelated text back to the previous file.
- **Opening recovery never overwrites the original.** It opens a dirty recovered
  buffer, displays the original path, and waits for an explicit decision:
  **Save to Original / Save As… / Don't Save / Cancel**. Cmd+S on that buffer
  means Save to Original; Save As writes only the chosen destination. If Save
  to Original fails, Pensieve immediately refreshes that buffer's existing
  recovery item with the latest bytes while preserving the same recovery ID and
  original-path association. The buffer remains dirty and the original remains
  stale. Later edits keep updating that same item without clearing the honest
  stale-original/recovery-safe status. This recovery fallback protects the
  bytes but does not satisfy a Save decision made during document close or
  global quit: both operations remain vetoed until the original itself is
  current.
- **A successful save retires the recovery item.** Saving to the original or a
  new destination removes the item only after the destination write succeeds.
  A launcher-level Save As also registers that destination in Pensieve's
  working set, persists any required file bookmark and adds it to native
  Recents, but does not open or select it in the launcher.
  Don't Save removes it only as a conscious rejection. Cancel and any failed
  write leave both the buffer and recovery item intact. If the filesystem
  refuses to retire the recovery payload after Don't Save, document/tab close
  and Clear Open Files veto teardown: the buffer stays dirty and the item remains
  claimed for a safe retry. Global quit alone may continue after the explicit
  **Quit Anyway** confirmation; it then retains the claimed payload through
  process exit and warns that the copy may return in Recovered Drafts on relaunch.
- **An untouched empty draft closes silently.** A draft asks where to save only
  after it contains unsaved changes.
- **Content durability fails closed.** If an original-file write fails, Pensieve
  attempts the recovery fallback before allowing teardown. If neither the
  original nor RecoveryStore accepts the bytes, the window/quit remains open,
  the buffer remains dirty, and the error explicitly says the only copy is
  still in memory. A teardown notification is only a final backstop; it is not
  allowed to be the first place a fallible user-content write is attempted.
- **No test writes production Application Support.** Tests inject isolated
  stores; XCTest's shared fallback for Recovery, workspace metadata, index and
  document AI state is process-scoped under one temporary directory. Runtime
  smoke uses its own staged identity and support directory.

The durable unit pins cover periodic file-backed snapshots, auto-save fallback,
source metadata across store reload, non-overwriting recovery open, explicit
Save to Original success and failure, same-ID refresh with the latest recovered
bytes, one-buffer/one-record identity, and red-X/global-quit veto until the
original destination accepts the recovered buffer.

### Error surface (05.08) — UX SHAPE PENDING RATIFICATION

What an error the app records actually does on screen. The behavior below is
implemented and pinned; its **visual shape is a recommendation awaiting Monika's
ratification**, so the wording, colour and placement may still change without
changing anything in this section's rules.

**Two classes, chosen at the write site.** A failure is classified where it is
raised, never by matching its message text:

- **Status** (the default). The action was refused, a read failed, or some
  housekeeping did not land — and nothing the user typed is at risk. Examples:
  "Open a workspace folder before creating a workspace file", a workspace that
  will not open, a recovered draft that could not be saved under a new name
  (the draft file is still on disk, so the work survives), and a failed write
  to the original file whose RecoveryStore fallback succeeded.
- **Data loss.** Pensieve failed to put content anywhere durable AND the only
  remaining copy is the in-memory buffer. A failed original-file write may
  raise this condition provisionally, but an immediate successful recovery
  fallback resolves it to status. If the fallback also fails, data loss stays
  latched and close/quit is vetoed. Status is the default precisely so that the
  loud class stays opt-in: a new error has to be argued into it and cannot fall
  into it.

**One surface, and it is passive.** Pensieve has NO modal error path. Both
classes show the same standing line in the window that recorded the failure and
in no other (the state is per-window: `AppState.currentError` →
`DocumentWindowModel`). It sits between the document pane and the status bar,
and deliberately NOT behind the status bar's `documentHasEditableBuffer` gate —
the errors that most need saying can land in a window with nothing open. It is
passive in the strict sense: it never takes first responder, so it may appear
and disappear under a live editing session without moving the caret or
interrupting typing. It carries a dismiss button. Nothing times it out. Severity
changes the dressing — filled accent and a warning icon for data loss, the
status bar's own material for everything else — never whether the user is
interrupted.

**Data loss LATCHES; status does not.** The two live in separate state, and the
separation is the point:

- `DocumentWindowModel.statusError` — the passive message, freely overwritten
  and freely cleared by whoever wrote it.
- `DocumentWindowModel.unresolvedDataLoss` — a latch: content that reached no
  file and exists only in a buffer that dies with the process.
- `DocumentWindowModel.dataLossBannerDismissed` — visibility only, never safety.

Three rules follow, and each is pinned:

1. **A status message cannot displace an unresolved data loss** — not by being
   written, and not by being cleared. Around a dozen sites assign
   `lastError = nil` on their own unrelated success, and none of them know
   anything about a buffer whose content reached no disk. The banner keeps
   showing the loss while it is still true.
2. **Dismissing the banner does not reset the condition.** The latch survives,
   so an identical failure repeating on the next autosave tick has nothing new
   to say and the banner the user put away stays away. Without this a full disk
   would resurrect a dismissed banner every 1.5 seconds. One original-write +
   recovery-write attempt publishes one final compound failure identity; its
   two internal errors must not alternate the surface back open.
3. **A resolved loss that happens again IS news.** The dedupe is scoped to one
   unresolved condition, not to a message string forever, so the surface re-arms
   — dismissal included. A genuinely different failure arriving while the first
   is still unresolved also re-arms.

**What retires the latch.** Only `AppState.resolveError()`, called where a
durable write for that buffer actually lands: a successful original-file save,
`saveAs`, or recovery write. When the original stays stale but recovery lands,
the data-loss latch is retired and replaced by a status that explicitly says
the original was not overwritten.

Tests. `WindowErrorChromeRenderTests` drives a real window hosting the real
`ContentView` and measures the live layout, so "the banner is mounted" is read
from the window and not from a resolver; it holds all three latch rules on that
live surface plus the focus contract (typing continues, caret unmoved, first
responder unchanged) across the banner appearing and disappearing.
`WindowErrorSurfaceTests` pins the classification through real production paths
(a failing save, an unwritable recovery directory, a refused document creation)
and the same three rules at the state level.
`testAnImportWhoseRecoveryWriteFailsSurfacesAsDataLoss` holds the import chain
end to end.

Creating a new document must not force a recovery decision. A recovery item can only be deleted after:

- being saved as a regular file;
- being explicitly discarded;
- being closed with confirmed rejection of changes.

When closing an ordinary untitled recovery item, the app shows the native
**Save / Don't Save / Cancel** prompt and Save opens Save As. A recovery item
that protects an existing file shows **Save to Original / Save As… / Don't
Save / Cancel**. "Discard" appears only in the batch modal as **Discard All**.
No recovery item is removed without one of these explicit decisions.

---

## Batch close modal — FINAL shape (Monika, 03.08, after native-behavior analysis)

1. Default option: **Review Changes…** (step through documents one by one).
2. **Save All** — a convenience shortcut (deliberate extension; the native alert doesn't have it).
3. **Discard All** — a clear, destructive option.
4. **Cancel** — always safely aborts the operation.
5. Every ordinary untitled recovery document gets its own native **Save As**.
   File-backed recovery offers **Save to Original** or **Save As…**; neither
   route writes automatically under a generated name.
6. Zero rollback for completed saves.
7. Recovery disappears only after a successful save or explicit rejection.

Review order: active tab first, then left to right
(predictability; macOS does not mandate this order — a deliberate choice).

Discard All requires an extra confirmation (this morning's spec; deliberately
more cautious than the native Discard Changes — relevant for recovery items).
Micro-refinement to consider during implementation: narrowing the
confirmation to only batches that contain recovery items.

The two deliberate extensions over AppKit's native batch alert are normative
and must not be "corrected" back toward pure nativeness: **Save All** is an
additional convenience action, and **Discard All** requires the extra
confirmation described above.

`Save All` runs in this order:

1. Save dirty files that already have paths; they need no picker.
2. Visit untitled and recovery tabs one at a time, active tab first and then
   left to right, presenting a separate native **Save As** picker for each.
3. After a successful Save As, assign the chosen path to the untitled tab. A
   recovery item may be retired only after the file is confirmed on disk.
4. Canceling any picker aborts the whole Close All. Completed saves remain;
   canceled and not-yet-visited tabs retain their content and dirty/recovery
   state.
5. A save error stops on that file, keeps the window open, and never retires its
   recovery item. The user may retry, switch to **Review Changes…**, or cancel.

`Cancel`, dismissing a picker, and a save error are never equivalent to
`Discard`.

## Close All Open Files

If all files are saved and no recovery item requires a decision, the app may close all files without an additional prompt.

Otherwise it shows the batch modal in its FINAL shape
(section above): **Review Changes…** (default) / **Save All** /
**Discard All** (with confirmation) / **Cancel**.

Close All must never cause silent data loss.

---

## Session and restore at launch (finalized 10.08.2026)

- **Workspace is configuration — it always comes back** (decision 26.07, W9). The
  "Restore session on launch" toggle controls only the files that get opened
  and the auto-select. Workspace roots remain indexed and protected in either
  setting; they are not session entries and do not expire.
- With restore OFF, a cold launch creates exactly **one empty launcher** and
  opens zero documents. Workspace roots and the sidebar still return.
- With restore ON, Pensieve restores the saved working set and its selection.
- Startup restore opens at most **12 most recent** files of the working set
  (decision 03.08, interim pending a true session snapshot — target model:
  "tabs from the moment of quit", variant b from 31.07).
- Restore **must not undo a deliberate Close** by the user.
- **Trash is dead** (decision 26.07): a file whose bookmark points into a Trash
  does not exist for the app. Membership is asked of the filesystem (every volume
  has its own Trash, a sandboxed build a container-relative one), not matched
  against a hardcoded `~/.Trash`, so a directory merely NAMED `.Trash` is not one.
  The fallback for a missing volume accepts only the real mount-root shape
  `/Volumes/<volume>/.Trashes/<uid>/...`; a nested user folder with the same
  component names is ordinary content.
  The rule holds at every point a file can become, or stay, an open document:
  - launch restore drops such an entry and its bookmark;
  - a **running** app retires a workspace file on the next watched scan commit.
    An ad-hoc file outside every workspace root is reconciled when Pensieve
    becomes active again (for example, after returning from Finder), so its row
    also leaves Open Files without waiting for a relaunch;
  - opening one is refused with "<name> is in the Trash. Put it back to open it.",
    so no route (Recents, drag, a stale sidebar row) can re-add it;
  - selecting one refuses to put its content in the editor and retires the row;
  - after Pensieve's own **Move to Trash**, bookmarks are pruned by where they
    LAND, which also covers every document inside a trashed folder. If the
    selected buffer had already produced an emergency recovery copy, clearing
    that buffer releases its live ownership claim but does not delete the copy:
    the single recovery entry becomes immediately available for an explicit
    Save / Save As / Don't Save decision instead of staying hidden until the
    next process launch. It never recreates the trashed original automatically.

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
  then re-add it as a workspace root. **[IMPLEMENTATION GAP]**:
  this PR only implements the individual-file half of "Trash is dead"; the
  root half described here is decided but not yet built.

- **Removing one workspace root never revokes another tab's access.** The
  persisted bookmark set is rebuilt from the UNION of the working set and the
  live tab chain across every window: a document of the removed root that a
  window still has open gets a file bookmark of its own, a document covered by a
  surviving root does not (its root already grants access), and a file that is in
  neither source still loses its bookmark — nothing is resurrected. In the
  sandboxed lane every freshly minted bookmark is resolved before old grants are
  released, and the resolved security-scoped URL is the one activated; a plain
  `DocumentRef` URL is not treated as if it carried a grant.
- **Quit gives the working set a bounded durability flush.** Quit starts an
  explicit `cfprefsd` synchronization and waits for it for up to one second
  before continuing with the remaining drain phases. A normal flush is durable
  before exit; a stalled system service may finish on its own schedule after the
  budget expires (measured at up to ~14 s after exit). The bounded wait is a
  deliberate tradeoff: working-set restoration can be stale in that exceptional
  case, but quit must not beachball indefinitely and user-content writes retain
  priority over session metadata.
- **Single source of truth for the session: Pensieve** (decisions 7–9: A,
  Monika + Maciej, 10.08). Every managed launcher/document window opts out of
  AppKit Saved Application State (`isRestorable = false`), and there is no
  value-based SwiftUI document `WindowGroup` for macOS to revive independently.
  Existing legacy Saved Application State may remain on disk, but Pensieve
  ignores its document/window payload: it never deletes user files, bookmarks,
  workspace configuration or the app's working set while doing so.

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
- [ ] `Cmd+N` does the same as `Cmd+T` in v1: it preserves the current buffer
      and creates a native tab; an idle launcher may fill in place.
- [ ] Repeated New commands (`file → Cmd+N → Cmd+T`) add one tab per command;
      a newly created empty tab is never mistaken for the idle launcher.
- [ ] `Cmd+O` opens the file picker, `Shift+Cmd+O` the folder picker (workspace).
- [ ] `Cmd+S` saves an existing file, and for untitled it triggers Save As.
- [ ] `Shift+Cmd+S` triggers Save As.
- [ ] `Cmd+W` and the tab's `X` close the active tab and protect dirty buffer/recovery.
- [ ] The system `X` protects dirty/recovery buffers, then closes the last
      window without an automatic reopen; the process stays alive with zero
      windows, and a later Dock click creates exactly one empty launcher.
- [ ] With Settings (or About) as the only remaining window: a Finder open of a
      `.md` file opens it in a new document host, and a Dock click creates
      exactly one empty launcher.
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
- [ ] With a live provider/onboarding sheet, opening or restoring another file
      never gives the sheet a document tab bar, changes the sheet's frame into
      a document frame, or moves document navigation outside its root window.
- [ ] Startup restore keeps one pinned document host across run-loop turns;
      provider onboarding appears only after all restored tabs have joined and
      the final tab has been selected.
- [ ] Window-lifecycle fixtures that call `beginSheet`, `addChildWindow`,
      `addTabbedWindow`, or `makeKeyAndOrderFront` are parked offscreen and set
      to zero alpha before AppKit can order them; test chrome must never flash
      on the operator's desktop.

---

## Open decisions and implementation gaps

**Current list:**

- **[IMPLEMENTATION GAP]** workspace ROOT in Trash: behavior
  **RESOLVED (Monika, 2026-08-05)** — same rule as files (see the
  "Trash is dead" section above); not yet built in this PR;
- **[IMPLEMENTATION GAP]** `Shift+Cmd+T` Reopen Closed Tab:
  shortcut **RESOLVED (Monika, 2026-08-05)** — reserved for this feature
  (see the `Shift+Cmd+T` section above); the feature itself is not yet
  implemented.

**To be inventoried in v0.2** (exist in the UI, semantics to be written down):
markdown formatting (`Cmd+B` / `Cmd+I` / `Cmd+K` — the toolbar has
bold/italic/link), switching editor/split/preview mode, sidebar toggle,
zoom `Cmd+±0`. **`Shift+Cmd+N` reserved** — nothing is assigned to it in v1.

Settled behavior belongs in the normative sections above, not in this list.
In particular, `Cmd+W` and Open Files, the last-tab launcher, system-window
close, and the batch-close/Save All sequence are resolved contracts.
