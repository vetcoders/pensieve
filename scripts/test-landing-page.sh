#!/usr/bin/env bash
# Unit tests for scripts/lib/landing-page.sh — the guard that keeps the public
# download page's SHA-256 tied to the DMG the release actually produced, and
# tied to the version and artifact link it is printed next to.
#
# Self-contained: synthetic HTML fixtures in a mktemp dir, no build, no
# codesign, no network. Runs in well under a second, so it belongs in
# `make gates` (see the test-scripts target).
#
# Usage: ./scripts/test-landing-page.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LANDING_PAGE_LIB="$SCRIPT_DIR/lib/landing-page.sh"
# shellcheck source=scripts/lib/landing-page.sh
source "$LANDING_PAGE_LIB"

C_GREEN='\033[32m'
C_RED='\033[31m'
C_RESET='\033[0m'

FIXTURE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/pensieve-landing-page.XXXXXX")"
cleanup() {
    if [[ -n "${FIXTURE_ROOT:-}" && -d "$FIXTURE_ROOT" ]]; then
        chmod -R u+rwx "$FIXTURE_ROOT" 2>/dev/null || true
        rm -rf "$FIXTURE_ROOT"
    fi
    return 0
}
trap cleanup EXIT

# Deliberately synthetic: an arbitrary version and two distinguishable
# checksums, NOT any real release of this repo.
VERSION_A="9.9.1"
VERSION_B="9.9.2"
SHA_A="1111111111111111111111111111111111111111111111111111111111111111"
SHA_B="2222222222222222222222222222222222222222222222222222222222222222"
PLACEHOLDER="RELEASE-9-9-1-SHA256-FILLED-AT-PUBLISH-DO-NOT-SHIP-THIS-LINE"
URL_A="https://github.com/vetcoders/pensieve/releases/latest/download/Pensieve.dmg"
URL_FOREIGN="https://github.com/someone-else/pensieve/releases/latest/download/Pensieve.dmg"

PASS_COUNT=0
FAIL_COUNT=0

pass() {
    printf "${C_GREEN}[PASS]${C_RESET} %s\n" "$1"
    PASS_COUNT=$((PASS_COUNT + 1))
}

