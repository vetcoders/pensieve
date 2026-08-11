# Pensieve Runtime Testing

> **Canonical for runtime identity, state isolation, and smoke-test cleanup.**
> Owner: Monika. Established 2026-08-11.

Repository gates prove source-level properties. Runtime checks prove the macOS
application that was actually launched. Those are different claims, and every
runtime report must name both the artifact and the state identity it exercised.

The product behavior being checked remains canonical in
[`keyboard-shortcuts-and-file-lifecycle-contract.md`](keyboard-shortcuts-and-file-lifecycle-contract.md).
This document is the single source of truth for preparing, launching, verifying,
reopening, and cleaning a runtime test identity.

## The non-negotiable boundary

`dist/Pensieve.app` is a production-identity application bundle. It has bundle
identifier `io.vetcoders.pensieve` and reads the same production preferences,
workspace bookmarks, recovery records, recent documents, caches, and other
user state as an installed Pensieve build. `make run-release` builds and opens
that bundle. It is useful for an intentional production-state check, but it is
**not a clean smoke test**.

Never diagnose a workspace, recovered draft, recent file, or restored window as
a smoke leak merely because it appeared after opening `dist/Pensieve.app`: that
bundle is expected to see production state. Conversely, never call a check made
with that bundle a fresh-start result.

Smoke testing must use the repository-owned smoke lanes below. A lane may read
and copy the signed production-identity bundle as an immutable source artifact;
it must never launch that source bundle or read, write, quit, reset, unregister,
or delete the production process or mutable production state.

The current smoke lanes accept only the non-sandboxed Developer ID product
bundle (`io.vetcoders.pensieve`, executable `Pensieve`). They reject an already
rewritten smoke app and reject the Mac App Store sandbox lane: sandboxed state
lives in container namespaces that this cleanup contract intentionally does not
claim to own. A MAS runtime harness requires its own container-aware contract.

Every smoke lane also fails closed on source provenance. A release build seals
`PensieveBuildProvenance.plist` inside the signed bundle. It binds the full Git
commit to a deterministic digest of every runtime-producing source and release
recipe input, plus canonical runtime-payload SHA-256 identities for the main
executable and embedded `qube-ffi` payload. The payload canonicalization removes
the code-signature blob and non-runtime debug/linkedit bookkeeping; this makes
the identity stable across Developer ID and smoke-only re-signing without
ignoring code, data, exports, relocations, or dylib load commands. Staging
accepts only a strictly signed source whose outer bundle, main executable, and
embedded FFI library all satisfy Apple's Developer ID designated requirement
and the repository's exact Team identity (`MW223P3NPX`). A matching Team string
or commit stamp by itself is not provenance. The harness verifies that sealed
evidence before copying and verifies the copied payload again before changing
its identity.

For a normal run the sealed commit must equal the current worktree `HEAD`, its
input digest must equal the current runtime inputs, and those inputs must be
clean. A clean profile running stale or substituted code is not a fresh smoke.
Historical-bundle and dirty-source experiments require separate, lane-specific
opt-ins. A historical artifact is accepted only when its sealed runtime digest
can be reproduced independently from that exact commit; a dirty historical
artifact is always rejected. The dirty override applies only to an artifact
labelled with the current `HEAD`, and only when the current compiler-visible
bytes still match its sealed digest. Neither override can bypass the
Apple-anchored Developer ID policy, exact Team identity, canonical product
shape, release configuration, architecture, FFI profile, entitlements,
hardened runtime, embedded manifest, or executable/FFI payload checks. Neither
is appropriate for release evidence.

The opt-ins are deliberately verbose and lane-scoped:

| Lane          | Historical artifact                          | Dirty runtime sources                        |
| ------------- | -------------------------------------------- | -------------------------------------------- |
| manual        | `PENSIEVE_MANUAL_SMOKE_ALLOW_STALE_SOURCE=1` | `PENSIEVE_MANUAL_SMOKE_ALLOW_DIRTY_SOURCE=1` |
| automated UI  | `PENSIEVE_UI_SMOKE_ALLOW_STALE_SOURCE=1`     | `PENSIEVE_UI_SMOKE_ALLOW_DIRTY_SOURCE=1`     |
| BUGMAP        | `PENSIEVE_BUGMAP_ALLOW_STALE_SOURCE=1`       | `PENSIEVE_BUGMAP_ALLOW_DIRTY_SOURCE=1`       |
| search-memory | `PENSIEVE_SMOKE_ALLOW_STALE_SOURCE=1`        | `PENSIEVE_SMOKE_ALLOW_DIRTY_SOURCE=1`        |

