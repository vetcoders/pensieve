# Contributing to Pensieve

Welcome to the 𝚅𝚒𝚋𝚎𝚌𝚛𝚊𝚏𝚝𝚎𝚍. forge.

We build software differently here at Vetcoders. We value _product truth_ over local elegance, and _runtime truth_ over theoretical correctness. If you want to contribute, please understand our core stance.

## Our Core Stance

1. **Be an explorer, not a caretaker.**
   - Prefer bold simplification over timid preservation.
   - Clean replacement > patching scar tissue.
2. **Backward compatibility is optional.**
   - Do not preserve bad architecture just because it exists.
   - Keep compatibility only when it creates real user value.
3. **Vibecrafting is a valid engineering mode.**
   - Coding is art and craftsmanship. Great systems are shaped, not merely assembled.
4. **DoU is law.**
   - "Done" means repo health, runtime health, product surface, install path, discoverability, and customer readiness.

## How to Contribute

1. **Examine before you implement.** Use `loctree` to understand the blast radius.
2. **Discuss first.** For any major architectural changes, open an issue. We work closely with our founders to shape the vision.
3. **Write tests.** But prefer e2e coverage for real product pipelines over unit comfort.
4. **Respect the Living Tree.** We do not use git worktrees for active implementation. Adapt to concurrent edits.

## Development Setup

- **Requirements:** macOS 15.0 (Sequoia) or newer, Xcode 16+, Swift 6.0+ (Swift 5 language mode).
- Open `Pensieve/Package.swift` in Xcode.
- No CocoaPods or Carthage. We use Swift Package Manager exclusively.

## Runtime verification

Runtime identity is part of the evidence. `dist/Pensieve.app` and
`make run-release` use the production bundle identifier and the operator's real
Pensieve state; `make run` also uses non-isolated support and Keychain fallbacks.
None is a clean smoke test. Use `make manual-smoke` for a new isolated
interactive experiment or `make ui-smoke` for the automated ephemeral lane.
Reopen, verify, and clean a manual experiment only through its scoped
`manual-smoke-*` targets.

The isolation and cleanup rules are canonical in
[`docs/runtime-testing.md`](docs/runtime-testing.md). A runtime report that does
not identify the exact artifact, bundle identity, state scope, and whether the
launch was fresh or reopened is incomplete. The default lanes require sealed
build provenance from the trusted Team ID: current runtime inputs and the exact
main/FFI payloads must agree. Experimental overrides may relax current-source
comparisons, but never signature, Team, manifest, or payload verification; they
change the evidence classification and never count as release proof.