fail() {
    printf "${C_RED}[FAIL]${C_RESET} %s\n       %s\n" "$1" "$2"
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

# print_download_targets <artifact-url>… — the download-target shape the real
# docs/index.html carries: a JSON-LD `downloadUrl`, a hero button and a
# download-panel button, one target per argument IN ORDER. Fixtures mirror that
# shape rather than a single link, because the lib asserts an exact target
# count and a one-link fixture would only ever exercise a page nobody publishes.
print_download_targets() {
    if (( $# >= 1 )); then
        printf '    <script type="application/ld+json">\n      { "downloadUrl": "%s" }\n    </script>\n' "$1"
    fi
    if (( $# >= 2 )); then
        printf '    <a class="btn btn-hero"\n      href="%s"\n      >Download</a\n    >\n' "$2"
    fi
    if (( $# >= 3 )); then
        printf '    <a class="btn btn-primary"\n      href="%s"\n      >Download Pensieve.dmg</a\n    >\n' "$3"
    fi
}

# make_labelled_page <name> <version> <artifact-url|-> <algorithm-label>
#                    <checksum-slot-payload>… → prints the page path.
# One slot payload per checksum <div>; zero payloads yields a page with none. A
# `-` URL yields a page that links no artifact at all; any other value is
# published in all three download targets. The label is a parameter so a page
# can advertise our checksum under somebody else's algorithm while keeping the
# slot's shape byte-for-byte.
make_labelled_page() {
    local name="$1"
    local version="$2"
    local url="$3"
    local label="$4"
    shift 4
    local page="$FIXTURE_ROOT/$name.html"
    local payload

    {
        printf '<!doctype html>\n<html>\n  <body>\n'
        printf '    <dl>\n      <div><dt>Version</dt><dd>%s</dd></div>\n' "$version"
        printf '      <div><dt>Platform</dt><dd>macOS 15+</dd></div>\n    </dl>\n'
        if [[ "$url" != "-" ]]; then
            print_download_targets "$url" "$url" "$url"
        fi
        for payload in "$@"; do
            printf '    <div class="sha">%s<br />%s</div>\n' "$label" "$payload"
        done
        printf '  </body>\n</html>\n'
    } >"$page"
    printf '%s\n' "$page"
}

# make_page <name> <version> <artifact-url|-> <checksum-slot-payload>… — the
# same page with the label the real docs/index.html carries.
make_page() {
    local name="$1"
    local version="$2"
    local url="$3"
    shift 3
    make_labelled_page "$name" "$version" "$url" '<b>SHA-256</b>' "$@"
}

# make_versions_page <name> <slot-payload> <version>… → prints the page path.
# A page whose download panel declares the given versions IN ORDER, each in its
# own <dt>Version</dt> record; an empty argument yields `<dd></dd>`.
make_versions_page() {
    local name="$1"
    local payload="$2"
    shift 2
    local page="$FIXTURE_ROOT/$name.html"
    local version

    {
        printf '<!doctype html>\n<html>\n  <body>\n    <dl>\n'
        for version in "$@"; do
            printf '      <div><dt>Version</dt><dd>%s</dd></div>\n' "$version"
        done
        printf '    </dl>\n'
        print_download_targets "$URL_A" "$URL_A" "$URL_A"
        printf '    <div class="sha"><b>SHA-256</b><br />%s</div>\n' "$payload"
        printf '  </body>\n</html>\n'
    } >"$page"
    printf '%s\n' "$page"
}

# assert_status <description> <expected status> <expected stderr substring> <fn> <args…>
# An empty expected substring means stderr is not inspected.
assert_status() {
    local desc="$1" expected="$2" needle="$3"
    shift 3
    local output status=0
    output="$("$@" 2>&1 >/dev/null)" || status=$?
    if (( status != expected )); then
        fail "$desc" "expected exit $expected, got $status: ${output:-<no output>}"
        return 0
    fi
    if [[ -n "$needle" && "$output" != *"$needle"* ]]; then
        fail "$desc" "expected stderr to mention '$needle', got: ${output:-<no output>}"
        return 0
    fi
    pass "$desc"
}

# ─── Preflight: landing_page_assert_publishable ───────────────────────────

GOOD_PAGE="$(make_page good "$VERSION_A" "$URL_A" "$PLACEHOLDER")"
assert_status "a placeholder page for this version is stampable" 0 "" \
    landing_page_assert_publishable "$GOOD_PAGE" "$VERSION_A" "$URL_A"

assert_status "a missing page is a failure, not a silent pass" 1 "no landing page at" \
    landing_page_assert_publishable "$FIXTURE_ROOT/absent.html" "$VERSION_A" "$URL_A"

UNREADABLE_PAGE="$(make_page unreadable "$VERSION_A" "$URL_A" "$PLACEHOLDER")"
chmod 000 "$UNREADABLE_PAGE"
if [[ -r "$UNREADABLE_PAGE" ]]; then
    # root (or an ACL-permissive volume) can read a 000 file; the case is then
    # untestable here rather than passing vacuously.
    printf '%b[SKIP]%b unreadable-page case: this user can read a 0000 file\n' "$C_RED" "$C_RESET"
else
    assert_status "an unreadable page is a failure, not a silent pass" 1 "not readable" \
        landing_page_assert_publishable "$UNREADABLE_PAGE" "$VERSION_A" "$URL_A"
fi
chmod 644 "$UNREADABLE_PAGE"

READONLY_PAGE="$(make_page readonly "$VERSION_A" "$URL_A" "$PLACEHOLDER")"
chmod 444 "$READONLY_PAGE"
if [[ -w "$READONLY_PAGE" ]]; then
    printf '%b[SKIP]%b read-only-page case: this user can write a 0444 file\n' "$C_RED" "$C_RESET"
else
    assert_status "a page the release cannot stamp is rejected up front" 1 "not writable" \
        landing_page_assert_publishable "$READONLY_PAGE" "$VERSION_A" "$URL_A"
fi
chmod 644 "$READONLY_PAGE"

NO_SLOT_PAGE="$(make_page no-slot "$VERSION_A" "$URL_A")"
assert_status "a page with no checksum slot is rejected" 1 "exactly one" \
    landing_page_assert_publishable "$NO_SLOT_PAGE" "$VERSION_A" "$URL_A"

TWO_SLOT_PAGE="$(make_page two-slots "$VERSION_A" "$URL_A" "$PLACEHOLDER" "$SHA_A")"
assert_status "an ambiguous page with two checksum slots is rejected" 1 "exactly one" \
    landing_page_assert_publishable "$TWO_SLOT_PAGE" "$VERSION_A" "$URL_A"

# The trailing slot is EMPTY on purpose. Slot listings are read through `$(…)`,
# which strips trailing newlines, so an empty last record used to disappear:
# this page counted as one slot, passed preflight, and only blew up at stamping
# time — after the build, the notarization round trip and the shelf copy.
EMPTY_TRAILING_SLOT_PAGE="$(make_page empty-trailing-slot "$VERSION_A" "$URL_A" "$PLACEHOLDER" "")"
assert_status "an empty trailing checksum slot is counted, not swallowed" 1 "found 2" \
    landing_page_assert_publishable "$EMPTY_TRAILING_SLOT_PAGE" "$VERSION_A" "$URL_A"

# The slot keeps its exact shape and only the algorithm label changes. The
# release computes a SHA-256, so a page presenting it as an MD5 tells every
# reader who verifies it that the DMG was tampered with.
MD5_LABEL_PAGE="$(make_labelled_page md5-label "$VERSION_A" "$URL_A" '<b>MD5</b>' "$PLACEHOLDER")"
assert_status "a checksum slot relabelled as another algorithm is rejected" 1 \
    "not labelled" landing_page_assert_publishable "$MD5_LABEL_PAGE" "$VERSION_A" "$URL_A"

# The label has to sit where the reader sees it — before the value, not smuggled
# in behind it.
TRAILING_LABEL_PAGE="$FIXTURE_ROOT/trailing-label.html"
printf '<div><dt>Version</dt><dd>%s</dd></div>\n<a href="%s">d</a>\n<div class="sha"><b>MD5</b><br />%s</div><b>SHA-256</b>\n' \
    "$VERSION_A" "$URL_A" "$PLACEHOLDER" >"$TRAILING_LABEL_PAGE"
assert_status "a SHA-256 label printed after the value does not vouch for the slot" 1 \
    "not labelled" landing_page_assert_publishable "$TRAILING_LABEL_PAGE" "$VERSION_A" "$URL_A"

RESHAPED_PAGE="$FIXTURE_ROOT/reshaped.html"
printf '<div><dt>Version</dt><dd>%s</dd></div>\n<div class="sha">%s</div>\n' \
    "$VERSION_A" "$PLACEHOLDER" >"$RESHAPED_PAGE"
assert_status "a checksum slot in an unknown shape is rejected, not stamped blindly" 1 \
    "no longer" landing_page_assert_publishable "$RESHAPED_PAGE" "$VERSION_A" "$URL_A"

assert_status "a page advertising another version is rejected before the build" 1 \
    "advertises version" landing_page_assert_publishable "$GOOD_PAGE" "$VERSION_B" "$URL_A"

NO_VERSION_PAGE="$FIXTURE_ROOT/no-version.html"
printf '<div class="sha"><b>SHA-256</b><br />%s</div>\n' "$PLACEHOLDER" >"$NO_VERSION_PAGE"
assert_status "a page that declares no download version is rejected" 1 \
    "exactly one download version" \
    landing_page_assert_publishable "$NO_VERSION_PAGE" "$VERSION_A" "$URL_A"

# The swallowed-trailing-record bug, in the version parser this time: the page
# declares the right version AND a second, empty declaration. `$(…)` dropped the
# empty last line, so two competing declarations read as one clean version — and
# a release cannot know which one the page will be read as advertising.
EMPTY_TRAILING_VERSION_PAGE="$(make_versions_page empty-trailing-version "$PLACEHOLDER" "$VERSION_A" "")"
assert_status "an empty trailing version record is counted, not swallowed" 1 "found 2" \
    landing_page_assert_publishable "$EMPTY_TRAILING_VERSION_PAGE" "$VERSION_A" "$URL_A"

EMPTY_VERSION_PAGE="$(make_versions_page empty-version "$PLACEHOLDER" "")"
assert_status "a download panel declaring an empty version is rejected" 1 \
    "empty download version" \
    landing_page_assert_publishable "$EMPTY_VERSION_PAGE" "$VERSION_A" "$URL_A"

RESHAPED_VERSION_PAGE="$FIXTURE_ROOT/reshaped-version.html"
printf '<div><dt>Version</dt><dd><span>%s</span></dd></div>\n<a href="%s">d</a>\n<div class="sha"><b>SHA-256</b><br />%s</div>\n' \
    "$VERSION_A" "$URL_A" "$PLACEHOLDER" >"$RESHAPED_VERSION_PAGE"
assert_status "a version record in an unknown shape is rejected, not read as absent" 1 \
    "the version record is no longer" \
    landing_page_assert_publishable "$RESHAPED_VERSION_PAGE" "$VERSION_A" "$URL_A"

FOREIGN_URL_PAGE="$(make_page foreign-url "$VERSION_A" "$URL_FOREIGN" "$PLACEHOLDER")"
assert_status "a download button pointing at another repo's artifact is rejected up front" 1 \
    "links the artifact" \
    landing_page_assert_publishable "$FOREIGN_URL_PAGE" "$VERSION_A" "$URL_A"

NO_URL_PAGE="$(make_page no-url "$VERSION_A" "-" "$PLACEHOLDER")"
assert_status "a page with no artifact link at all is rejected" 1 "no downloadable artifact" \
    landing_page_assert_publishable "$NO_URL_PAGE" "$VERSION_A" "$URL_A"

# make_targets_page <name> <download-target>… → prints the page path. Everything
# but the download targets is this release's: the point of each fixture below is
# one target that disagrees while its neighbours vouch for the page.
make_targets_page() {
    local name="$1"
    shift
    local page="$FIXTURE_ROOT/$name.html"

    {
        printf '<!doctype html>\n<html>\n  <body>\n'
        printf '    <dl>\n      <div><dt>Version</dt><dd>%s</dd></div>\n    </dl>\n' "$VERSION_A"
        print_download_targets "$@"
        printf '    <div class="sha"><b>SHA-256</b><br />%s</div>\n' "$PLACEHOLDER"
        printf '  </body>\n</html>\n'
    } >"$page"
    printf '%s\n' "$page"
}

MIXED_URL_PAGE="$(make_targets_page mixed-url "$URL_A" "$URL_A" "$URL_FOREIGN")"
assert_status "two canonical links do not excuse a third, foreign one" 1 "links the artifact" \
    landing_page_assert_publishable "$MIXED_URL_PAGE" "$VERSION_A" "$URL_A"

# The substring scan this parser replaced saw absolute .dmg URLs only, so a
# relative href was not a target it disagreed with — it was a target it could
# not see, and the two canonical neighbours carried the page through.
RELATIVE_URL_PAGE="$(make_targets_page relative-url "$URL_A" "/downloads/Other.dmg" "$URL_A")"
assert_status "a download target repointed at a relative path is rejected" 1 \
    "links the artifact" \
    landing_page_assert_publishable "$RELATIVE_URL_PAGE" "$VERSION_A" "$URL_A"

# …and it matched a PREFIX, so a button offering Pensieve.dmg.exe yielded the
# canonical URL as a substring and the page shipped this DMG's checksum next to
# a Windows executable.
SUFFIXED_URL_PAGE="$(make_targets_page suffixed-url "$URL_A" "$URL_A" "$URL_A.exe")"
assert_status "a download target that only starts with the artifact URL is rejected" 1 \
    "links the artifact" \
    landing_page_assert_publishable "$SUFFIXED_URL_PAGE" "$VERSION_A" "$URL_A"

# A target repointed at something that is not a DMG at all leaves the other two
# canonical, so only an exact count can notice it.
MISSING_TARGET_PAGE="$(make_targets_page missing-target \
    "$URL_A" "https://github.com/vetcoders/pensieve/releases/latest" "$URL_A")"
assert_status "a page that stopped handing the reader the artifact in one of its three places is rejected" 1 \
    "hands the reader the artifact in 2 places" \
    landing_page_assert_publishable "$MISSING_TARGET_PAGE" "$VERSION_A" "$URL_A"

DROPPED_TARGET_PAGE="$(make_targets_page dropped-target "$URL_A" "$URL_A")"
assert_status "a page that dropped a download target outright is rejected" 1 \
    "hands the reader the artifact in 2 places" \
    landing_page_assert_publishable "$DROPPED_TARGET_PAGE" "$VERSION_A" "$URL_A"

EXTRA_TARGET_PAGE="$FIXTURE_ROOT/extra-target.html"
{
    printf '<!doctype html>\n<html>\n  <body>\n'
    printf '    <dl>\n      <div><dt>Version</dt><dd>%s</dd></div>\n    </dl>\n' "$VERSION_A"
    print_download_targets "$URL_A" "$URL_A" "$URL_A"
    printf '    <a class="btn" href="%s">one more</a>\n' "$URL_A"
    printf '    <div class="sha"><b>SHA-256</b><br />%s</div>\n' "$PLACEHOLDER"
    printf '  </body>\n</html>\n'
} >"$EXTRA_TARGET_PAGE"
assert_status "a fourth download target is a deliberate edit, not a silent widening" 1 \
    "hands the reader the artifact in 4 places" \
    landing_page_assert_publishable "$EXTRA_TARGET_PAGE" "$VERSION_A" "$URL_A"

UNQUOTED_URL_PAGE="$FIXTURE_ROOT/unquoted-url.html"
{
    printf '<!doctype html>\n<html>\n  <body>\n'
    printf '    <dl>\n      <div><dt>Version</dt><dd>%s</dd></div>\n    </dl>\n' "$VERSION_A"
    print_download_targets "$URL_A" "$URL_A"
    printf '    <a class="btn" href=%s>Download Pensieve.dmg</a>\n' "$URL_A"
    printf '    <div class="sha"><b>SHA-256</b><br />%s</div>\n' "$PLACEHOLDER"
    printf '  </body>\n</html>\n'
} >"$UNQUOTED_URL_PAGE"
assert_status "a download target whose shape the parser cannot read fails loudly, not silently" 1 \
    "no longer href=" \
    landing_page_assert_publishable "$UNQUOTED_URL_PAGE" "$VERSION_A" "$URL_A"

# The parser reads whole attribute values, not URLs found inside a line. Pinned
# directly, because every assertion above would also pass on a parser that
# merely counted three matches somewhere on the page.
TARGET_RECORDS="$(landing_page_artifact_urls "$SUFFIXED_URL_PAGE")"
if [[ "$TARGET_RECORDS" == "$URL_A
$URL_A
$URL_A.exe" ]]; then
    pass "a download target is read whole, not truncated at the first .dmg"
else
    fail "a download target is read whole, not truncated at the first .dmg" \
        "records: $(printf '%s' "$TARGET_RECORDS" | tr '\n' ' ')"
fi

assert_status "an expected artifact URL that is not an https .dmg is a usage error" 2 \
    "not an https .dmg URL" \
    landing_page_assert_publishable "$GOOD_PAGE" "$VERSION_A" "https://github.com/vetcoders/pensieve/releases/latest"

assert_status "preflight without an expected artifact URL is a usage error, not a pass" 2 \
    "usage" landing_page_assert_publishable "$GOOD_PAGE" "$VERSION_A"

# Preflight only earns its keep while it rejects everything the stamp rejects.
# These two are the stamp's own refusals, moved to the front of the run: a
# writable page in a sealed directory (the stamped page is renamed in from a
# temp file created there) and a symlinked page (a rename would replace the link
# and leave the real page unstamped). Both used to fail AFTER the build and the
# notarization round trip.
SEALED_PREFLIGHT_DIR="$FIXTURE_ROOT/sealed-preflight"
mkdir -p "$SEALED_PREFLIGHT_DIR"
SEALED_PREFLIGHT_PAGE="$SEALED_PREFLIGHT_DIR/index.html"
printf '<div><dt>Version</dt><dd>%s</dd></div>\n<a href="%s">d</a>\n<div class="sha"><b>SHA-256</b><br />%s</div>\n' \
    "$VERSION_A" "$URL_A" "$PLACEHOLDER" >"$SEALED_PREFLIGHT_PAGE"
chmod 500 "$SEALED_PREFLIGHT_DIR"
if [[ -w "$SEALED_PREFLIGHT_DIR" ]]; then
    printf '%b[SKIP]%b sealed-directory preflight case: this user can write a 0500 directory\n' "$C_RED" "$C_RESET"
else
    assert_status "a page in a directory the stamp cannot write is rejected up front" 1 \
        "not a writable directory" \
        landing_page_assert_publishable "$SEALED_PREFLIGHT_PAGE" "$VERSION_A" "$URL_A"
fi
chmod 700 "$SEALED_PREFLIGHT_DIR"

SYMLINK_PREFLIGHT_PAGE="$FIXTURE_ROOT/symlinked-preflight.html"
ln -sf "$(make_page symlink-preflight-target "$VERSION_A" "$URL_A" "$PLACEHOLDER")" "$SYMLINK_PREFLIGHT_PAGE"
assert_status "a symlinked page is rejected up front, not at stamping time" 1 "is a symlink" \
    landing_page_assert_publishable "$SYMLINK_PREFLIGHT_PAGE" "$VERSION_A" "$URL_A"

# ─── Stamping: landing_page_stamp_checksum ────────────────────────────────

STAMP_PAGE="$(make_page stamp "$VERSION_A" "$URL_A" "$PLACEHOLDER")"
BEFORE_LINES="$(wc -l <"$STAMP_PAGE")"
chmod 640 "$STAMP_PAGE"
if landing_page_stamp_checksum "$STAMP_PAGE" "$SHA_A"; then
    if grep -q "<div class=\"sha\"><b>SHA-256</b><br />$SHA_A</div>" "$STAMP_PAGE"; then
        pass "stamping replaces the placeholder with the build's checksum"
    else
        fail "stamping replaces the placeholder with the build's checksum" \
            "slot line after stamping: $(grep 'class="sha"' "$STAMP_PAGE")"
    fi
    if grep -q "DO-NOT-SHIP" "$STAMP_PAGE"; then
        fail "stamping removes the DO-NOT-SHIP placeholder" "marker survived"
    else
        pass "stamping removes the DO-NOT-SHIP placeholder"
    fi
    if [[ "$(wc -l <"$STAMP_PAGE")" == "$BEFORE_LINES" ]] \
        && grep -q "<dd>macOS 15+</dd>" "$STAMP_PAGE"; then
        pass "stamping leaves the rest of the page intact"
    else
        fail "stamping leaves the rest of the page intact" "line count or surrounding markup changed"
    fi
    # The page is now written by renaming a fresh file into place, so its
    # permissions have to be carried over explicitly — a published page that
    # silently becomes 0600 is a broken checkout, not a stamped release.
    if [[ "$(stat -f '%Lp' "$STAMP_PAGE")" == "640" ]]; then
        pass "stamping preserves the page's permissions"
    else
        fail "stamping preserves the page's permissions" \
            "mode after stamping: $(stat -f '%Lp' "$STAMP_PAGE")"
    fi
    if compgen -G "$FIXTURE_ROOT/.pensieve-landing-page.*" >/dev/null; then
        fail "stamping leaves no temporary file behind" \
            "leftovers: $(echo "$FIXTURE_ROOT"/.pensieve-landing-page.*)"
    else
        pass "stamping leaves no temporary file behind"
    fi
else
    fail "stamping replaces the placeholder with the build's checksum" "stamp call failed"
fi
chmod 644 "$STAMP_PAGE"

# Re-stamping an already filled page is the --dmg-only / retry path.
if landing_page_stamp_checksum "$STAMP_PAGE" "$SHA_B" \
    && grep -q "<br />$SHA_B</div>" "$STAMP_PAGE"; then
    pass "a re-run overwrites the previous run's checksum"
else
    fail "a re-run overwrites the previous run's checksum" \
        "slot line: $(grep 'class="sha"' "$STAMP_PAGE")"
fi

assert_status "stamping a value that is not a SHA-256 is a usage error" 2 "not a lowercase SHA-256" \
    landing_page_stamp_checksum "$STAMP_PAGE" "not-a-checksum"

assert_status "stamping a missing page fails" 1 "no landing page at" \
    landing_page_stamp_checksum "$FIXTURE_ROOT/absent.html" "$SHA_A"

assert_status "stamping a page with no slot fails instead of writing nothing quietly" 1 \
    "could not rewrite exactly one checksum slot" \
    landing_page_stamp_checksum "$(make_page stamp-no-slot "$VERSION_A" "$URL_A")" "$SHA_A"

# A SHA-256 must never be written into a slot promising another algorithm, even
# though the slot's shape is stampable: the stamp leaves the line alone and the
# run fails on the "exactly one slot" count.
assert_status "a slot advertising another algorithm is not stamped with our SHA-256" 1 \
    "could not rewrite exactly one checksum slot" \
    landing_page_stamp_checksum \
    "$(make_labelled_page stamp-md5 "$VERSION_A" "$URL_A" '<b>MD5</b>' "$PLACEHOLDER")" "$SHA_A"

SYMLINK_PAGE="$FIXTURE_ROOT/symlinked.html"
ln -sf "$(make_page symlink-target "$VERSION_A" "$URL_A" "$PLACEHOLDER")" "$SYMLINK_PAGE"
assert_status "stamping through a symlink is refused instead of replacing the link" 1 \
    "is a symlink" landing_page_stamp_checksum "$SYMLINK_PAGE" "$SHA_A"

# The stamped page is renamed into place from a temp file in the page's OWN
# directory, because a rename is atomic only inside one filesystem. Proving it
# behaviorally: a directory that cannot hold the temp file fails the stamp
# (a $TMPDIR temp plus an in-place truncating write would have succeeded here).
SEALED_DIR="$FIXTURE_ROOT/sealed"
mkdir -p "$SEALED_DIR"
SEALED_PAGE="$SEALED_DIR/index.html"
printf '<div><dt>Version</dt><dd>%s</dd></div>\n<a href="%s">d</a>\n<div class="sha"><b>SHA-256</b><br />%s</div>\n' \
    "$VERSION_A" "$URL_A" "$PLACEHOLDER" >"$SEALED_PAGE"
chmod 500 "$SEALED_DIR"
if [[ -w "$SEALED_DIR" ]]; then
    printf '%b[SKIP]%b sealed-directory case: this user can write a 0500 directory\n' "$C_RED" "$C_RESET"
else
    assert_status "the stamped page is written next to the page, not from \$TMPDIR" 1 \
        "next to" landing_page_stamp_checksum "$SEALED_PAGE" "$SHA_A"
fi
chmod 700 "$SEALED_DIR"

# A shared worktree can be edited while the release is stamping. The rewrite is
# bracketed by a digest of the page for exactly that reason: publishing the
# pre-edit snapshot would erase the concurrent edit AND leave the final gate
# nothing to notice, because the snapshot still carries the expected checksum.
# Simulated deterministically by making the two digest reads disagree, which is
# what a racing writer produces.
CONFLICT_PAGE="$(make_page conflict "$VERSION_A" "$URL_A" "$PLACEHOLDER")"
CONFLICT_MARKER="$FIXTURE_ROOT/conflict-digest-taken"
# The counter lives in a file: each digest is read through `$(…)`, i.e. in a
# subshell, so a shell variable would come back to 0 on the second call.
landing_page_digest() {
    if [[ -e "$CONFLICT_MARKER" ]]; then
        printf 'bbbb%060d\n' 0
    else
        : >"$CONFLICT_MARKER"
        printf 'aaaa%060d\n' 0
    fi
}
CONFLICT_OUTPUT="$(landing_page_stamp_checksum "$CONFLICT_PAGE" "$SHA_A" 2>&1 >/dev/null)" \
    && CONFLICT_STATUS=0 || CONFLICT_STATUS=$?
# shellcheck source=scripts/lib/landing-page.sh
source "$LANDING_PAGE_LIB"
if (( CONFLICT_STATUS == 1 )) && [[ "$CONFLICT_OUTPUT" == *"changed while this release was stamping it"* ]]; then
    if grep -q "DO-NOT-SHIP" "$CONFLICT_PAGE"; then
        pass "a page edited mid-stamp is left alone and the stamp fails loudly"
    else
        fail "a page edited mid-stamp is left alone and the stamp fails loudly" \
            "the stamp was published anyway"
    fi
else
    fail "a page edited mid-stamp is left alone and the stamp fails loudly" \
        "expected exit 1 with a concurrent-edit message, got $CONFLICT_STATUS: ${CONFLICT_OUTPUT:-<no output>}"
fi
if compgen -G "$FIXTURE_ROOT/.pensieve-landing-page.*" >/dev/null; then
    fail "an aborted stamp leaves no temporary file behind" \
        "leftovers: $(echo "$FIXTURE_ROOT"/.pensieve-landing-page.*)"
else
    pass "an aborted stamp leaves no temporary file behind"
fi

# ─── Gate: landing_page_assert_published ──────────────────────────────────

FILLED_PAGE="$(make_page filled "$VERSION_A" "$URL_A" "$SHA_A")"
assert_status "a page describing this build passes the gate" 0 "" \
    landing_page_assert_published "$FILLED_PAGE" "$SHA_A" "$VERSION_A" "$URL_A"

assert_status "a page advertising another build's checksum fails the gate" 1 "advertises checksum" \
    landing_page_assert_published "$FILLED_PAGE" "$SHA_B" "$VERSION_A" "$URL_A"

# The P1 this gate exists for: a parallel agent bumps <dd>Version</dd> while the
# build and notarization are in flight. The checksum still matches, so a
# checksum-only gate reported success for a page pairing 0.4.3's checksum with
# 0.4.4's version.
VERSION_DRIFT_PAGE="$(make_page version-drift "$VERSION_B" "$URL_A" "$SHA_A")"
assert_status "a version changed underneath the build fails the gate" 1 "advertises version" \
    landing_page_assert_published "$VERSION_DRIFT_PAGE" "$SHA_A" "$VERSION_A" "$URL_A"

URL_DRIFT_PAGE="$(make_page url-drift "$VERSION_A" "$URL_FOREIGN" "$SHA_A")"
assert_status "a download link repointed underneath the build fails the gate" 1 \
    "links the artifact" \
    landing_page_assert_published "$URL_DRIFT_PAGE" "$SHA_A" "$VERSION_A" "$URL_A"

assert_status "the gate refuses to run on half a contract" 2 "usage" \
    landing_page_assert_published "$FILLED_PAGE" "$SHA_A"

PLACEHOLDER_PAGE="$(make_page placeholder "$VERSION_A" "$URL_A" "$PLACEHOLDER")"
assert_status "an unfilled placeholder fails the gate" 1 "DO-NOT-SHIP" \
    landing_page_assert_published "$PLACEHOLDER_PAGE" "$SHA_A" "$VERSION_A" "$URL_A"

assert_status "a missing page fails the gate instead of passing for lack of a match" 1 \
    "no landing page at" \
    landing_page_assert_published "$FIXTURE_ROOT/absent.html" "$SHA_A" "$VERSION_A" "$URL_A"

UNREADABLE_GATE_PAGE="$(make_page unreadable-gate "$VERSION_A" "$URL_A" "$SHA_A")"
chmod 000 "$UNREADABLE_GATE_PAGE"
if [[ -r "$UNREADABLE_GATE_PAGE" ]]; then
    printf '%b[SKIP]%b unreadable-gate case: this user can read a 0000 file\n' "$C_RED" "$C_RESET"
else
    assert_status "an unreadable page fails the gate (grep's exit 2 is not 'no match')" 1 \
        "not readable" \
        landing_page_assert_published "$UNREADABLE_GATE_PAGE" "$SHA_A" "$VERSION_A" "$URL_A"
fi
chmod 644 "$UNREADABLE_GATE_PAGE"

assert_status "a page with two checksum slots fails the gate" 1 "exactly one" \
    landing_page_assert_published \
    "$(make_page gate-two "$VERSION_A" "$URL_A" "$SHA_A" "$SHA_A")" "$SHA_A" "$VERSION_A" "$URL_A"

# Same swallowed-record bug as in preflight, on the far more dangerous side:
# the page carries this build's checksum AND a stray second slot, and the gate
# used to report it as a single clean slot.
assert_status "a stray empty checksum slot cannot slip past the gate" 1 "found 2" \
    landing_page_assert_published \
    "$(make_page gate-empty-trailing "$VERSION_A" "$URL_A" "$SHA_A" "")" "$SHA_A" "$VERSION_A" "$URL_A"

assert_status "an expected checksum that is not a SHA-256 is a usage error" 2 \
    "not a lowercase SHA-256" \
    landing_page_assert_published "$FILLED_PAGE" "deadbeef" "$VERSION_A" "$URL_A"

# The value is this build's checksum and the slot's shape is untouched — only
# the algorithm the page names changed. The gate is the last thing standing
# between that page and the public.
assert_status "a page presenting our checksum as another algorithm fails the gate" 1 \
    "not labelled" landing_page_assert_published \
    "$(make_labelled_page gate-md5 "$VERSION_A" "$URL_A" '<b>MD5</b>' "$SHA_A")" \
    "$SHA_A" "$VERSION_A" "$URL_A"

assert_status "a stray empty version record cannot slip past the gate" 1 "found 2" \
    landing_page_assert_published \
    "$(make_versions_page gate-empty-trailing-version "$SHA_A" "$VERSION_A" "")" \
    "$SHA_A" "$VERSION_A" "$URL_A"

# A gate that opens the page once per field can report success for a page no
# revision of which was ever publishable — checksum read before an editor saved,
# version read after. All four fields now come from ONE snapshot, and the
# snapshot is proved to still be the page on disk. Simulated deterministically
# by making the two digest reads disagree, which is what a racing writer
# produces.
GATE_RACE_PAGE="$(make_page gate-race "$VERSION_A" "$URL_A" "$SHA_A")"
GATE_RACE_MARKER="$FIXTURE_ROOT/gate-race-digest-taken"
# Overrides the lib's own function; the call comes back through
# landing_page_assert_published, not from a name mentioned in this file.
# shellcheck disable=SC2329
landing_page_digest() {
    if [[ -e "$GATE_RACE_MARKER" ]]; then
        printf 'bbbb%060d\n' 0
    else
        : >"$GATE_RACE_MARKER"
        printf 'aaaa%060d\n' 0
    fi
}
assert_status "a page rewritten while the gate reads it fails instead of passing on mixed revisions" 1 \
    "changed while this release was validating it" \
    landing_page_assert_published "$GATE_RACE_PAGE" "$SHA_A" "$VERSION_A" "$URL_A"
# shellcheck source=scripts/lib/landing-page.sh
source "$LANDING_PAGE_LIB"

# …and the isolation itself, which the race test above cannot see: every field
# has to be read from the SAME file, and that file must not be the page. A gate
# reading the page once per field is exactly how checksum and version end up
# describing different revisions.
READS_LOG="$FIXTURE_ROOT/gate-reads"
: >"$READS_LOG"
# Overrides of the lib's parsers; the calls come back through
# landing_page_assert_published, not from names mentioned in this file.
# shellcheck disable=SC2329
landing_page_checksum_values() {
    printf '%s\n' "$1" >>"$READS_LOG"
    printf '%s\n' "$SHA_A"
}
# shellcheck disable=SC2329
landing_page_declared_version() {
    printf '%s\n' "$1" >>"$READS_LOG"
    printf '%s\n' "$VERSION_A"
}
# shellcheck disable=SC2329
landing_page_artifact_urls() {
    printf '%s\n' "$1" >>"$READS_LOG"
    printf '%s\n%s\n%s\n' "$URL_A" "$URL_A" "$URL_A"
}
ISOLATION_PAGE="$(make_page gate-isolation "$VERSION_A" "$URL_A" "$SHA_A")"
if landing_page_assert_published "$ISOLATION_PAGE" "$SHA_A" "$VERSION_A" "$URL_A"; then
    READ_PATHS="$(sort -u "$READS_LOG")"
    if [[ "$(wc -l <"$READS_LOG" | tr -d ' ')" -ge 2 ]] \
        && [[ "$(printf '%s\n' "$READ_PATHS" | wc -l | tr -d ' ')" == "1" ]] \
        && [[ "$READ_PATHS" != "$ISOLATION_PAGE" ]]; then
        pass "every field the gate asserts is read from one snapshot, not from the page"
    else
        fail "every field the gate asserts is read from one snapshot, not from the page" \
            "paths read: $(tr '\n' ' ' <"$READS_LOG")"
    fi
else
    fail "every field the gate asserts is read from one snapshot, not from the page" \
        "the gate rejected a page all of whose fields were stubbed as correct"
fi
# shellcheck source=scripts/lib/landing-page.sh
source "$LANDING_PAGE_LIB"

if compgen -G "${TMPDIR:-/tmp}/pensieve-landing-page-gate.*" >/dev/null; then
    fail "the gate leaves no snapshot behind" \
        "leftovers: $(echo "${TMPDIR:-/tmp}"/pensieve-landing-page-gate.*)"
else
    pass "the gate leaves no snapshot behind"
fi

# ─── Lane contract in scripts/build-release.sh ────────────────────────────
# The page belongs to the lane that publishes a notarized DMG. `make
# release-local` (--no-notarize --no-dmg) builds on a tree that deliberately
# keeps the unfilled placeholder, so an unconditional gate breaks it — that is
# the exact regression this section pins.

RELEASE_SCRIPT="$SCRIPT_DIR/build-release.sh"

if grep -q 'if (( DO_DMG \&\& DO_NOTARIZE )); then' "$RELEASE_SCRIPT" \
    && grep -q '^    PUBLISHES_DMG=1$' "$RELEASE_SCRIPT"; then
    pass "the publishable lane is exactly DO_DMG && DO_NOTARIZE"
else
    fail "the publishable lane is exactly DO_DMG && DO_NOTARIZE" \
        "no 'if (( DO_DMG && DO_NOTARIZE ))' / PUBLISHES_DMG=1 pair in build-release.sh"
fi

UNGUARDED="$(awk '
    /^if \(\( PUBLISHES_DMG \)\); then$/ { guard = 1; next }
    /^fi$/ { guard = 0; next }
    /landing_page_(assert|stamp)/ { if (!guard) printf "%d: %s\n", NR, $0 }
' "$RELEASE_SCRIPT")"
if [[ -z "$UNGUARDED" ]]; then
    pass "every landing-page call in build-release.sh sits behind the publishable-lane guard"
else
    fail "every landing-page call in build-release.sh sits behind the publishable-lane guard" \
        "unguarded: $UNGUARDED"
fi

# Both gates — the one right after stamping and the one at the end of the run —
# must assert the whole published contract. The final gate asserting only the
# checksum is what let a mid-build version bump through.
GATE_CALLS="$(grep -c \
    'landing_page_assert_published .*LANDING_PAGE.*DMG_SHA256.*APP_VERSION.*LANDING_PAGE_ARTIFACT_URL' \
    "$RELEASE_SCRIPT" || true)"
if [[ "$GATE_CALLS" == "2" ]]; then
    pass "both landing-page gates assert checksum, version and artifact URL together"
else
    fail "both landing-page gates assert checksum, version and artifact URL together" \
        "expected 2 full-contract gate calls in build-release.sh, found $GATE_CALLS"
fi

if grep -q 'landing_page_assert_publishable .*LANDING_PAGE.*APP_VERSION.*LANDING_PAGE_ARTIFACT_URL' \
    "$RELEASE_SCRIPT"; then
    pass "preflight checks the artifact URL before anything is built"
else
    fail "preflight checks the artifact URL before anything is built" \
        "no landing_page_assert_publishable call carrying \$LANDING_PAGE_ARTIFACT_URL"
fi

if grep -Eq "grep .*(DO-NOT-SHIP|docs/index\.html)" "$RELEASE_SCRIPT"; then
    fail "the release script no longer gates the page with a bare grep" \
        "a bare grep on docs/index.html cannot tell 'no marker' (exit 1) from 'unreadable' (exit 2)"
else
    pass "the release script no longer gates the page with a bare grep"
fi

# ─── Provenance contract in scripts/lib/build-provenance.sh ───────────────
# The stamping helper is sourced by the release script and mutates a published
# file (docs/index.html), so it is a runtime input like every other release
# helper: a release must refuse to run with local edits to it, seal it into the
# input digest, and materialize it from the commit it claims to build.

# The release enumerates its own helpers by hand in several places — the git
# archive that materializes a snapshot, the digest's existence check and hash
# list, the archive that reproduces a commit, and the two `git status` lists
# that decide whether the inputs are clean. Sealing a NEW helper into provenance
# means editing every one of them, and a list quietly left behind does not fail
# the release it belongs to: `landing-page.sh` reached the digest but not
# build-release.sh's snapshot archive, and every lane that snapshots died on
# "required runtime input is missing" AFTER preflight.
#
# So the invariant is checked structurally rather than per helper: any
# multi-line list in the release scripts that names one release helper must name
# them ALL. That is what makes the next helper's omission a test failure here
# instead of a broken release lane, whatever the helper is called.
RELEASE_HELPERS='bundle-identity.sh build-keychain.sh build-provenance.sh landing-page.sh rpath-hygiene.sh'
RELEASE_ENUMERATORS=(
    "$SCRIPT_DIR/build-release.sh"
    "$SCRIPT_DIR/lib/build-provenance.sh"
    "$SCRIPT_DIR/lib/isolated-app.sh"
)
HELPER_LISTS="$(awk -v helpers="$RELEASE_HELPERS" '
    function flush(   name, missing) {
        if (lines >= 2 && named) {
            missing = ""
            for (name in required) {
                if (!(name in seen)) {
                    missing = missing " " name
                }
            }
            printf "%s\t%s\t%d\t%s\n", (missing == "" ? "OK" : "MISSING"), \
                FILENAME, start, missing
        }
        lines = 0
        named = 0
        split("", seen)
    }
    BEGIN { split(helpers, list, " "); for (i in list) required[list[i]] }
    FNR == 1 { flush(); open = 0 }
    {
        if (!open) { start = FNR; lines = 0; named = 0; split("", seen) }
        open = 1
        lines++
        if (match($0, /scripts\/lib\/[A-Za-z0-9._-]+\.sh/)) {
            name = substr($0, RSTART, RLENGTH)
            sub(/.*\//, "", name)
            if (name in required) { seen[name]; named = 1 }
        }
        if ($0 !~ /\\[ \t]*$/) { flush(); open = 0 }
    }
    END { flush() }
' "${RELEASE_ENUMERATORS[@]}")"

INCOMPLETE_LISTS="$(printf '%s\n' "$HELPER_LISTS" | grep '^MISSING' || true)"
if [[ -z "$INCOMPLETE_LISTS" ]]; then
    pass "every release-helper list in the release scripts names every release helper"
else
    fail "every release-helper list in the release scripts names every release helper" \
        "incomplete: $(printf '%s' "$INCOMPLETE_LISTS" | tr '\n\t' '; ')"
fi

# …and the check above cannot pass by finding nothing: each enumerator really
# does declare at least one such list, so a matcher that stopped matching is a
# failure rather than a silent all-clear.
UNSCANNED=""
for enumerator in "${RELEASE_ENUMERATORS[@]}"; do
    printf '%s\n' "$HELPER_LISTS" | grep -q "^OK	$enumerator	" \
        || UNSCANNED="$UNSCANNED $enumerator"
done
if [[ -z "$UNSCANNED" ]]; then
    pass "the release-helper list check really reaches every release script"
else
    fail "the release-helper list check really reaches every release script" \
        "no complete helper list found in:$UNSCANNED"
fi

printf '\n'
if (( FAIL_COUNT > 0 )); then
    printf "${C_RED}[fail]${C_RESET} landing-page: %d passed, %d failed\n" "$PASS_COUNT" "$FAIL_COUNT"
    exit 1
fi
printf "${C_GREEN}[ ok ]${C_RESET} landing-page: %d passed, 0 failed\n" "$PASS_COUNT"
