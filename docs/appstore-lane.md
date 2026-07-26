# Mac App Store lane

The App Store lane produces a sandbox-signed `.app` and an installer `.pkg` for
submission through App Store Connect. It is a separate lane from the Developer
ID lane that produces the notarized DMG — different entitlements, different
signing identities, different distribution channel.

Both `make info-appstore` and the end of a successful `--appstore` build point
here for the checklist below.

---

## The two lanes are not variants of each other

|                  | Developer ID (default)                     | Mac App Store (`--appstore`)                   |
| ---------------- | ------------------------------------------ | ---------------------------------------------- |
| Entitlements     | `Pensieve/Resources/Pensieve.entitlements` | `Pensieve/Resources/Pensieve.mas.entitlements` |
| Sandbox          | no                                         | **yes, mandatory**                             |
| Hardened Runtime | yes (`--options runtime`)                  | **no**                                         |
| Trust step       | Apple notarization + staple                | App Review                                     |
| Product          | `dist/Pensieve.dmg`                        | `dist/mas/Pensieve.pkg`                        |
| Identity source  | `~/.keys/signing-identity.txt`             | `PENSIEVE_MAS_*` env vars                      |
| Distribution     | direct download from the landing page      | App Store Connect                              |

Hardened Runtime is deliberately absent from the MAS lane — the App Sandbox
takes its place there, and adding `--options runtime` is at best a no-op and at
worst an App Review flag. Both lanes funnel through one `sign_code` helper in
`scripts/build-release.sh` so the three signing sites (dylib, executable,
bundle) cannot drift apart.

## What the sandbox grants

`Pensieve.mas.entitlements` is deliberately small. Every key earns its place:

- `com.apple.security.app-sandbox` — mandatory for MAS distribution.
- `com.apple.security.files.user-selected.read-write` — Pensieve is a file-first
  editor; the user grants folders and documents through `NSOpenPanel`.
- `com.apple.security.files.bookmarks.app-scope` — that access has to survive
  relaunch, which is what `BookmarkStore` persists.
- `com.apple.security.device.audio-input` — the transcription surface
  (`TranscriptionService`). The usage string lives in `Info.plist` under
  `NSMicrophoneUsageDescription`.

Note for anyone editing that file: XML comments there must not contain double
hyphens. AMFI rejects the entitlements even when `plutil` lints clean.

---

## Prerequisites

### Certificates

From App Store Connect ▸ Certificates, IDs & Profiles:

- **App signing** — `Apple Distribution: <Team Name> (<TEAMID>)`, or the legacy
  `3rd Party Mac Developer Application: …`.
- **Installer signing** — `3rd Party Mac Developer Installer: …` (also listed as
  "Mac Installer Distribution").
- **Provisioning profile** — a Mac App Store `.provisionprofile` for the app's
  bundle id.

Check what the keychain already holds:

```bash
make info-appstore          # entitlements, pkg signature, and MAS certs
```

### Environment

```bash
export PENSIEVE_MAS_APP_IDENTITY='Apple Distribution: <Team Name> (<TEAMID>)'
export PENSIEVE_MAS_INSTALLER_IDENTITY='3rd Party Mac Developer Installer: <Team Name> (<TEAMID>)'
export PENSIEVE_MAS_PROVISIONING_PROFILE="$HOME/.keys/Pensieve_MAS.provisionprofile"
```

Only `PENSIEVE_MAS_APP_IDENTITY` is enforced by the script. The other two are
optional _to the build_ and required _to the submission_:

- Without the installer identity you get an unsigned `.pkg` — inspectable
  locally, rejected by App Store Connect.
- Without the provisioning profile the bundle carries no
  `Contents/embedded.provisionprofile` — App Review requires one. The build
  warns and continues, because local dry-runs have to keep working.

A Developer ID identity works as a stand-in for a dry run. The resulting `.pkg`
is inspectable but **not submittable**.

---

## Build

```bash
make release-appstore
```

This runs `make gates` first (tests, lint, Semgrep), then
`scripts/build-release.sh --appstore`. The lane forces no notarization and no
DMG — App Review replaces notarization and the product is a `.pkg`.

Outputs:

```
dist/mas/Pensieve.app     sandbox-signed
dist/mas/Pensieve.pkg     productbuild, signed if the installer identity was set
```

### The FFI dylib has to be a release build

