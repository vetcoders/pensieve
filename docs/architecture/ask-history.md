# Ask history

An Ask conversation owns a UUID and an immutable context: workspace roots, explicitly
selected files, and an optional untitled document ID. Changing context starts another
thread. Document and workspace identities are context metadata, not history keys.

`AskHistoryStore` saves conversations in `AskHistory.sqlite` under Pensieve's application
support directory, independently of the disposable search index. `PENSIEVE_SUPPORT_DIR`
and the automatic XCTest isolation root apply to history just as they do to the other
stores. Tests can also inject a database URL directly.

The `ask_history_v1` GRDB migration creates one `ask_threads` table. A row contains the
thread UUID, versioned context and turn payloads, the composer draft, and creation and
update timestamps. Updates preserve the original creation time and refuse to change
context under an existing UUID. Roots and document URLs are resolved to canonical paths
when the thread is created; persistence retains those exact absolute paths. Saving and
restoring do not resolve them again. If a canonical file or root becomes a symlink later,
the history still names its original path and the tool host denies the changed target.
Ad-hoc status, document root and relative-path metadata remain attached to each file.
History listing sorts by the last change.

There is no older on-disk Ask transcript format to import. The previous
`DocumentAskThread` and `WorkspaceAskThread` stored turns and drafts only in memory, and
`DocumentSession.askThreadID` was regenerated on document restoration. The migration
therefore creates the first durable history. It preserves any UUID supplied by the
current caller; it cannot recover conversations already lost when an older app exited.

Loading history decodes data without constructing an FFI agent, opening a document or
building a tool host. An interrupted assistant response keeps its saved text and returns
with `isStreaming = false`. Active tool approvals, host objects, pending image attachment
files and running requests are not resurrected. Turn attachment IDs remain as transcript
metadata. Tool access is reconstructed and checked from the thread context at the next
submit; stored paths do not establish file access or keep sandbox permissions alive.

Database, encoding, decoding and unsupported-format failures are thrown to the caller.
The UI owner must show an unavailable history or failed save explicitly rather than
treating a failure as an empty history list.

Both the Quit menu and AppKit termination hook stop streaming and flush history before
document consent. A failed save cancels termination unless the user explicitly chooses
**Quit Without Saving Ask History**. The failed transcript and draft remain in memory
when Quit is cancelled, so a later attempt can retry the write. Closing the Ask surface
or its owner window preserves the application-owned thread and flushes its checkpoint.