Set an override only on the single command that needs it. An override changes
the experiment's provenance classification; it does not make that run fresh,
current-head, or release evidence. Ordinary smoke runs should rebuild the
source bundle and use no override.

## Runtime lanes

| Command                    | Identity and lifetime                                                             | Intended use                                                                                                                                            |
| -------------------------- | --------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `make run`                 | Unbundled development executable with non-isolated support and Keychain fallbacks | Deliberate development run. Never a clean smoke.                                                                                                        |
| `make run-release`         | Production bundle and production state                                            | Deliberate check against the operator's real Pensieve configuration. Never a clean smoke.                                                               |
| `make manual-smoke`        | Creates and opens a new, clean, unique identity for one experiment                | Interactive runtime testing. Every invocation starts a new experiment rather than inheriting an earlier smoke.                                          |
| `make manual-smoke-reopen` | Reopens the current manual-smoke identity without resetting it                    | Relaunch, restoration, recovery, and persistence checks within the same experiment.                                                                     |
| `make manual-smoke-verify` | Read-only verification of the current manual-smoke identity                       | Proves that the running/staged app and every state namespace still belong to that experiment.                                                           |
| `make manual-smoke-clean`  | Scoped retirement of the current manual-smoke identity                            | Quits only that app, removes only that experiment's state, unregisters only that staged bundle, and retires the experiment record.                      |
| `make ui-smoke`            | Automated, ephemeral, unique identity per independent scenario                    | Accessibility-driven product smoke. Scenario capsules own their mutable state; the invocation owns only shared witness files and the capsule directory. |
| `make bugmap-smoke`        | P0 matrix composed from isolated UI-smoke and one unique evidence identity        | Runtime regression evidence without opening or terminating the production app.                                                                          |
| `make smoke-search-memory` | Unique identity retained only for one generated indexing experiment               | Memory/index profiling whose mutable app profile is retired while the synthetic vault and forensic report remain.                                       |

`manual-smoke-reopen`, `manual-smoke-verify`, and `manual-smoke-clean` operate
only on the current experiment created by `manual-smoke`. They must fail closed
when there is no unambiguous active experiment. They must not guess from a
bundle name, a broad process match, Spotlight, or an arbitrary application with
a similar identifier.

Within one manual experiment the identity stays stable. That is intentional:
relaunch tests need to observe the state written by the preceding launch. A new
`make manual-smoke` starts a different identity and therefore a different state
capsule. The active capsule lives under repository-local `.runtime/manual-smoke`,
outside `dist`, so `make clean` cannot delete a live bundle or its manifest.
Its bundle path, executable name, support path, defaults domain, and Keychain
service all include the experiment token and are never reused by the next run.

## What one smoke identity owns

The run token must namespace every **known** stateful macOS surface in the
bounded cleanup contract together. Changing only the application name or only
the support directory is not isolation. This is not a claim that macOS can
never add another bundle-keyed surface; the final census is deliberately
explicit so a new surface must be added to the contract rather than swept by a
broad delete.

