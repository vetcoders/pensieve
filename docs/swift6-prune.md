# Swift 6 migration: repository prune inventory

Date: 2026-09-08. This inventory records the bounded prune alongside the Swift 6
migration. It is not a release or runtime acceptance receipt. The integrating
worker owns gates, installed-artifact verification, and the final release report.

## Evidence and scope

The scan covered tracked application sources, tests, scripts, manifests, docs,
hooks, and resources; generated dependencies and vendored implementation were
not candidates for blind source deletion. The runtime starts at `PensieveApp`,
with document lifecycle, editor, preview, search, transcription, provider, and
workspace components participating in the application. `Makefile` and
`scripts/build-release.sh` own build and delivery; isolated smoke contracts live
in `docs/runtime-testing.md`.

Loctree context, dead-export discovery, literal occurrences, slice and impact
were followed by tracked-file reference checks. The pre-prune dead scan reported
108 candidates, but only one at high confidence: `AIEditingTask`. Most other
results were protocol witnesses, native delegates, SwiftUI representables, or
methods with independently visible callers. They are not deletion evidence.
`DocumentAISession.swift` has 13 direct consumers and a broad transitive cone;
only the definition-only enum was removed from that live file.

## Decisions

| Classification               | Surface                                                          | Evidence and disposition                                                                                                                                                                                                                                                                                          |
| ---------------------------- | ---------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| DELETE-NOW, removed          | `Pensieve/Sources/Pensieve/Resources/Assets.xcassets`            | 125 tracked files, 52,809 bytes: 31 legacy image sets and an empty AppIcon catalog. No application named-image lookup consumes these assets; UI images use SF Symbols. Release uses `Pensieve/Resources/Pensieve.icns`. Removed the manifest resource entry with the directory.                                   |
| DELETE-NOW, removed          | `Pensieve/Sources/Pensieve/Resources/sample.md`                  | Legacy Japanese markdown sample had no runtime or test reader, only the packaging declaration. Removed both file and declaration.                                                                                                                                                                                 |
| DELETE-NOW, removed          | `AIEditingTask`                                                  | Six-line enum in `DocumentAISession.swift`; Loctree literal scan found one definition and zero reads or writes. Concrete continuation/rewrite/transcription paths do not consume this wrapper.                                                                                                                    |
| KEEP-BUILD                   | `scripts/test-isolated-app.sh` stale asset fixtures              | The script fabricates old `sample.md` and `Assets.xcassets` paths to prove retirement of read-only historical bundles. Removing current resources does not remove this regression risk.                                                                                                                           |
| KEEP-RUNTIME                 | Markdown/GFM CSS, Mermaid, KaTeX, bundled fonts and licenses     | Rendering and theme resource paths remain active; font directory shape and licenses are part of packaging.                                                                                                                                                                                                        |
| KEEP-BUILD                   | FFI bindings, module map, debug/release dylibs and FFI scripts   | The package links the selected FFI profile. Generated bindings and two build profiles are not duplicate product engines.                                                                                                                                                                                          |
| KEEP-BUILD                   | CI, hook libraries, security rules and isolated smoke helpers    | These enforce repository/release integrity. CI documentation was corrected to match actual PR base filters: `main`, `fix/**`, `feat/**`; pushes remain `main` only.                                                                                                                                               |
| KEEP-RUNTIME                 | Live lifecycle, search, provider, transcription and preview code | Low-confidence dead flags do not override explicit consumers or framework dispatch. No independently proven dead vertical subsystem was found.                                                                                                                                                                    |
| FORGOTTEN-GEM / VERIFY-FIRST | `scripts/scroll-trace.sh` and `.lldb`                            | Useful viewport/layout breakpoint recipe, currently self-contained and undiscoverable from Makefile/README. Its wrapper launches the raw debug executable with production identity. Preserve the technique; an isolated manifest-owned launch/attach path is required before advertising it as a safe diagnostic. |
| KEEP-BUILD                   | Public landing page, icons, metadata and product docs            | These are distribution/discovery surfaces, not application imports. Their absence from the Swift dependency graph does not establish deadness.                                                                                                                                                                    |
| KEEP-BUILD                   | `Pensieve/scripts/vendor-katex.sh`                               | No external script-name references, but it reproduces the two active KaTeX resources with embedded fonts. Maintenance tooling remains valuable without being called on every build.                                                                                                                               |
| FORGOTTEN-GEM / VERIFY-FIRST | `scripts/pensieve-wait`                                          | No in-repo external script-name references; intended external `VC_COMPOSER` integration opens the selected file with `--wait`. Cross-repository use is outside this inventory, so local non-reference is not grounds for removal.                                                                                 |

