#!/usr/bin/env bash
# Pensieve release pipeline:
#   swift build (release) → bundle .app → sign → DMG → notarize → staple.
#
# Reads credentials from ~/.keys/.notary.env:
#   NOTARY_APPLE_ID, NOTARY_TEAM_ID, NOTARY_PASSWORD (app-specific)
# Signing identity from ~/.keys/signing-identity.txt
#
# Outputs:
#   dist/Pensieve.app  (signed + hardened + stapled)
#   dist/Pensieve.dmg  (signed + notarized + stapled)
#
# Usage:
#   ./scripts/build-release.sh            # full pipeline
#   ./scripts/build-release.sh --no-notarize   # local-only signed build
#   ./scripts/build-release.sh --clean    # nuke dist/ first
#   ./scripts/build-release.sh --dmg-only # only (re)build DMG from existing stapled .app
#   ./scripts/build-release.sh --no-dmg   # build + sign the .app only, skip the DMG step
#   ./scripts/build-release.sh --appstore # Mac App Store lane: sandbox-signed .app + .pkg
#
# App Store lane (--appstore):
#   Signs with Pensieve.mas.entitlements (App Sandbox) and packages a .pkg via
#   productbuild. No notarization (App Review replaces it) and no DMG. Outputs
#   land in dist/mas/. Identities come from the environment:
#     PENSIEVE_MAS_APP_IDENTITY        (required) app signing identity, e.g.
#                                      "Apple Distribution: <Team> (<TEAMID>)"
#                                      or "3rd Party Mac Developer Application: …"
#     PENSIEVE_MAS_INSTALLER_IDENTITY  (optional) pkg signing identity, e.g.
#                                      "3rd Party Mac Developer Installer: …";
#                                      unset → unsigned pkg (local inspection only)
#     PENSIEVE_MAS_PROVISIONING_PROFILE (optional) path to the Mac App Store
#                                      .provisionprofile; embedded when present.
#                                      App Review REQUIRES it — without it the
#                                      .pkg is a dry-run artifact, not a submission.

set -euo pipefail

# The shell that launches this build may carry a finite `ulimit -f` (file-size
# cap) inherited from its environment. The vendored qube-ffi dylib is ~68 MiB,
# so a 31 MiB cap makes the `cp` into the .app's Frameworks dir die on SIGXFSZ
# (exit 153, "Filesize limit exceeded") after the whole build otherwise
# succeeded. Lift it for the build's process tree.
ulimit -f unlimited 2>/dev/null || true

# ─── Resolve paths ────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PKG_DIR="$REPO_ROOT/Pensieve"
DIST_DIR="$REPO_ROOT/dist"
APP_NAME="Pensieve"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
# DMG_PATH is derived later (x.y.z+slug needs VERSION + git HEAD resolved);
# DMG_STABLE_PATH keeps the fixed name docs/index.html downloads via
# releases/latest/download/Pensieve.dmg.
DMG_STABLE_PATH="$DIST_DIR/$APP_NAME.dmg"
DMG_VOLNAME="Pensieve"
VERSION_FILE="$REPO_ROOT/VERSION"
INFO_PLIST_SRC="$PKG_DIR/Resources/Info.plist"
ENTITLEMENTS="$PKG_DIR/Resources/Pensieve.entitlements"
ICON_SRC="$PKG_DIR/Resources/$APP_NAME.icns"
ICON_RESOURCE="$APP_NAME.icns"
KEYS_DIR="${HOME}/.keys"
NOTARY_ENV="$KEYS_DIR/.notary.env"
SIGNING_IDENTITY_FILE="$KEYS_DIR/signing-identity.txt"
# Development builds keep Package.swift's debug default. Every release lane
# defaults to the optimized vendored runtime and exports the choice so the
# SwiftPM manifest links the same profile that is later embedded in the app.
FFI_PROFILE="${FFI_PROFILE:-release}"
export FFI_PROFILE

