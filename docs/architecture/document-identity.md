# Document identity: one intent, five stores

Read this before touching anything that opens, closes, renames, restores, or
forgets a document. It explains why a bug fixed in one place tends to reappear
in another.

## The short version

`DocumentIdentity` was introduced to be _the_ identity of a document, and
`persistentID` to be its one durable key. That unification reached the window
layer and stopped there. Five other layers still key documents their own way, so
every operation has to synchronise all of them by hand — and each forgotten
synchronisation is a separate, click-to-reproduce bug.

---

## What was intended

`Pensieve/Sources/Pensieve/App/DocumentSession.swift` defines:

```swift
enum DocumentIdentity: Hashable {
  case file(URL)
  case untitled(UUID)
  case recovered(UUID)
}
```

Three cases covering exactly the three kinds of document the app can hold. Next
to it sits a durable key:

```swift
var persistentID: String {
  switch standardized {
  case .file(let url):  return "file:\(url.absoluteString)"
  case .untitled(let id): return "untitled:\(id.uuidString.lowercased())"
  case .recovered(let id): return "recovery:\(id.uuidString.lowercased())"
  }
}
```

A stable string, namespaced per kind, lowercased, built off `standardized` URLs.
That is a key designed for serialisation — the shape you build when several
stores are meant to name the same document with the same word.

The intent, then: **one identity, many indexes.** Working set, window registry,
bookmarks and recovery would be views over one entity rather than parallel
registries, and "forget document X" would be a single call.

## Where it stopped

`DocumentSession` defines `persistentID`. `DocumentWindowModel` consumes it as
the AI-session identity, while `DocumentWindowRegistry` includes it in identity
diagnostics. No persistence store uses it: the durable working set, bookmarks
and RecoveryStore still keep their own keys. The exact call-site count is not an
architectural invariant and must not be copied into this document.

---

## The five stores, and what each keys by

| Layer                     | Owner                        | Keyed by                                          | Survives relaunch |
| ------------------------- | ---------------------------- | ------------------------------------------------- | ----------------- |
| Working set (`openFiles`) | `AppState` / `DocumentStore` | `URL`                                             | via bookmarks     |
| Window registry           | `DocumentWindowRegistry`     | `DocumentIdentity` + `ObjectIdentifier(NSWindow)` | no                |
| File bookmarks            | `BookmarkStore`              | path + bookmark `Data` bytes                      | yes               |
| Workspace roots           | `BookmarkStore`              | separate defaults key                             | yes               |
| Recovery drafts           | `RecoveryStore`              | draft `UUID` + payload/sidecars                    | yes               |
| Untitled documents        | `DocumentSession`            | in-memory `UUID` + optional `recoveryID`          | only via recovery |

`BookmarkStore` alone holds three defaults keys:

```swift
private let legacyFolderBookmarkKey = "Pensieve.openFolder.bookmark"
private let rootBookmarksKey        = "Pensieve.workspace.rootBookmarks"
private let fileBookmarksKey        = "Pensieve.workspace.fileBookmarks"
```

The first is named `legacy` in the source — a single-folder bookmark superseded
by multi-root `rootBookmarks`. The migration started and the old path stayed.
That is the same half-finished pattern as `DocumentIdentity` itself, one layer
down.

One RecoveryStore record is not one filesystem object. Its UUID names a visible
Markdown payload (`.md`), a title sidecar (`.title`), and, for a file-backed
buffer, a required original-path sidecar (`.source`). The ownership claim that
keeps two live windows from adopting the same record exists only in process; a
crash drops the claim while leaving the record available at the next launch.

---

## How this shows up as bugs

Because no store is authoritative, every operation must fan out by hand. The
failures below are all instances of one missing fan-out, not six unrelated
defects:

- **Rename a folder** — `replaceReferences` compares `ref.url.path == sourcePath`
  exactly, while `removeReferences` handles descendants. Documents open from
  inside the renamed folder keep pointing at the old path.
- **Evict past the open-files cap** — `pruneOpenFilesWorkingSet` drops the row
  but leaves the bookmark, so launch restore resurrects a file the user can no
  longer close through the UI.
- **Open through a symlink** — `forgetFile` compares `standardizedFileURL`, which
  does not resolve symlinks, while bookmark resolution returns the canonical
  path. The entry never matches and the file comes back.
- **Close a document from another window** — identity routing exists in the
  registry, but the completion captures the _calling_ window's controller.

These are historical examples found first through runtime clicking because no
single type forced the stores to agree. Targeted regression tests now cover the
repaired paths; the underlying multi-store coordination risk remains.

