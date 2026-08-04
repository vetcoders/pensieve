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
docs/          landing page (index.html) + architecture notes
```

## Traps worth knowing before you edit

**Document identity is not unified.** Five stores key documents differently
(working set by URL, registry by identity, bookmarks by path, recovery by UUID).
Any operation that opens, closes, renames or forgets a document has to reach all
of them by hand. Read `docs/architecture/document-identity.md` before touching
that area — it is the single largest source of click-to-reproduce bugs here.

**`DocumentStore.swift` is a hub** with 20 direct and 56 transitive consumers.
Run `loct impact` on it before changing a signature.

**`make ui-smoke` runs against an isolated smoke identity, not the operator's
app.** It stages a renamed, re-signed copy of the built app under
`$SMOKE_ROOT` as `PensieveSmoke` (bundle id `io.vetcoders.pensieve.smoke`) and
drives that — a separate process name, defaults domain, and support directory
from the operator's production instance in `/Applications`. See
`scripts/ui-smoke.sh` for the identity-isolation rationale.

**`ui-smoke.sh` runs under whatever `bash` is first on PATH.** The shebang is
`#!/usr/bin/env bash`, so a clean environment picks the system bash 3.2. Empty
arrays under `set -u`, and heredocs nested inside `$(...)`, are fatal there and
fine under Homebrew's bash 5. Verify with `/bin/bash -n scripts/ui-smoke.sh`,
not just `bash -n`.

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
