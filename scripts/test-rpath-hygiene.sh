#!/usr/bin/env bash
# Unit tests for scripts/lib/rpath-hygiene.sh — the guard that stops the release
# lane from shipping an app binary whose LC_RPATH list points at the builder's
# own filesystem (a load-path hazard first, a path leak second).
#
# Self-contained: the fixtures are tiny Mach-O executables linked on the spot
# with `cc -Wl,-rpath,…` in a mktemp dir. No codesign, no swift build, no
# network, well under a second — so it belongs in `make gates` next to
# test-bundle-identity.sh (see the test-scripts target).
#
# Usage: ./scripts/test-rpath-hygiene.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The source= directive lets `shellcheck -x` follow the lib; the plain hook run
# has no -x, hence the SC1091 pair (same idiom as scripts/build-release.sh).
# shellcheck source=scripts/lib/rpath-hygiene.sh
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/rpath-hygiene.sh"

C_GREEN='\033[32m'
C_RED='\033[31m'
C_RESET='\033[0m'

if ! command -v cc >/dev/null 2>&1; then
    printf '%b[fail]%b rpath-hygiene: cc is required to link the Mach-O fixtures\n' "$C_RED" "$C_RESET"
    exit 1
fi

FIXTURE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/pensieve-rpath-hygiene.XXXXXX")"
cleanup() {
    if [[ -n "${FIXTURE_ROOT:-}" && -d "$FIXTURE_ROOT" ]]; then
        rm -rf "$FIXTURE_ROOT"
    fi
    return 0
}
trap cleanup EXIT

# Deliberately synthetic builder paths: they must not resemble any real checkout
# on the machine running the suite, or a stale rpath could pass by accident.
ABS_VENDOR="/Users/fixture-builder/checkout/Pensieve/Vendor/qube-ffi/release"
ABS_TOOLCHAIN="/Fixtures/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift-9.9/macosx"
# A space in an rpath is the shape that breaks naive `awk '{print $2}'` parsing.
ABS_SPACED="/Users/fixture builder/Vendor with space"
REL_FRAMEWORKS="@executable_path/../Frameworks"
REL_LOADER="@loader_path"

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

# link_binary <name> [rpath]… → prints the binary path
# Links a do-nothing executable carrying exactly the requested LC_RPATH entries,
# in the requested order. `args` always holds -o/source, so it is never an empty
# array — the expansion is safe under bash 3.2 + `set -u`.
link_binary() {
    local binary="$FIXTURE_ROOT/$1"
    local source_file="$FIXTURE_ROOT/$1.c"
    shift
    printf 'int main(void) { return 0; }\n' >"$source_file"
    local args=(-o "$binary" "$source_file")
    local rpath flag
    for rpath in "$@"; do
        flag="-Wl,-rpath,$rpath"
        args+=("$flag")
    done
    cc "${args[@]}"
    printf '%s\n' "$binary"
}

# assert_eq <description> <expected> <actual>
assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        pass "$desc"
    else
        fail "$desc" "expected [$expected], got [$actual]"
    fi
}

# assert_clean <description> <binary>
assert_clean() {
    local desc="$1" binary="$2"
    local output status=0
    output="$(rpath_assert_clean "$binary" 2>&1)" || status=$?
    if (( status == 0 )); then
        pass "$desc"
    else
        fail "$desc" "expected acceptance, got exit $status: ${output:-<no output>}"
    fi
}

# assert_dirty <description> <expected stderr substring> <binary>
assert_dirty() {
    local desc="$1" needle="$2" binary="$3"
    local output status=0
    output="$(rpath_assert_clean "$binary" 2>&1)" || status=$?
    if (( status == 0 )); then
        fail "$desc" "expected rejection, but the binary was accepted"
    elif [[ "$output" != *"$needle"* ]]; then
        fail "$desc" "rejected, but the diagnostic never mentions '$needle': ${output:-<no output>}"
    else
        pass "$desc"
    fi
}

printf "Testing rpath-hygiene (fixtures: %s)\n\n" "$FIXTURE_ROOT"

# ── Reading ───────────────────────────────────────────────────────────────
MIXED="$(link_binary mixed "$ABS_VENDOR" "$REL_FRAMEWORKS" "$ABS_SPACED" "$REL_LOADER")"

assert_eq "rpath_entries lists every LC_RPATH in load order" \
    "$ABS_VENDOR
$REL_FRAMEWORKS
$ABS_SPACED
$REL_LOADER" \
    "$(rpath_entries "$MIXED")"

assert_eq "rpath_absolute_entries keeps absolute paths, including one with a space" \
    "$ABS_VENDOR
$ABS_SPACED" \
    "$(rpath_absolute_entries "$MIXED")"

# ── The gate ──────────────────────────────────────────────────────────────
assert_dirty "a builder Vendor rpath is rejected" "$ABS_VENDOR" "$MIXED"
assert_dirty "the diagnostic names EVERY offender, not just the first" "$ABS_SPACED" "$MIXED"

LOADER_ONLY="$(link_binary loader-only "$REL_FRAMEWORKS" "$REL_LOADER")"
assert_clean "loader-relative rpaths only is accepted" "$LOADER_ONLY"

NO_RPATH="$(link_binary no-rpath)"
assert_clean "a binary with no LC_RPATH at all is accepted" "$NO_RPATH"