# ─── Args ─────────────────────────────────────────────────────────────────
DO_NOTARIZE=1
DO_CLEAN=0
DMG_ONLY=0
DO_DMG=1
APPSTORE=0
for arg in "$@"; do
    case "$arg" in
        --no-notarize) DO_NOTARIZE=0 ;;
        --clean)       DO_CLEAN=1 ;;
        --dmg-only)    DMG_ONLY=1 ;;
        --no-dmg)      DO_DMG=0 ;;
        --appstore)    APPSTORE=1 ;;
        -h|--help)
            head -48 "$0" | grep -E "^#" | sed 's/^# \?//'
            exit 0
            ;;
        *) echo "Unknown arg: $arg" >&2; exit 2 ;;
    esac
done
if (( DMG_ONLY )) && (( ! DO_DMG )); then
    echo "Args --dmg-only and --no-dmg are contradictory" >&2; exit 2
fi
if (( APPSTORE )) && (( DMG_ONLY )); then
    echo "Args --appstore and --dmg-only are contradictory (MAS lane has no DMG)" >&2; exit 2
fi
if (( APPSTORE )); then
    # MAS lane: App Review replaces notarization; the product is a .pkg, not a DMG.
    DO_NOTARIZE=0
    DO_DMG=0
    DIST_DIR="$REPO_ROOT/dist/mas"
    APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
    PKG_PATH="$DIST_DIR/$APP_NAME.pkg"
    ENTITLEMENTS="$PKG_DIR/Resources/Pensieve.mas.entitlements"
fi

# ─── Helpers ──────────────────────────────────────────────────────────────
log()  { printf "\033[36m[build]\033[0m %s\n" "$*"; }
ok()   { printf "\033[32m[ ok ]\033[0m %s\n" "$*"; }
warn() { printf "\033[33m[warn]\033[0m %s\n" "$*" >&2; }
die()  { printf "\033[31m[fail]\033[0m %s\n" "$*" >&2; exit 1; }

case "$FFI_PROFILE" in
    debug|release) ;;
    *) die "FFI_PROFILE must be debug or release, got: $FFI_PROFILE" ;;
esac
if (( ! DMG_ONLY )) && [[ "$FFI_PROFILE" != "release" ]]; then
    if (( DO_NOTARIZE || APPSTORE )); then
        die "Distributable releases require FFI_PROFILE=release; debug FFI is local-only."
    fi
    warn "FFI_PROFILE=debug — local signed app will contain the debug qube-ffi runtime."
fi

plist_set_string() {
    local plist="$1"
    local key="$2"
    local value="$3"
    /usr/libexec/PlistBuddy -c "Set :$key $value" "$plist" >/dev/null 2>&1 \
        || /usr/libexec/PlistBuddy -c "Add :$key string $value" "$plist" >/dev/null
}

# Hardened Runtime belongs to the Developer ID/notarization lane; the MAS lane
# relies on the App Sandbox instead (adding `--options runtime` there is at best
# a no-op and at worst an App Review flag). One funnel keeps the two lanes from
# drifting apart at each of the three signing sites (dylib, executable, bundle).
sign_code() {
    if (( APPSTORE )); then
        codesign --force --timestamp --sign "$SIGNING_IDENTITY" "$@"
    else
        codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$@"
    fi
}

# bundle_identity_matches() — guards the lanes that REUSE an existing .app.
# Kept in a sourceable lib so scripts/test-bundle-identity.sh can exercise it
# without a build (see `make test-scripts`).
# The source= directive lets `shellcheck -x` follow the lib; the plain hook run
# has no -x, hence the SC1091 pair (same idiom as the .notary.env source below).
# shellcheck source=scripts/lib/bundle-identity.sh
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/bundle-identity.sh"