The `.pkg` embeds `Pensieve/Vendor/qube-ffi/$FFI_PROFILE/` verbatim. `FFI_PROFILE`
defaults to `release` in every release lane, but if you override it the build
warns rather than dies, so dry-runs keep working — read those warnings before
submitting.

`make ffi-check` only compares vista-kernel HEADs. It is blind both to the build
profile and to a dirty source tree, so a MAS artifact can silently ship an
untraceable dylib. The build reads `Vendor/qube-ffi/PROVENANCE.txt` and warns
when `vista-kernel-describe` ends in `-dirty`. Rebuild from a clean vista-kernel
before submitting:

```bash
FFI_PROFILE=release Pensieve/scripts/build-ffi.sh
```

---

## Verify before submitting

```bash
# Sandbox actually applied?
codesign -d --entitlements - dist/mas/Pensieve.app

# Provisioning profile embedded?
ls dist/mas/Pensieve.app/Contents/embedded.provisionprofile

# Installer signature present?
pkgutil --check-signature dist/mas/Pensieve.pkg

# All three at once
make info-appstore
```

The profile must sit inside the bundle _before_ the seal is computed, otherwise
the signature does not cover it and App Review rejects the pkg. The build
handles that ordering; this check confirms it landed.

---

## Submit

Upload `dist/mas/Pensieve.pkg` with **Transporter.app**. Then in App Store
Connect:

- [ ] Version matches `VERSION` and the build number is higher than any
      previously uploaded build. The build number is `git rev-list --count HEAD`,
      so it only ever grows.
- [ ] Microphone usage string is present and describes transcription — the
      sandbox grants `device.audio-input`, so App Review will look for it.
- [ ] Privacy labels reflect reality: documents stay local; AI completion is
      opt-in and talks to a user-configured endpoint.
- [ ] Screenshots and description match the shipped build.
- [ ] Export compliance answered. Pensieve uses HTTPS through the system stack
      and ships no custom cryptography.

### Third-party AI endpoints

Pensieve talks to user-selected AI providers, which App Review may ask about.
The repo's position is recorded in `.semgrep-policy.json`: no certificate
pinning, because pinning provider certificates would break endpoint choice and
certificate rotation while adding no stable trust boundary for this product.
Pensieve uses Apple's system trust store instead.

---

## Troubleshooting

### `make release-clean` dies with "Directory not empty"

```
rm: .../Pensieve/.build/arm64-apple-macosx/debug/index/store: Directory not empty
make: *** [release-clean] Error 1
```

A live SourceKit or IDE indexer is writing into `.build/index-build` while the
delete runs — it repopulates a directory mid-delete, so `rmdir` hits `ENOTEMPTY`.
`make clean` already handles this by renaming the tree aside before deleting it,
which detaches it from the path the indexer holds. The `--clean` flag inside
`scripts/build-release.sh` still uses a plain `rm -rf` and loses the same race.

Workaround until that script adopts the same rename-aside:

```bash
make clean && make release-appstore    # instead of release-clean
```

Or quit the indexer (close Xcode / VS Code on this repo) and retry.

### `errSecMissingEntitlement` (-34018) when saving a provider API key

The keychain item is stored in the file-based login keychain without
`SecAccessControl` user-auth gating, and that is deliberate.
`SecAccessControl(.biometryCurrentSet)` routes the item to the macOS
data-protection keychain, which requires provisioning-profile-backed keychain
entitlements the Developer ID signature does not carry — every save failed with
`-34018`, blocking cloud autocomplete, and biometry gating excluded Macs without
Touch ID. Silent access to the login-keychain item stays bound to the app's code
signature. Full rationale in `.semgrep-policy.json`.

If this resurfaces under the MAS lane, note the difference: a MAS build _does_
carry a provisioning profile, so the data-protection keychain becomes reachable
there. Treat it as a lane-specific decision, not a global one.

### The pkg builds but Transporter rejects it

Almost always one of: unsigned pkg (installer identity missing), missing
`embedded.provisionprofile`, or a build number that is not higher than the last
upload. The first two are covered by `make info-appstore`.

---

## Related

- `scripts/build-release.sh` — both lanes; MAS branches guarded by `APPSTORE`.
- `Pensieve/Resources/Pensieve.mas.entitlements` — the sandbox surface.
- `.semgrep-policy.json` — reviewed security findings with their rationale.
- `Makefile` — `release-appstore`, `info-appstore`, `gates`.
- `docs/architecture/document-identity.md` — how a document is identified across
  windows, storage, and recovery.
