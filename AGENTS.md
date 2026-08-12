# pensieve — Repo Guidelines

<!-- Per-repo, agent-agnostic instructions. Edit below this line. -->

Native macOS markdown editor. Swift 6 / SwiftPM, AppKit + SwiftUI, GRDB for the
search index, a vendored Rust FFI dylib (`qube-ffi`) for the Vista bridge.

## Before you change anything

```bash
make            # target list
make test       # unit + integration (swift test)
make lint       # swift-format lint — required, fails if swift-format is missing
make gates      # test + lint + semgrep — what CI runs
```

`make gates` is the bar. Green gates are necessary, not sufficient — see the
runtime notes below for what they do _not_ cover.

## Working agreements

- **Living Tree.** Agents share one directory; concurrent edits are expected.
  Re-read files you touched if time has passed. Never revert someone else's work
  without being asked. A dirty worktree is usually intentional.
- **Commits** are titled `[<agent>/<workflow>] <description>` with a non-empty
  body describing the change as a bulleted list. Attribution goes in
  `Authored-By: <agent> <agents@vetcoders.io>` — the agent that actually wrote
  the code, one line each for collaborative work.
- **Push, merge, tag and release are operator decisions.** Do the work, run the
  gates, report — then stop.

## Layout

```
Pensieve/Sources/Pensieve/
  App/         windows, lifecycle, launch intents, settings, commands
  Storage/     DocumentStore, BookmarkStore, RecoveryStore, IndexDatabase
  Sidebar/     workspace tree, rename, open-files list
  Editor/      text editing, AI session, formatter
  Preview/     rendering, themes
  Search/      index-backed workspace search
  Workspace/   substrate, cache, scanning
scripts/       build-release.sh, ui-smoke.sh, semgrep-with-policy.sh
docs/          runtime-testing canon, product contract, architecture notes
```

## Traps worth knowing before you edit

**Document identity is not unified.** Five stores key documents differently
(working set by URL, registry by identity, bookmarks by path, recovery by UUID).
Any operation that opens, closes, renames or forgets a document has to reach all
of them by hand. Read `docs/architecture/document-identity.md` before touching
that area — it is the single largest source of click-to-reproduce bugs here.

**`DocumentStore.swift` is a hub.** Its consumer count changes quickly as the
lifecycle surface evolves; run `loct impact` on it before changing a signature
instead of relying on a historical count.

**`dist/Pensieve.app` and `make run-release` use production identity and
production state; `make run` is also non-isolated.** These are not clean smoke
lanes: they may restore or write the operator's real support, Keychain,
workspaces, files, drafts, recents, and window state. Use
`make manual-smoke` for a fresh interactive identity, its `-reopen`, `-verify`,
and `-clean` companions for the same experiment, or `make ui-smoke` for an
automated ephemeral run. Each independent scenario owns a unique,
manifest-scoped runtime identity, verifies trusted build provenance and exact
executable/FFI payloads before launch, and fails closed rather than touching
`io.vetcoders.pensieve` or production state. Historical or dirty-source runs
are explicitly labelled and are not release evidence. Low-level identity,
cleanup, compatibility and evidence rules live only in the canonical
`docs/runtime-testing.md` contract.

**`ui-smoke.sh` runs under whatever `bash` is first on PATH.** The shebang is
`#!/usr/bin/env bash`, so a clean environment picks the system bash 3.2. Empty
arrays under `set -u`, and heredocs nested inside `$(...)`, are fatal there and
fine under Homebrew's bash 5. Verify with `/bin/bash -n scripts/ui-smoke.sh`,
not just `bash -n`.

**Unit tests must not present native window fixtures on the operator's
desktop.** An AppKit test may allocate only an unshown `NSWindow` or `NSPanel`
constructed with the literal argument `defer: true` to pin inert window
properties. The default `NSWindow()`/`NSPanel()` constructors, `defer: false`,
and merely parking a fixture offscreen are not isolation: they allocate a real
WindowServer object. A unit test must not call `beginSheet`, `addChildWindow`,
`orderFront`, `makeKeyAndOrderFront`, or otherwise attach/order that fixture.
Inject relationship seams and synthetic notifications instead. A scenario that
must exercise real ordering belongs in a uniquely isolated runtime smoke and
must be announced before it can take focus.

**Suppressions carry rationale.** `.semgrep-policy.json` records accepted
findings with a `decision` and a `rationale` field. If you need to silence a
finding, add it there with a reason — do not sprinkle inline ignores.

## What the gates do not cover

- **CI only triggers on `main`, `fix/**` and `feat/**` base branches.**
  `.github/workflows/ci.yml` has `pull_request: branches: ["main", "fix/**",
"feat/**"]`, so a stacked PR based on a `fix/*` or `feat/*` branch still gets
  checks; a PR based on any other branch prefix gets none. Run `make gates`
  locally and say so in the PR when the base branch is outside that list.
- **`ui-smoke` is not part of `make ci`.** It is operator-side and ad hoc.
- **Semgrep does not parse every file.** The gate passes with parser warnings;
  a Swift construct it cannot parse silently drops that whole file from the
  scan. Watch the parser-warning count, not just pass/fail.
- **prview reports profile `Generic` on this repo**, which means its packs run
  no Swift gates at all. Its `CONDITIONAL` verdicts say nothing about the code.

## Release

```bash
make release            # signed + notarized .app + .dmg (Developer ID)
make release-appstore   # sandbox-signed .app + .pkg (Mac App Store)
make install-app        # local install into /Applications
```

Both release lanes are gated by `make gates`. The App Store lane has its own
identities, entitlements and checklist — see `docs/appstore-lane.md`.

If `make release-clean` dies with `Directory not empty`, a live SourceKit
indexer is racing the delete; use `make clean && make release` instead.