# ─── Pre-flight ───────────────────────────────────────────────────────────
log "Pre-flight checks"
[[ -d "$PKG_DIR" ]] || die "Pensieve/ not found at $PKG_DIR"
[[ -f "$PKG_DIR/Package.swift" ]] || die "Package.swift missing"
[[ -f "$VERSION_FILE" ]] || die "VERSION file missing at $VERSION_FILE"
[[ -f "$INFO_PLIST_SRC" ]] || die "Info.plist template missing at $INFO_PLIST_SRC"
[[ -f "$ENTITLEMENTS" ]] || die "Entitlements missing at $ENTITLEMENTS"
[[ -f "$ICON_SRC" ]] || die "App icon missing at $ICON_SRC"

if (( APPSTORE )); then
    SIGNING_IDENTITY="${PENSIEVE_MAS_APP_IDENTITY:-}"
    [[ -n "$SIGNING_IDENTITY" ]] || die "App Store lane needs PENSIEVE_MAS_APP_IDENTITY.
       Export the Mac App Store app signing identity, e.g.:
         export PENSIEVE_MAS_APP_IDENTITY='Apple Distribution: <Team Name> (<TEAMID>)'
       (or '3rd Party Mac Developer Application: …' for the legacy cert type).
       Certificates come from App Store Connect ▸ Certificates, IDs & Profiles.
       For a local dry-run a Developer ID Application identity also works as a
       stand-in — the resulting .pkg is NOT submittable, only inspectable."
    MAS_INSTALLER_IDENTITY="${PENSIEVE_MAS_INSTALLER_IDENTITY:-}"
    MAS_PROFILE="${PENSIEVE_MAS_PROVISIONING_PROFILE:-}"
    if [[ -n "$MAS_PROFILE" && ! -f "$MAS_PROFILE" ]]; then
        die "PENSIEVE_MAS_PROVISIONING_PROFILE points to a missing file: $MAS_PROFILE"
    fi
    log "App Store lane: sandbox entitlements $ENTITLEMENTS"
    # The pkg embeds Vendor/qube-ffi/$FFI_PROFILE/ verbatim. ffi-check only
    # compares vista-kernel HEADs — it is blind to the build profile and to a
    # dirty source tree, so a MAS artifact could silently ship a debug or
    # untraceable dylib. Warn (not die): local dry-runs must keep working.
    if [[ "$FFI_PROFILE" != "release" ]]; then
        warn "FFI_PROFILE=$FFI_PROFILE — the pkg will embed the $FFI_PROFILE-profile qube-ffi dylib."
        warn "A submittable MAS build needs FFI_PROFILE=release (Pensieve/scripts/build-ffi.sh)."
    fi
    FFI_PROVENANCE="$PKG_DIR/Vendor/qube-ffi/PROVENANCE.txt"
    if [[ -f "$FFI_PROVENANCE" ]]; then
        FFI_DESCRIBE="$(awk -F= '$1 == "vista-kernel-describe" { print $2 }' "$FFI_PROVENANCE" 2>/dev/null || true)"
        if [[ "$FFI_DESCRIBE" == *-dirty ]]; then
            warn "Vendored qube-ffi was built from a DIRTY vista-kernel tree ($FFI_DESCRIBE) —"
            warn "its source is untraceable; rebuild from a clean vista-kernel before submitting."
        fi
    fi
else
    [[ -f "$SIGNING_IDENTITY_FILE" ]] || die "Signing identity file missing at $SIGNING_IDENTITY_FILE"
    SIGNING_IDENTITY="$(head -n1 "$SIGNING_IDENTITY_FILE" | sed -e 's/[[:space:]]*$//')"
    [[ -n "$SIGNING_IDENTITY" ]] || die "Signing identity is empty"
fi
log "Signing identity: $SIGNING_IDENTITY"

if (( DO_NOTARIZE )); then
    [[ -f "$NOTARY_ENV" ]] || die ".notary.env not found at $NOTARY_ENV"
    # shellcheck disable=SC1090
    source "$NOTARY_ENV"
    : "${NOTARY_APPLE_ID:?NOTARY_APPLE_ID missing}"
    : "${NOTARY_TEAM_ID:?NOTARY_TEAM_ID missing}"
    : "${NOTARY_PASSWORD:?NOTARY_PASSWORD missing}"
    log "Notary creds loaded (Apple ID: $NOTARY_APPLE_ID, team: $NOTARY_TEAM_ID)"