Loctree `impact` could not resolve the asset catalog because resource directories
are absent from its source snapshot. For that deletion, manifest ownership,
tracked literal references, every application image call site and release icon
routing supplied independent evidence.

## Silencers and test limitations

Baseline before concurrent Swift 6 changes, excluding generated
`VistaBridge/qube_ffi.swift` and vendor code:

| Category                              | Production | Tests |
| ------------------------------------- | ---------: | ----: |
| `@unchecked Sendable`                 |         14 |    55 |
| `nonisolated(unsafe)`                 |          2 |     2 |
| `XCTSkip`                             |          0 |     8 |
| Swift lint/format inline suppressions |          0 |     0 |
| Actual inline Semgrep suppressions    |          0 |     0 |

After migration, handwritten production code has one `@unchecked Sendable`
wrapper and one local `nonisolated(unsafe)` alias; tests have one unchecked
NSCondition fixture and no unsafe isolation declarations. Their ownership is
documented below. Generated UniFFI bindings are excluded from both counts.
No XCTest skip or Semgrep suppression was added.

Three `.semgrep-policy.json` exceptions remain documented: system trust instead
of certificate pinning for user-selected endpoints; a non-executable canonical
HTML link; and login-Keychain API-key storage compatible with Developer ID
signing after the documented entitlement failure. None was added by this prune.

The eight skip sites comprise headless toolbar/editor layout constraints, an
unavailable private AppKit menu selector, two pre-macOS-26 checks, locked login
Keychain access, and a recovery timeout. The recovery timeout already records
`XCTFail` before throwing, so it cannot turn missing persistence into a pass.
Headless fixture skips do not prove the skipped UI behavior; isolated runtime
coverage remains necessary. No skip was stripped into native window presentation
on the Founder's desktop.

## Verification ownership

The prune worker performed source/reference and diff checks without running a
parallel build. The integrating worker must run the repository gates and real
release/runtime path against the combined changes. No success, signing,
notarization or installation is attested by this inventory alone.

## Concurrency ownership after migration

The package requires Swift 6.2+ and selects Swift 6 language mode for the app
and test target. UI models, AppKit adapters, theme selection, syntax highlighting
and font resolution belong to MainActor. Detached filesystem/index operations
keep value snapshots and checked Sendable services; mutable shared caches and
recorders use Mutex or OSAllocatedUnfairLock with state stored inside the lock.
No package-wide concurrency checking reduction or preconcurrency import was added.

Two production interoperability boundaries remain deliberately narrow:

- `DefaultsFlush` wraps only the injected UserDefaults instance for detached
  `synchronize()`, retaining the bounded quit contract. Apple documents
  [UserDefaults as thread-safe](https://developer.apple.com/documentation/foundation/userdefaults).
  The wrapper cannot expose the rest of BookmarkStore across actors.
- TextKit's legacy `processEditing` override lacks actor annotations. A local
  unsafe reference is consumed synchronously inside `MainActor.assumeIsolated`
  after immutable edit snapshots are captured. No reference is stored or sent
  to a background task; UI editing still occurs after the superclass callback.

The remaining test unchecked boundary is `WatcherWalkGate`: NSCondition's
atomic release/wait/reacquire cycle is the synchronization contract tested there.
Generated UniFFI bindings retain their upstream ownership and are excluded from
handwritten-code suppression counts; regenerated bindings need their own FFI
provenance check. The Rust payload itself was not rewritten by this migration.

Actor-isolated destruction uses [SE-0371, implemented in Swift 6.2](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0371-isolated-synchronous-deinit.md).
See [Swift's migration guide](https://www.swift.org/migration/) for the language-mode
and data-race checking contract.

## Installation

`make install-built-app` installs the already built signed artifact after strict
provenance and idle checks. It never quits a running session, rebuilds the app,
or launches it as a side effect. The previous bundle is retained at the printed
transaction path. `make install-app` checks idle before its build and uses the
same installation transaction. Launch the installed bundle explicitly afterward.

## Security parser coverage

The full post-migration scan reports three accepted policy findings and 24
scanner diagnostics, compared with 20 at baseline. Four newly affected Swift
files use `isolated deinit`: `DocumentWindowModel.swift`, `EditorView.swift`,
`PreviewWebView.swift` (two spans) and `TranscriptionTaflaPanel.swift`. Semgrep
reports partial parsing around those destructor declarations, not a new
whole-file Swift syntax failure. The complete 24 comprise 21 partial parses,
two shell syntax parse failures and one JavaScript engine matching error.
Compiler checks and focused ownership review cover the new destructor code;
a passing Semgrep exit does not establish complete scanner coverage.
