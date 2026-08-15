#!/usr/bin/env bash
# Unit tests for scripts/lib/landing-page.sh — the guard that keeps the public
# download page's SHA-256 tied to the DMG the release actually produced.
#
# Self-contained: synthetic HTML fixtures in a mktemp dir, no build, no
# codesign, no network. Runs in well under a second, so it belongs in
# `make gates` (see the test-scripts target).
#
# Usage: ./scripts/test-landing-page.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/landing-page.sh
source "$SCRIPT_DIR/lib/landing-page.sh"

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

# make_page <name> <version> <checksum-slot-payload>… → prints the page path
# One slot payload per checksum <div>; zero payloads yields a page with none.
make_page() {
    local name="$1"
    local version="$2"
    shift 2
    local page="$FIXTURE_ROOT/$name.html"
    local payload

    {
        printf '<!doctype html>\n<html>\n  <body>\n'
        printf '    <dl>\n      <div><dt>Version</dt><dd>%s</dd></div>\n' "$version"
        printf '      <div><dt>Platform</dt><dd>macOS 15+</dd></div>\n    </dl>\n'
        for payload in "$@"; do
            printf '    <div class="sha"><b>SHA-256</b><br />%s</div>\n' "$payload"
        done
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

GOOD_PAGE="$(make_page good "$VERSION_A" "$PLACEHOLDER")"
assert_status "a placeholder page for this version is stampable" 0 "" \
    landing_page_assert_publishable "$GOOD_PAGE" "$VERSION_A"

assert_status "a missing page is a failure, not a silent pass" 1 "no landing page at" \
    landing_page_assert_publishable "$FIXTURE_ROOT/absent.html" "$VERSION_A"

UNREADABLE_PAGE="$(make_page unreadable "$VERSION_A" "$PLACEHOLDER")"
chmod 000 "$UNREADABLE_PAGE"
if [[ -r "$UNREADABLE_PAGE" ]]; then
    # root (or an ACL-permissive volume) can read a 000 file; the case is then
    # untestable here rather than passing vacuously.
    printf '%b[SKIP]%b unreadable-page case: this user can read a 0000 file\n' "$C_RED" "$C_RESET"
else
    assert_status "an unreadable page is a failure, not a silent pass" 1 "not readable" \
        landing_page_assert_publishable "$UNREADABLE_PAGE" "$VERSION_A"
fi
chmod 644 "$UNREADABLE_PAGE"

READONLY_PAGE="$(make_page readonly "$VERSION_A" "$PLACEHOLDER")"
chmod 444 "$READONLY_PAGE"
if [[ -w "$READONLY_PAGE" ]]; then
    printf '%b[SKIP]%b read-only-page case: this user can write a 0444 file\n' "$C_RED" "$C_RESET"
else
    assert_status "a page the release cannot stamp is rejected up front" 1 "not writable" \
        landing_page_assert_publishable "$READONLY_PAGE" "$VERSION_A"
fi
chmod 644 "$READONLY_PAGE"

NO_SLOT_PAGE="$(make_page no-slot "$VERSION_A")"
assert_status "a page with no checksum slot is rejected" 1 "exactly one" \
    landing_page_assert_publishable "$NO_SLOT_PAGE" "$VERSION_A"

TWO_SLOT_PAGE="$(make_page two-slots "$VERSION_A" "$PLACEHOLDER" "$SHA_A")"
assert_status "an ambiguous page with two checksum slots is rejected" 1 "exactly one" \
    landing_page_assert_publishable "$TWO_SLOT_PAGE" "$VERSION_A"

RESHAPED_PAGE="$FIXTURE_ROOT/reshaped.html"
printf '<div><dt>Version</dt><dd>%s</dd></div>\n<div class="sha">%s</div>\n' \
    "$VERSION_A" "$PLACEHOLDER" >"$RESHAPED_PAGE"
assert_status "a checksum slot in an unknown shape is rejected, not stamped blindly" 1 \
    "no longer" landing_page_assert_publishable "$RESHAPED_PAGE" "$VERSION_A"

assert_status "a page advertising another version is rejected before the build" 1 \
    "advertises version" landing_page_assert_publishable "$GOOD_PAGE" "$VERSION_B"

NO_VERSION_PAGE="$FIXTURE_ROOT/no-version.html"
printf '<div class="sha"><b>SHA-256</b><br />%s</div>\n' "$PLACEHOLDER" >"$NO_VERSION_PAGE"
assert_status "a page that declares no download version is rejected" 1 \
    "exactly one download version" landing_page_assert_publishable "$NO_VERSION_PAGE" "$VERSION_A"

# ─── Stamping: landing_page_stamp_checksum ────────────────────────────────

STAMP_PAGE="$(make_page stamp "$VERSION_A" "$PLACEHOLDER")"
BEFORE_LINES="$(wc -l <"$STAMP_PAGE")"
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
else
    fail "stamping replaces the placeholder with the build's checksum" "stamp call failed"
fi

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
    landing_page_stamp_checksum "$(make_page stamp-no-slot "$VERSION_A")" "$SHA_A"

# ─── Gate: landing_page_assert_checksum ───────────────────────────────────

FILLED_PAGE="$(make_page filled "$VERSION_A" "$SHA_A")"
assert_status "a page advertising this build's checksum passes the gate" 0 "" \
    landing_page_assert_checksum "$FILLED_PAGE" "$SHA_A"

assert_status "a page advertising another build's checksum fails the gate" 1 "advertises checksum" \
    landing_page_assert_checksum "$FILLED_PAGE" "$SHA_B"

PLACEHOLDER_PAGE="$(make_page placeholder "$VERSION_A" "$PLACEHOLDER")"
assert_status "an unfilled placeholder fails the gate" 1 "DO-NOT-SHIP" \
    landing_page_assert_checksum "$PLACEHOLDER_PAGE" "$SHA_A"

assert_status "a missing page fails the gate instead of passing for lack of a match" 1 \
    "no landing page at" landing_page_assert_checksum "$FIXTURE_ROOT/absent.html" "$SHA_A"

UNREADABLE_GATE_PAGE="$(make_page unreadable-gate "$VERSION_A" "$SHA_A")"
chmod 000 "$UNREADABLE_GATE_PAGE"
if [[ -r "$UNREADABLE_GATE_PAGE" ]]; then
    printf '%b[SKIP]%b unreadable-gate case: this user can read a 0000 file\n' "$C_RED" "$C_RESET"
else
    assert_status "an unreadable page fails the gate (grep's exit 2 is not 'no match')" 1 \
        "not readable" landing_page_assert_checksum "$UNREADABLE_GATE_PAGE" "$SHA_A"
fi
chmod 644 "$UNREADABLE_GATE_PAGE"

assert_status "a page with two checksum slots fails the gate" 1 "exactly one" \
    landing_page_assert_checksum "$(make_page gate-two "$VERSION_A" "$SHA_A" "$SHA_A")" "$SHA_A"

assert_status "an expected checksum that is not a SHA-256 is a usage error" 2 \
    "not a lowercase SHA-256" landing_page_assert_checksum "$FILLED_PAGE" "deadbeef"

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

if grep -Eq "grep .*(DO-NOT-SHIP|docs/index\.html)" "$RELEASE_SCRIPT"; then
    fail "the release script no longer gates the page with a bare grep" \
        "a bare grep on docs/index.html cannot tell 'no marker' (exit 1) from 'unreadable' (exit 2)"
else
    pass "the release script no longer gates the page with a bare grep"
fi

printf '\n'
if (( FAIL_COUNT > 0 )); then
    printf "${C_RED}[fail]${C_RESET} landing-page: %d passed, %d failed\n" "$PASS_COUNT" "$FAIL_COUNT"
    exit 1
fi
printf "${C_GREEN}[ ok ]${C_RESET} landing-page: %d passed, 0 failed\n" "$PASS_COUNT"