fi

# Verify cert in keychain
if ! security find-identity -v -p codesigning | grep -q "$SIGNING_IDENTITY"; then
    die "Signing identity '$SIGNING_IDENTITY' not in Keychain"
fi
ok "Signing identity present in Keychain"

APP_VERSION="$(tr -d '[:space:]' < "$VERSION_FILE")"
[[ "$APP_VERSION" =~ ^[0-9]+(\.[0-9]+){1,2}([-+][0-9A-Za-z.-]+)?$ ]] \
    || die "VERSION must be semver-like, got '$APP_VERSION'"
BUILD_NUMBER="$(git -C "$REPO_ROOT" rev-list --count HEAD)"
COMMIT_FULL="$(git -C "$REPO_ROOT" rev-parse HEAD)"
COMMIT_SLUG="$(git -C "$REPO_ROOT" rev-parse --short=8 HEAD)"
BUILD_DATE="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
BUILD_LABEL="$APP_VERSION+$COMMIT_SLUG"
DMG_PATH="$DIST_DIR/$APP_NAME-$BUILD_LABEL.dmg"
log "Version: $APP_VERSION ($COMMIT_SLUG), build $BUILD_NUMBER"
log "FFI profile: $FFI_PROFILE"

if (( DMG_ONLY )); then
    # Reuse an already-built, signed, notarized + stapled .app and only
    # (re)build/sign/notarize/staple the DMG around it. Lets a disk-full or
    # transient DMG failure be retried without re-running swift build and a
    # second Apple notarization of the .app.
    [[ -d "$APP_BUNDLE" ]] || die "--dmg-only: $APP_BUNDLE not found — run a full build first."
    if ! codesign --verify --strict "$APP_BUNDLE" >/dev/null 2>&1; then
        die "--dmg-only: $APP_BUNDLE signature is invalid — rebuild it before packaging a DMG."
    fi
    # A valid signature proves the bundle was not modified after signing. It is
    # NOT proof of identity: a perfectly signed .app from an older VERSION/HEAD
    # verifies clean, and everything downstream here (DMG filename, the stable
    # Pensieve.dmg download alias, the checksum, the release notes) would then
    # advertise $BUILD_LABEL while shipping that older app. Compare the identity
    # stamped into the bundle at build time before reusing it.
    if ! bundle_identity_matches "$APP_BUNDLE" "$APP_VERSION" "$COMMIT_FULL"; then
        die "--dmg-only: $APP_BUNDLE was built from a different source than this tree.
       Packaging it would ship that older app under the label $BUILD_LABEL.
       Run a full build first: make release-clean (or ./scripts/build-release.sh --clean)."
    fi
    ok "DMG-only: reusing existing signed .app at $APP_BUNDLE (identity $BUILD_LABEL verified, skipping build/sign/notarize-app)"
fi

if (( ! DMG_ONLY )); then

# ─── Clean ────────────────────────────────────────────────────────────────
if (( DO_CLEAN )); then
    log "Cleaning $DIST_DIR + Pensieve/.build"
    rm -rf "$DIST_DIR" "$PKG_DIR/.build"
fi
mkdir -p "$DIST_DIR"

# ─── Build ────────────────────────────────────────────────────────────────
log "swift build -c release (arm64)"
cd "$PKG_DIR"
# Same failure class as the `make test | tail` fix: a `| tail -8` on a red
# parallel build routinely shows 8 progress lines from OTHER modules while the
# actual `error:` lines scrolled away — the release/MAS lane died with no names.
BUILD_LOG="$DIST_DIR/swift-build.log"
if ! swift build -c release --arch arm64 >"$BUILD_LOG" 2>&1; then
    grep -E "error:" "$BUILD_LOG" | head -40 || tail -25 "$BUILD_LOG"
    die "swift build failed — full log: $BUILD_LOG"
