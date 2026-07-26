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

`persistentID` has **four occurrences across three files** in the whole
repository:

| Site                               | Purpose                           |
| ---------------------------------- | --------------------------------- |
| `DocumentSession.swift:18`         | the definition                    |
| `DocumentSession.swift:83`         | `persistentAIDocumentID`          |
| `DocumentWindowModel.swift:38`     | `aiDocumentID` for the AI session |
| `DocumentWindowRegistry.swift:382` | a string inside a debug log line  |

No persistence layer uses it. The unifying key currently unifies one thing: the
AI conversation keyed to a document.

---

## The five stores, and what each keys by

| Layer                     | Owner                        | Keyed by                                          | Survives relaunch |
| ------------------------- | ---------------------------- | ------------------------------------------------- | ----------------- |
| Working set (`openFiles`) | `AppState` / `DocumentStore` | `URL`                                             | via bookmarks     |
| Window registry           | `DocumentWindowRegistry`     | `DocumentIdentity` + `ObjectIdentifier(NSWindow)` | no                |
| File bookmarks            | `BookmarkStore`              | path + bookmark `Data` bytes                      | yes               |
| Workspace roots           | `BookmarkStore`              | separate defaults key                             | yes               |
| Recovery drafts           | `RecoveryStore`              | draft `UUID`, one file each                       | yes               |
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
- **Save a recovered draft** — `saveRecoveredDraftAs` writes and indexes but
  skips the registration that `saveAs` performs, so the file lands in neither
  the working set nor recents and gets no security-scoped bookmark.
- **Close a document from another window** — identity routing exists in the
  registry, but the completion captures the _calling_ window's controller.

Each was found by clicking, not by a test, because no single type forces the
stores to agree.

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

- **Adding a way to close/remove a document?** It must reach `forgetOpenFile`,
  which is the choke point that clears the bookmark. Bypassing it is what makes
  files immortal.
- **Adding a way to create/save a document?** Compare against `saveAs` — that is
  the path that registers bookmark, working set and recents together.
- **Comparing paths?** Use one convention. `standardizedFileURL` does not resolve
  symlinks; `resolvingSymlinksInPath()` does. Mixed conventions across stores
  produce entries that never match.
- **Adding persistence?** Key it by `persistentID`, not by URL. Every new
  URL-keyed store makes the eventual consolidation more expensive.
- **Touching `DocumentStore.swift`?** It has 20 direct and 56 transitive
  consumers. Run `loct impact Pensieve/Sources/Pensieve/Storage/DocumentStore.swift`
  before changing a signature.

---

## Related

- `Pensieve/Sources/Pensieve/App/DocumentSession.swift` — the identity type.
- `Pensieve/Sources/Pensieve/App/DocumentWindowRegistry.swift` — the one layer
  that already uses it.
- `Pensieve/Sources/Pensieve/Storage/BookmarkStore.swift` — three defaults keys,
  one marked legacy.
- `Pensieve/Sources/Pensieve/Storage/RecoveryStore.swift` — drafts on disk.