| Layer                      | Required isolation                                                                                                                                                                                                                                                                                                                                                                       |
| -------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Process and executable     | The staged executable has a smoke-only process name, and runtime verification resolves the exact PID back to the exact staged executable path. Lifecycle control retains one exact `NSRunningApplication` identified by bundle ID, bundle path, executable path, and PID; it never sends a raw signal to an app after a separate PID check and never targets `Pensieve` by a broad name. |
| Bundle and defaults        | A unique per-scenario bundle identifier owns a unique `UserDefaults` domain, its exact plist, and matching `Preferences/ByHost/<bundle-id>.*.plist` files.                                                                                                                                                                                                                               |
| Application Support        | `PENSIEVE_SUPPORT_DIR` points to a run-owned absolute directory containing Recovery, `workspace.json`, workspace caches, `index.db`, and document AI sessions.                                                                                                                                                                                                                           |
| Keychain                   | `PENSIEVE_KEYCHAIN_SERVICE` is unique per run. A smoke must neither read nor delete the production completion-provider item.                                                                                                                                                                                                                                                             |
| Open Recent                | `NSDocumentController` operates under the run bundle identifier. An earlier smoke's `.sfl4` list is never an input to a new run.                                                                                                                                                                                                                                                         |
| Saved Application State    | Any state belongs to the run bundle identifier. Managed Pensieve windows still opt out of AppKit document restoration; the smoke namespace prevents legacy state from another run becoming an input.                                                                                                                                                                                     |
| Caches and framework state | The bounded namespace includes the exact bundle-ID paths under `Caches`, `WebKit`, `HTTPStorages`, `Cookies`, `Containers`, and `Application Scripts`. The Developer ID lane does not claim sandbox-container semantics merely because it retires an incidental exact container path.                                                                                                    |
| LaunchServices             | The exact staged bundle is registered for the experiment and unregistered before that bundle is removed. Cleanup never performs a global LaunchServices reset.                                                                                                                                                                                                                           |

The run's schema-4 identity manifest has an explicit, one-way state machine:

```text
atomic reservation (cleanup-only authority)
  -> staging
  -> atomic finalized manifest derived from the staged bundle
  -> bundle verification
  -> launch
```

The reservation records only the prevalidated, exact cleanup coordinates and a
nonce. It exists before any partial bundle or mutable namespace can be created,
so an interrupted staging attempt remains safely retireable. A reservation can
never authorize bundle verification or launch. Finalization re-derives the
artifact facts from the completed staged bundle, requires every reserved
coordinate to agree, and atomically replaces the reservation. Only the
finalized manifest records and proves the trusted source Team ID and sealed
source commit/input/main/FFI identities.

A process name or commit stamp alone is not identity proof. The owner root must
be a canonical real directory owned by the current user, and the manifest,
bundle, and support path must be non-symlink direct children. Legacy
single-phase manifest schemas cannot authorize verification or launch. Cleanup
accepts either a valid schema-4 reservation or a valid schema-4 finalized
manifest, because both name the same bounded run-owned cleanup surface. It
refuses aliases and preserves the manifest whenever complete retirement does
not succeed.

## Fresh-start preflight

Before the first witness document is opened, a new smoke must fail closed unless
all of the following are true:

1. The immutable source bundle is strictly signed by Team `MW223P3NPX`; its
   sealed build-provenance manifest, current runtime-input digest, canonical
   main executable payload and canonical FFI payload all agree with one another and
   with the current worktree.
2. No process from that new identity is already running.
3. The staged `Info.plist`, executable, code signature, bundle identifier,
   support override, Keychain service, and build commit match the run manifest.
4. The run's Application Support directory is empty.
5. Its defaults domain is absent or empty, including all three workspace keys:
   `Pensieve.openFolder.bookmark`, `Pensieve.workspace.rootBookmarks`, and
   `Pensieve.workspace.fileBookmarks`.
6. Its Keychain service has no API-key item. `errSecItemNotFound` is clean;
   inability to query the item is not.
7. Its native Open Recent list, Saved Application State, ByHost preferences,
   caches/framework stores, container path, and Application Scripts path are
   absent.
8. The launched PID resolves back to the exact staged bundle and executable,
   not merely to an application sharing its display name.
9. The first UI census remains stable across repeated samples and shows one
   empty launcher, zero workspace roots, zero
   Open Files entries, zero Recovered Drafts entries, and zero Recent entries.

Only after that baseline passes may an automated smoke seed its witness files or
an operator begin an interactive manual scenario. A reset command that ignores
errors without a read-back is not evidence of a clean state.