fi
tail -8 "$BUILD_LOG"
EXECUTABLE="$PKG_DIR/.build/arm64-apple-macosx/release/$APP_NAME"
[[ -x "$EXECUTABLE" ]] || die "Executable not built at $EXECUTABLE"
ok "Executable: $EXECUTABLE ($(du -h "$EXECUTABLE" | cut -f1))"

# Bundle resources from SwiftPM (Bundle.module)
SPM_BUNDLE_DIR="$(find "$PKG_DIR/.build/arm64-apple-macosx/release" -maxdepth 1 -name "${APP_NAME}_${APP_NAME}.bundle" -type d | head -1)"
[[ -d "$SPM_BUNDLE_DIR" ]] || die "SwiftPM resource bundle not found"
ok "SwiftPM resources: $SPM_BUNDLE_DIR"

# ─── Bundle into .app ─────────────────────────────────────────────────────
log "Building $APP_NAME.app structure"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$EXECUTABLE" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
chmod +x "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

cp "$INFO_PLIST_SRC" "$APP_BUNDLE/Contents/Info.plist"
cp "$ICON_SRC" "$APP_BUNDLE/Contents/Resources/$ICON_RESOURCE"
plist_set_string "$APP_BUNDLE/Contents/Info.plist" "CFBundleIconFile" "$APP_NAME"
plist_set_string "$APP_BUNDLE/Contents/Info.plist" "CFBundleShortVersionString" "$APP_VERSION"
plist_set_string "$APP_BUNDLE/Contents/Info.plist" "CFBundleVersion" "$BUILD_NUMBER"
plist_set_string "$APP_BUNDLE/Contents/Info.plist" "CFBundleGetInfoString" "$APP_NAME $APP_VERSION ($COMMIT_SLUG)"
plist_set_string "$APP_BUNDLE/Contents/Info.plist" "PensieveBuildCommit" "$COMMIT_FULL"
plist_set_string "$APP_BUNDLE/Contents/Info.plist" "PensieveBuildCommitSlug" "$COMMIT_SLUG"
plist_set_string "$APP_BUNDLE/Contents/Info.plist" "PensieveBuildDate" "$BUILD_DATE"
/usr/libexec/PlistBuddy -c "Delete :PensieveComponentVersions" "$APP_BUNDLE/Contents/Info.plist" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy -c "Add :PensieveComponentVersions dict" "$APP_BUNDLE/Contents/Info.plist" >/dev/null
for component in Editor MarkdownRenderer Preview Search Storage Workspace; do
    /usr/libexec/PlistBuddy -c "Add :PensieveComponentVersions:$component string $BUILD_LABEL" "$APP_BUNDLE/Contents/Info.plist" >/dev/null
done
# The vendored runtime's banner (line 1) is the ONLY producer of the Mermaid
# version claim — a hand-copied literal here silently outlives upgrades.
MERMAID_JS="$PKG_DIR/Sources/Pensieve/Resources/mermaid.min.js"
MERMAID_VERSION="$(sed -n '1s/.*Mermaid v\([0-9][0-9.]*[0-9]\).*/\1/p' "$MERMAID_JS")"
[[ -n "$MERMAID_VERSION" ]] || die "Cannot extract Mermaid version from banner of $MERMAID_JS"
/usr/libexec/PlistBuddy -c "Add :PensieveComponentVersions:Mermaid string $MERMAID_VERSION" "$APP_BUNDLE/Contents/Info.plist" >/dev/null
cp -R "$SPM_BUNDLE_DIR" "$APP_BUNDLE/Contents/Resources/"
ok ".app bundle laid out at $APP_BUNDLE"

# Sanity: bundle structure
log "Bundle contents:"
find "$APP_BUNDLE" -maxdepth 3 -print | head -20 | sed 's|'"$APP_BUNDLE"'|  ./|'

