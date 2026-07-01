# Contributing to Pensieve

Welcome to the 𝚅𝚒𝚋𝚎𝚌𝚛𝚊𝚏𝚝𝚎𝚍. forge. 

We build software differently here at Vetcoders. We value *product truth* over local elegance, and *runtime truth* over theoretical correctness. If you want to contribute, please understand our core stance.

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

- **Requirements:** macOS 13.0 (Ventura) or newer, Xcode 15+, Swift 5.9+.
- Open `Pensieve/Package.swift` in Xcode.
- No CocoaPods or Carthage. We use Swift Package Manager exclusively.