Independent scenarios inside one automated run do not share an application
identity. The harness retires the exact process and profile, requires a bounded
quiet census, then mints a new UUID and atomically derives a new process name,
bundle path, defaults domain, support root, Keychain service, and manifest. A
throwaway baseline capsule receives another UUID and is retired before the
actual product scenario is seeded. A late writer from one probe therefore has
no namespace the next probe reads.

## Reopen semantics

`make manual-smoke-reopen` deliberately preserves the current experiment's
state. Use it to test such behavior as:

- Restore session ON versus OFF;
- zero-window process followed by Dock-style reopen;
- recovery after a controlled abnormal exit;
- Open Recent and working-set persistence;
- whether Pensieve, rather than AppKit Saved Application State, is the only
  managed-document restore owner.

A preserved experiment is not a fresh launch. Reports must say whether the
evidence came from the initial clean launch or from a reopen of retained state.

## Verification and evidence

`make manual-smoke-verify` is read-only. It must report a non-zero result if the
active run cannot be resolved uniquely or if any recorded identity field has
drifted. At minimum it verifies:

- the exact application bundle and executable paths;
- the live PID set and bundle identifier;
- the support root and Keychain service embedded in the staged application;
- absence of production mutable-state paths from the run manifest (the
  immutable `sourceBundlePath` may point at `dist/Pensieve.app`);
- the source artifact's trusted Team ID and sealed commit, runtime-input,
  canonical executable-payload, and canonical FFI-payload identities;
- that every mutable path it reports is inside the run's owned scope.

A useful runtime report records the command, timestamp, host, branch and commit,
staged bundle path and identifier, whether the launch was fresh or reopened,
the relevant setting values, and the observed result. A screenshot or green UI
alone does not establish which application or state namespace produced it.

## Scoped cleanup

Cleanup follows a validated reservation or finalized manifest and is
deliberately narrow. Verification and launch still require the finalized
state:

1. quit the run's exact retained `NSRunningApplication`, using bounded
   graceful-then-force escalation only while its complete identity still
   matches;
2. prove that the process exited;
3. clear or retire only the run's Open Recent and Keychain entries; because
   `sharedfilelistd` can recreate an `.sfl4` file after exit, require a bounded
   quiet interval in which the exact run-owned path remains absent;
4. unregister the exact staged bundle while it still exists and judge success
   by an exact LaunchServices registry census, not by `lsregister`'s exit code;
5. remove only that run's defaults and plist, ByHost preferences, Saved
   Application State, exact `Containers` and `Application Scripts` paths,
   caches, WebKit, HTTP stores/cookies, support root, and staged bundle;
6. repeat the bounded known-namespace retirement until it has stayed empty for
   the required quiet interval, then perform a final exact LaunchServices
   census;
7. retire the active-run manifest only after every preceding step succeeds;
8. remove invocation-owned witnesses only after its current capsule has been
   retired successfully.

Cleanup must never target `io.vetcoders.pensieve`, `/Applications/Pensieve.app`,
or production `~/Library/Application Support/Pensieve`. It must never use a
global LaunchServices reset, global Recent Documents reset, broad Keychain
deletion, or an unvalidated recursive path.

An interrupted cleanup may leave the experiment available for inspection and a
later retry. It must not silently broaden its scope to make the cleanup appear
successful.

The isolation test is itself repository-safe when invoked from a Git hook.
`scripts/test-isolated-app.sh` clears inherited repository-local `GIT_*`
variables before creating its temporary Git fixtures, because `git -C` does not
override an exported `GIT_DIR`. It also pins the host repository's `HEAD`, index,
and worktree before and after the run. A synthetic fixture must never create a
commit on, switch, stage, or otherwise mutate the branch being validated.

## Choosing the right lane

- Use `make gates` for source-level confidence.
- Use `make ui-smoke` for the deterministic automated runtime matrix.
- Use `make manual-smoke` when a person needs to click, type, move windows, use
  Mission Control, or inspect a lifecycle transition interactively.
- Use `make manual-smoke-reopen` only when retaining the current experiment is
  part of the test.
- Use `make run-release` only when intentionally testing with production
  identity and production state.

Green gates, a signed bundle, a fresh manual smoke, and a production-state run
are four bounded pieces of evidence. None silently substitutes for another.