# ─── Embed qube-ffi dylib ───────────────────────────────────────────────────
# The release binary links libqube_ffi.dylib via an ABSOLUTE dev path baked into
# its load command (the dylib ships from vista-kernel with an absolute install_name
# and is only ad-hoc signed). An installed hardened-runtime app cannot load it —
# the dev path is gone and the Team IDs differ — so dyld aborts at launch (build 133
# crashed exactly here). Embed it in Contents/Frameworks, repoint to @rpath, and
# re-sign with our identity so it loads from inside the bundle.
QUBE_DYLIB_SRC="$PKG_DIR/Vendor/qube-ffi/$FFI_PROFILE/libqube_ffi.dylib"
if [[ -f "$QUBE_DYLIB_SRC" ]]; then
    log "Embedding qube-ffi dylib (repoint to @rpath + re-sign)"
    FRAMEWORKS_DIR="$APP_BUNDLE/Contents/Frameworks"
    mkdir -p "$FRAMEWORKS_DIR"
    cp "$QUBE_DYLIB_SRC" "$FRAMEWORKS_DIR/libqube_ffi.dylib"
    chmod u+w "$FRAMEWORKS_DIR/libqube_ffi.dylib"
    QUBE_OLD_REF="$(otool -L "$APP_BUNDLE/Contents/MacOS/$APP_NAME" | awk '/libqube_ffi\.dylib/{print $1; exit}')"
    install_name_tool -id "@rpath/libqube_ffi.dylib" "$FRAMEWORKS_DIR/libqube_ffi.dylib"
    if [[ -n "$QUBE_OLD_REF" ]]; then
        install_name_tool -change "$QUBE_OLD_REF" "@rpath/libqube_ffi.dylib" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
    fi
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP_BUNDLE/Contents/MacOS/$APP_NAME" 2>/dev/null || true
    # Same identity (= same Team ID) as the main executable: the sandbox's
    # library validation refuses dylibs signed by another team.
    sign_code "$FRAMEWORKS_DIR/libqube_ffi.dylib"
    ok "qube-ffi embedded → @rpath, re-signed with $SIGNING_IDENTITY"
else
    die "qube-ffi dylib not found at $QUBE_DYLIB_SRC — the app binary links libqube_ffi.dylib unconditionally, so a bundle without it aborts in dyld at launch. Run Pensieve/scripts/build-ffi.sh to produce it, then re-run this script."
fi

# ─── Sign ─────────────────────────────────────────────────────────────────
if (( APPSTORE )); then
    log "Signing for Mac App Store (App Sandbox entitlements)"
    # The provisioning profile must sit inside the bundle BEFORE the seal is
    # computed, or the signature won't cover it and App Review rejects the pkg.
    if [[ -n "$MAS_PROFILE" ]]; then
        cp "$MAS_PROFILE" "$APP_BUNDLE/Contents/embedded.provisionprofile"
        ok "Embedded provisioning profile: $MAS_PROFILE"
    else
        warn "No PENSIEVE_MAS_PROVISIONING_PROFILE — App Review requires an embedded"
        warn "provisioning profile; this build is a local dry-run, not a submission."
    fi
else
    log "Signing with Hardened Runtime"
fi
# Sign nested first if any (none yet, but template safe)
sign_code --entitlements "$ENTITLEMENTS" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

sign_code --entitlements "$ENTITLEMENTS" "$APP_BUNDLE"

log "Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE" 2>&1 | tail -5
ok "Signed"

