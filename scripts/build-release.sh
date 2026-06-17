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
DMG_PATH="$DIST_DIR/$APP_NAME.dmg"
DMG_VOLNAME="Pensieve"
VERSION_FILE="$REPO_ROOT/VERSION"
INFO_PLIST_SRC="$PKG_DIR/Resources/Info.plist"
ENTITLEMENTS="$PKG_DIR/Resources/Pensieve.entitlements"
ICON_SRC="$PKG_DIR/Resources/$APP_NAME.icns"
ICON_RESOURCE="$APP_NAME.icns"
KEYS_DIR="${HOME}/.keys"
NOTARY_ENV="$KEYS_DIR/.notary.env"
SIGNING_IDENTITY_FILE="$KEYS_DIR/signing-identity.txt"
FFI_PROFILE="${FFI_PROFILE:-debug}"

# ─── Args ─────────────────────────────────────────────────────────────────
DO_NOTARIZE=1
DO_CLEAN=0
DMG_ONLY=0
DO_DMG=1
for arg in "$@"; do
    case "$arg" in
        --no-notarize) DO_NOTARIZE=0 ;;
        --clean)       DO_CLEAN=1 ;;
        --dmg-only)    DMG_ONLY=1 ;;
        --no-dmg)      DO_DMG=0 ;;
        -h|--help)
            head -32 "$0" | grep -E "^#" | sed 's/^# \?//'
            exit 0
            ;;
        *) echo "Unknown arg: $arg" >&2; exit 2 ;;
    esac
done
if (( DMG_ONLY )) && (( ! DO_DMG )); then
    echo "Args --dmg-only and --no-dmg are contradictory" >&2; exit 2
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

plist_set_string() {
    local plist="$1"
    local key="$2"
    local value="$3"
    /usr/libexec/PlistBuddy -c "Set :$key $value" "$plist" >/dev/null 2>&1 \
        || /usr/libexec/PlistBuddy -c "Add :$key string $value" "$plist" >/dev/null
}

# ─── Pre-flight ───────────────────────────────────────────────────────────
log "Pre-flight checks"
[[ -d "$PKG_DIR" ]] || die "Pensieve/ not found at $PKG_DIR"
[[ -f "$PKG_DIR/Package.swift" ]] || die "Package.swift missing"
[[ -f "$VERSION_FILE" ]] || die "VERSION file missing at $VERSION_FILE"
[[ -f "$INFO_PLIST_SRC" ]] || die "Info.plist template missing at $INFO_PLIST_SRC"
[[ -f "$ENTITLEMENTS" ]] || die "Pensieve.entitlements missing"
[[ -f "$ICON_SRC" ]] || die "App icon missing at $ICON_SRC"
[[ -f "$SIGNING_IDENTITY_FILE" ]] || die "Signing identity file missing at $SIGNING_IDENTITY_FILE"

SIGNING_IDENTITY="$(head -n1 "$SIGNING_IDENTITY_FILE" | sed -e 's/[[:space:]]*$//')"
[[ -n "$SIGNING_IDENTITY" ]] || die "Signing identity is empty"
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
    ok "DMG-only: reusing existing signed .app at $APP_BUNDLE (skipping build/sign/notarize-app)"
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
swift build -c release --arch arm64 2>&1 | tail -8
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
/usr/libexec/PlistBuddy -c "Add :PensieveComponentVersions:Mermaid string 11.15.0" "$APP_BUNDLE/Contents/Info.plist" >/dev/null
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
    codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$FRAMEWORKS_DIR/libqube_ffi.dylib"
    ok "qube-ffi embedded → @rpath, re-signed with $SIGNING_IDENTITY"
else
    die "qube-ffi dylib not found at $QUBE_DYLIB_SRC — the app binary links libqube_ffi.dylib unconditionally, so a bundle without it aborts in dyld at launch. Run Pensieve/scripts/build-ffi.sh to produce it, then re-run this script."
fi

# ─── Sign ─────────────────────────────────────────────────────────────────
log "Signing with Hardened Runtime"
# Sign nested first if any (none yet, but template safe)
codesign --force \
    --options runtime \
    --entitlements "$ENTITLEMENTS" \
    --sign "$SIGNING_IDENTITY" \
    --timestamp \
    "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

codesign --force \
    --options runtime \
    --entitlements "$ENTITLEMENTS" \
    --sign "$SIGNING_IDENTITY" \
    --timestamp \
    "$APP_BUNDLE"

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
    warn "Skipping notarization (--no-notarize); .app signed but not notarized"
fi

fi  # end: skip build/sign/notarize-app in --dmg-only mode

# ─── DMG ──────────────────────────────────────────────────────────────────
if (( ! DO_DMG )); then
    ok "Skipping DMG (--no-dmg): signed .app is ready at $APP_BUNDLE"
else
log "Building DMG"
rm -f "$DMG_PATH"
hdiutil create \
    -volname "$DMG_VOLNAME" \
    -srcfolder "$APP_BUNDLE" \
    -ov \
    -format UDZO \
    "$DMG_PATH" 2>&1 | tail -3
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
