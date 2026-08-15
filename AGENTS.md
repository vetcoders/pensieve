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

- **CI only triggers on `main`.** `.github/workflows/ci.yml` has
  `pull_request: branches: ["main"]`, so a PR based on another branch (stacked
  PRs) gets no checks at all. Run `make gates` locally and say so in the PR.
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

**The release unlocks its own build keychain.** The Developer ID identity lives
in a dedicated keychain (`~/Library/Keychains/pensieve-build.keychain-db` by
default), and a keychain's unlocked state belongs to the security session that
unlocked it. Unlocking it in a GUI session therefore does nothing for a release
driven over SSH: codesign fails there with `errSecInternalComponent`, minutes
into the build. `scripts/build-release.sh` unlocks it itself, inside the same
session that runs codesign, reading the password from
`~/.keys/.build-keychain-pw` (0600). Both paths are overridable via
`PENSIEVE_BUILD_KEYCHAIN` and `PENSIEVE_BUILD_KEYCHAIN_PASSWORD_FILE`; a machine
with no such keychain file is left alone entirely.

The unlock is re-asserted before every signing site, not just in pre-flight,
because a keychain's inactivity auto-lock can close it again while the run sits
in `swift build` or waits on notarization — deliberately, in preference to
raising the operator's auto-lock timeout, which would leave a persistent change
to their security posture behind. `security find-identity` is not evidence that
signing will work: it lists an identity out of a LOCKED keychain, since only the
private key is sealed.

With no password file the run continues rather than failing: signing may still
succeed because this session already holds the keychain open. The one case that
fails in pre-flight, with the remedy printed, is a locked keychain in a session
that cannot be prompted. That branch is the only caller of
`security show-keychain-info`, and it is fenced behind a GUI-session check for a
concrete reason: against a locked keychain that call is not a passive read, it
raises a SecurityAgent panel and blocks on it. Never lift it out of that branch,
and never let a test reach a real keychain — `scripts/test-build-keychain.sh`
shims `security` and `launchctl` on `PATH` and asserts the absence of that call
in the sessions that could pop a panel.

**The download page's checksum is stamped, not typed.** A lane that produces a
notarized DMG (`make release`, `make release-clean`, `make notarize`) rewrites
the single `class="sha"` slot in `docs/index.html` with the SHA-256 of the DMG
it just built, then verifies it — so commit `docs/index.html` together with the
release. Local lanes (`make release-local`, `make release-appstore`, any
`--no-notarize` run) never touch or gate on the page: the repo deliberately
keeps an unfilled placeholder between releases. A page that cannot carry this
build's checksum (missing, unreadable, read-only, reshaped, or advertising
another version) fails in pre-flight, before anything is built or published.

What is asserted — in pre-flight and again at the end of the run — is the whole
published claim: the checksum, the version in the panel's `<dt>Version</dt>`,
and every place the page hands the reader the artifact. That last one is an
exact census, not a spot check: the page carries three download targets (hero
button, panel button, JSON-LD `downloadUrl`), each `href`/`downloadUrl` value
must equal the `releases/latest/download/Pensieve.dmg` funnel this lane
publishes IN FULL, and there must be exactly three of them
(`LANDING_PAGE_ARTIFACT_LINK_COUNT`). Giving `docs/index.html` a fourth
download target therefore means bumping that constant deliberately. So editing
the version line or a download button of `docs/index.html` while a release is
in flight fails that release rather than publishing a mismatched page. Stamping
itself is concurrency-safe for the same reason: the page is rewritten by
renaming a fresh copy into place, and an edit that lands mid-stamp aborts the
run instead of being silently overwritten.

`scripts/lib/landing-page.sh` is a release runtime input like every other
release helper, so a release refuses to run with uncommitted edits to it and
seals it into the provenance digest. The release enumerates its helpers by hand
in several places — the snapshot archive in `scripts/build-release.sh`, the
digest and status lists in `scripts/lib/build-provenance.sh`, and the
dirty-input status list in `scripts/lib/isolated-app.sh` — and a helper added to
some of them but not all breaks a release lane rather than failing a test. A
helper is therefore added to EVERY such list at once;
`scripts/test-landing-page.sh` checks that structurally, by requiring any
multi-line helper list in those scripts to name every release helper.

`Permission denied` or `Directory not empty` while a release retires `dist/` or
`Pensieve/.build` is the read-only SwiftPM resource shape, not a race:
`Bundle.module` resources are copied `r--r--r--` inside `r-xr-xr-x` directories,
and unlinking a read-only child needs write permission on its parent. The
cleanup helpers in `scripts/lib/build-provenance.sh` unlock those exact derived
trees first, so `make release-clean` retires them without prompting. A live
SourceKit indexer repopulating `.build/index-build` mid-delete can raise the
same `Directory not empty` — that secondary race is what the rename-aside in the
`clean` target covers.