# ─── Notarize .app ────────────────────────────────────────────────────────
if (( DO_NOTARIZE )); then
    log "Zipping .app for notarization submission"
    APP_ZIP="$DIST_DIR/$APP_NAME.app.zip"
    rm -f "$APP_ZIP"
    /usr/bin/ditto -c -k --keepParent "$APP_BUNDLE" "$APP_ZIP"

    log "Submitting to notary service (may take 1-5 min)"
    xcrun notarytool submit "$APP_ZIP" \
        --apple-id "$NOTARY_APPLE_ID" \
        --team-id "$NOTARY_TEAM_ID" \
        --password "$NOTARY_PASSWORD" \
        --wait \
        --timeout 30m 2>&1 | tee "$DIST_DIR/notary-app.log"

    if grep -q "status: Accepted" "$DIST_DIR/notary-app.log"; then
        ok "App notarized"
        rm -f "$APP_ZIP"

        log "Stapling notarization ticket to .app"
        xcrun stapler staple "$APP_BUNDLE"
        xcrun stapler validate "$APP_BUNDLE" 2>&1 | tail -3
        ok "App stapled"
    else
        SUB_ID="$(awk '/id: [0-9a-f-]+/{print $2; exit}' "$DIST_DIR/notary-app.log")"
        warn "Notarization NOT Accepted. Fetching log…"
        if [[ -n "${SUB_ID:-}" ]]; then
            xcrun notarytool log "$SUB_ID" \
                --apple-id "$NOTARY_APPLE_ID" \
                --team-id "$NOTARY_TEAM_ID" \
                --password "$NOTARY_PASSWORD" 2>&1 | tail -40
        fi
        die "App notarization failed"
    fi
else
    if (( APPSTORE )); then
        log "No notarization in the App Store lane — App Review replaces it"
    else
        warn "Skipping notarization (--no-notarize); .app signed but not notarized"
    fi
fi

fi  # end: skip build/sign/notarize-app in --dmg-only mode

# ─── Mac App Store pkg ────────────────────────────────────────────────────
if (( APPSTORE )); then
    log "Building installer pkg (productbuild)"
    rm -f "$PKG_PATH"
    if [[ -n "$MAS_INSTALLER_IDENTITY" ]]; then
        productbuild \
            --component "$APP_BUNDLE" /Applications \
            --sign "$MAS_INSTALLER_IDENTITY" \
            "$PKG_PATH"
        ok "Signed pkg: $PKG_PATH ($(du -h "$PKG_PATH" | cut -f1))"
    else
        productbuild \
            --component "$APP_BUNDLE" /Applications \
            "$PKG_PATH"
        warn "pkg is UNSIGNED (no PENSIEVE_MAS_INSTALLER_IDENTITY) — fine for local"
        warn "inspection; App Store submission needs a '3rd Party Mac Developer"
        warn "Installer' / 'Mac Installer Distribution' signed pkg."
        ok "Unsigned pkg: $PKG_PATH ($(du -h "$PKG_PATH" | cut -f1))"
    fi

    log "Entitlements on signed app (verify sandbox):"
    codesign -d --entitlements - "$APP_BUNDLE" 2>/dev/null | head -30

    ok "App Store lane complete"
    echo ""
    echo "  App: $APP_BUNDLE"
    echo "  Pkg: $PKG_PATH"
    echo ""
    echo "  Verify entitlements: codesign -d --entitlements - '$APP_BUNDLE'"
    echo "  Submit (operator):   upload the signed pkg with Transporter.app;"
    echo "                       see docs/appstore-lane.md for the ASC checklist."
    exit 0
fi

# ─── DMG ──────────────────────────────────────────────────────────────────
if (( ! DO_DMG )); then
    ok "Skipping DMG (--no-dmg): signed .app is ready at $APP_BUNDLE"
else
log "Building DMG"
rm -f "$DMG_PATH"
# Stage a drag-install layout: the app plus an /Applications symlink, so the
# mounted image offers the drop target instead of a lone .app.
DMG_STAGING="$DIST_DIR/dmg-staging"
rm -rf "$DMG_STAGING"
(
    trap 'rm -rf "$DMG_STAGING"' EXIT
    mkdir -p "$DMG_STAGING"
    cp -R "$APP_BUNDLE" "$DMG_STAGING/"
    ln -s /Applications "$DMG_STAGING/Applications"
    hdiutil create \
        -volname "$DMG_VOLNAME" \
        -srcfolder "$DMG_STAGING" \
        -ov \
        -format UDZO \
        "$DMG_PATH" 2>&1 | tail -3
)
ok "DMG: $DMG_PATH ($(du -h "$DMG_PATH" | cut -f1))"