# ── Stripping ─────────────────────────────────────────────────────────────
STRIPPED="$(link_binary stripped "$ABS_VENDOR" "$REL_FRAMEWORKS" "$ABS_TOOLCHAIN" "$ABS_SPACED" "$REL_LOADER")"
rpath_strip_absolute "$STRIPPED"

assert_eq "strip removes every absolute rpath and preserves relative order" \
    "$REL_FRAMEWORKS
$REL_LOADER" \
    "$(rpath_entries "$STRIPPED")"

assert_clean "the stripped binary passes the gate" "$STRIPPED"

rpath_strip_absolute "$STRIPPED"
assert_eq "strip is idempotent" \
    "$REL_FRAMEWORKS
$REL_LOADER" \
    "$(rpath_entries "$STRIPPED")"

ALL_ABSOLUTE="$(link_binary all-absolute "$ABS_VENDOR" "$ABS_TOOLCHAIN")"
rpath_strip_absolute "$ALL_ABSOLUTE"
assert_eq "a binary whose rpaths were ALL absolute ends up with none" \
    "" \
    "$(rpath_entries "$ALL_ABSOLUTE")"

# ── Resolvability after the strip ─────────────────────────────────────────
# A binary that links @rpath/libfixture.dylib, mirroring how the app links
# @rpath/libqube_ffi.dylib after the release script repoints it.
FRAMEWORKS="$FIXTURE_ROOT/Frameworks"
mkdir -p "$FRAMEWORKS"
printf 'int fixture_symbol(void) { return 7; }\n' >"$FIXTURE_ROOT/libfixture.c"
cc -dynamiclib -install_name "@rpath/libfixture.dylib" \
    -o "$FRAMEWORKS/libfixture.dylib" "$FIXTURE_ROOT/libfixture.c"
printf 'int fixture_symbol(void); int main(void) { return fixture_symbol() - 7; }\n' \
    >"$FIXTURE_ROOT/linked.c"
LINKED="$FIXTURE_ROOT/linked"
cc -o "$LINKED" "$FIXTURE_ROOT/linked.c" "$FRAMEWORKS/libfixture.dylib" \
    -Wl,-rpath,"$ABS_VENDOR" -Wl,-rpath,"$REL_FRAMEWORKS"

assert_eq "rpath_dependencies lists the @rpath install names an executable links" \
    "@rpath/libfixture.dylib" \
    "$(rpath_dependencies "$LINKED")"

STATUS=0
rpath_assert_resolvable "$LINKED" "$FRAMEWORKS" || STATUS=$?
assert_eq "an @rpath dependency present in the search dir resolves" "0" "$STATUS"

STATUS=0
rpath_assert_resolvable "$LINKED" "$FIXTURE_ROOT/empty-frameworks" >/dev/null 2>&1 || STATUS=$?
assert_eq "an @rpath dependency missing from the search dir is rejected" "1" "$STATUS"

OUTPUT="$(rpath_assert_resolvable "$LINKED" "$FIXTURE_ROOT/empty-frameworks" 2>&1 || true)"
if [[ "$OUTPUT" == *"@rpath/libfixture.dylib"* ]]; then
    pass "the unresolvable-dependency diagnostic names the dependency"
else
    fail "the unresolvable-dependency diagnostic names the dependency" \
        "diagnostic was: ${OUTPUT:-<no output>}"
fi

STATUS=0
rpath_assert_resolvable "$NO_RPATH" "$FRAMEWORKS" || STATUS=$?
assert_eq "a binary with no @rpath dependencies resolves trivially" "0" "$STATUS"

# The whole point of the pair: strip, then prove the binary still resolves.
rpath_strip_absolute "$LINKED"
assert_clean "the stripped linked binary passes the absolute-rpath gate" "$LINKED"
STATUS=0
rpath_assert_resolvable "$LINKED" "$FRAMEWORKS" || STATUS=$?
assert_eq "the stripped linked binary still resolves its @rpath dependency" "0" "$STATUS"

# ── Refusals ──────────────────────────────────────────────────────────────
assert_dirty "a path that does not exist is rejected, not treated as clean" \
    "no file at" \
    "$FIXTURE_ROOT/absent"

printf 'not a Mach-O binary\n' >"$FIXTURE_ROOT/plain.txt"
assert_dirty "a non-Mach-O file is rejected, not treated as clean" \
    "not a readable Mach-O binary" \
    "$FIXTURE_ROOT/plain.txt"

STATUS=0
rpath_assert_clean "" >/dev/null 2>&1 || STATUS=$?
assert_eq "rpath_assert_clean with no argument is a usage error (2), not a pass" "2" "$STATUS"

STATUS=0
rpath_strip_absolute "" >/dev/null 2>&1 || STATUS=$?
assert_eq "rpath_strip_absolute with no argument is a usage error (2), not a pass" "2" "$STATUS"

STATUS=0
rpath_strip_absolute "$FIXTURE_ROOT/plain.txt" >/dev/null 2>&1 || STATUS=$?
assert_eq "rpath_strip_absolute refuses a non-Mach-O file instead of reporting success" "1" "$STATUS"

printf '\n'
if (( FAIL_COUNT > 0 )); then
    printf "${C_RED}[fail]${C_RESET} rpath-hygiene: %d passed, %d failed\n" "$PASS_COUNT" "$FAIL_COUNT"
    exit 1
fi
printf "${C_GREEN}[ ok ]${C_RESET} rpath-hygiene: %d passed, 0 failed\n" "$PASS_COUNT"