The launcher-level recovered-draft Save As route now closes one of those fan-out
gaps explicitly: after the destination write succeeds it registers the file in
the working set, persists the ad-hoc bookmark when required, indexes it and adds
it to native Recents. It deliberately does not select or open the saved file in
the launcher that performed the rescue.

---

## Target shape

Make `persistentID` the actual key of every layer and reduce the rest to indexes
over one document registry. Concretely:

1. One registry maps `persistentID` → document record (URL or draft id,
   bookmark, recovery id, working-set membership, window).
2. `BookmarkStore`, `RecoveryStore` and the working set become lookups into that
   registry rather than independent sources.
3. `forgetOpenFile` becomes one call instead of one call per layer.

Two observable signals that the work is done: `legacyFolderBookmarkKey`
disappears, and no operation needs a per-layer checklist.

This is not a rewrite. `DocumentIdentity` already exists, is already `Hashable`,
and already covers all three kinds — PR #13 did the window half. What remains is
the persistence half.

---

## Until then: rules for touching this area

When you add or change an operation on a document, walk all six rows of the
table above and decide explicitly for each one. In particular:

- **Adding a way to close/remove a document?** An ordinary close/remove must
  reach `forgetOpenFile`, which clears the working-set row and matching
  bookmark. Trash is intentionally different: a moved bookmark resolves to its
  Trash landing path, so that lane uses `pruneTrashedFiles()` and releases its
  security scope through the cached pre-trash origin or, when no origin exists,
  through the bookmark blob itself.
- **Adding a way to create/save a document?** Compare against `saveAs` — that is
  the path that registers bookmark, working set and recents together.
- **Comparing paths?** Use one convention. `standardizedFileURL` does not resolve
  symlinks; `resolvingSymlinksInPath()` does. Mixed conventions across stores
  produce entries that never match.
- **Comparing a path that may no longer exist?** Use
  `BookmarkStore.identityPath`. Both `standardizedFileURL` and
  `resolvingSymlinksInPath()` drop a leading `/private` only while the target
  still exists, so a trashed file reads as `/var/…` from its live row and
  `/private/var/…` from its bookmark blob. `identityPath` folds that prefix for
  the three directories macOS publishes twice — `/private/var`, `/private/tmp`,
  `/private/etc`, the symlink aliases — and returns every other path untouched.
  It is an identity key, **not** a general canonicalizer: it resolves no
  symlinks of its own, it does not fold the alias roots spelled on their own,
  and it must never be handed back to the filesystem. Folding `/private`
  unconditionally is the bug this narrowing fixed — it fused `/private/foo` with
  an unrelated `/foo`, and with them their security-scoped grants.
  `FileWatcher.canonicalPath` folds the same three aliases for FSEvents paths;
  the two must stay in step.
- **Rewriting the whole persisted workspace?** `BookmarkStore.replaceWorkspace`
  is all-or-nothing on purpose, and its caller (`removeRoot`) has already changed
  the LIVE workspace by the time it hears about a failure — so a refused write
  leaves the removed root persisted and it comes back on the next launch. A
  working-set file that can no longer be minted a bookmark therefore does not
  abort the rewrite: its already-persisted blob is carried forward, matched by
  `identityPath` against the path the blob was minted for (`.pathKey` read out of
  the blob — resolution cannot answer for an unreachable file). A URL with no
  persisted blob still throws, because carrying nothing forward would mean
  inventing an entry. Anything else that a root removal persists — the exclusions
  in `workspace.json` — must move on the same side of that outcome, or a relaunch
  reads two halves of one workspace that disagree about which roots exist.
- **Adding persistence?** Key it by `persistentID`, not by URL. Every new
  URL-keyed store makes the eventual consolidation more expensive.
- **Touching `DocumentStore.swift`?** It is a high-fan-out hub and its consumer
  count changes as the app evolves. Run
  `loct impact Pensieve/Sources/Pensieve/Storage/DocumentStore.swift` against
  the current tree before changing a signature; do not rely on a historical
  count copied into documentation.

---

## Related

- `Pensieve/Sources/Pensieve/App/DocumentSession.swift` — the identity type.
- `Pensieve/Sources/Pensieve/App/DocumentWindowRegistry.swift` — the one layer
  that already uses it.
- `Pensieve/Sources/Pensieve/Storage/BookmarkStore.swift` — three defaults keys,
  one marked legacy.
- `Pensieve/Sources/Pensieve/Storage/RecoveryStore.swift` — drafts on disk.