log "Signing DMG"
codesign --force --sign "$SIGNING_IDENTITY" --timestamp "$DMG_PATH"
codesign --verify --verbose=2 "$DMG_PATH" 2>&1 | tail -3

# ─── Notarize DMG ─────────────────────────────────────────────────────────
if (( DO_NOTARIZE )); then
    log "Submitting DMG for notarization"
    xcrun notarytool submit "$DMG_PATH" \
        --apple-id "$NOTARY_APPLE_ID" \
        --team-id "$NOTARY_TEAM_ID" \
        --password "$NOTARY_PASSWORD" \
        --wait \
        --timeout 30m 2>&1 | tee "$DIST_DIR/notary-dmg.log"

    if grep -q "status: Accepted" "$DIST_DIR/notary-dmg.log"; then
        ok "DMG notarized"
        log "Stapling DMG"
        xcrun stapler staple "$DMG_PATH"
        xcrun stapler validate "$DMG_PATH" 2>&1 | tail -3
        ok "DMG stapled"
    else
        SUB_ID="$(awk '/id: [0-9a-f-]+/{print $2; exit}' "$DIST_DIR/notary-dmg.log")"
        warn "DMG notarization NOT Accepted. Fetching log…"
        if [[ -n "${SUB_ID:-}" ]]; then
            xcrun notarytool log "$SUB_ID" \
                --apple-id "$NOTARY_APPLE_ID" \
                --team-id "$NOTARY_TEAM_ID" \
                --password "$NOTARY_PASSWORD" 2>&1 | tail -40
        fi
        die "DMG notarization failed"
    fi
fi

# Refresh the stable-named copy AFTER sign/notarize/staple: the staple ticket
# lives inside the DMG, so the copy stays validated, and the fixed name keeps
# the releases/latest/download/Pensieve.dmg funnel alive.
cp -f "$DMG_PATH" "$DMG_STABLE_PATH"
ok "Stable alias: $DMG_STABLE_PATH"

# Internal release shelf (Codescribe convention: <root>/<App>/<version>/ with
# the artifact + SHA256SUMS.txt). Notarized lane only — local --no-notarize
# builds are not releases and must not land on the team shelf.
INTERNAL_RELEASES_ROOT="${PENSIEVE_INTERNAL_RELEASES:-/Volumes/vc-workspace/_RELEASES}"
if (( DO_NOTARIZE )); then
    if [[ -d "$INTERNAL_RELEASES_ROOT" ]]; then
        INTERNAL_DIR="$INTERNAL_RELEASES_ROOT/$APP_NAME/$APP_VERSION"
        mkdir -p "$INTERNAL_DIR"
        cp -f "$DMG_PATH" "$INTERNAL_DIR/"
        (cd "$INTERNAL_DIR" && shasum -a 256 ./*.dmg > SHA256SUMS.txt)
        ok "Internal release: $INTERNAL_DIR/$(basename "$DMG_PATH")"
    else
        warn "Internal releases root missing at $INTERNAL_RELEASES_ROOT — skipped internal publish"
    fi
fi
fi  # end: skip DMG build/sign/notarize in --no-dmg mode

# ─── Final Gatekeeper check ───────────────────────────────────────────────
log "Gatekeeper assessment"
spctl --assess --type execute --verbose "$APP_BUNDLE" 2>&1 | tail -3 || warn "spctl assessment failed (may be OK before stapler)"
if (( DO_DMG )); then
    spctl --assess --type open --context context:primary-signature "$DMG_PATH" 2>&1 | tail -3 || warn "DMG spctl check failed (may be OK)"
fi

ok "Release pipeline complete"
echo ""
echo "  App: $APP_BUNDLE"
(( DO_DMG )) && echo "  DMG: $DMG_PATH"
echo ""
echo "  Open: open '$APP_BUNDLE'"
if (( DO_DMG )); then
    echo "  Verify staple: xcrun stapler validate '$APP_BUNDLE'"
    echo "  Open DMG: open '$DMG_PATH'"
fi
