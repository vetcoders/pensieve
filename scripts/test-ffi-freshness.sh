#!/usr/bin/env bash
# Unit tests for Pensieve/scripts/check-ffi-freshness.sh — the donor pin for
# vendored libcodescribe_ffi.dylib (and the optional leftover qube-ffi).
#
# Self-contained: synthetic git checkouts + provenance files in a mktemp tree
# that mirrors ../../codescribe relative to Pensieve/. No cargo, no codesign,
# no network. Belongs in `make gates` (see the test-scripts target).
#
# Usage: ./scripts/test-ffi-freshness.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="$SCRIPT_DIR/../Pensieve/scripts/check-ffi-freshness.sh"

C_GREEN='\033[32m'
C_RED='\033[31m'
C_RESET='\033[0m'

if [[ ! -x "$CHECK" && ! -f "$CHECK" ]]; then
    printf '%b[fail]%b ffi-freshness: missing %s\n' "$C_RED" "$C_RESET" "$CHECK"
    exit 1
fi

FIXTURE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/pensieve-ffi-freshness.XXXXXX")"
cleanup() {
    if [[ -n "${FIXTURE_ROOT:-}" && -d "$FIXTURE_ROOT" ]]; then
        chmod -R u+rwx "$FIXTURE_ROOT" 2>/dev/null || true
        rm -rf "$FIXTURE_ROOT"
    fi
    return 0
}
trap cleanup EXIT

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

# layout: $FIX/pensieve/Pensieve  →  default donor $FIX/codescribe
PENSIEVE_ROOT="$FIXTURE_ROOT/pensieve/Pensieve"
CODESCRIBE_DEFAULT="$FIXTURE_ROOT/codescribe"
VISTA_DEFAULT="$FIXTURE_ROOT/vista-kernel"
mkdir -p \
    "$PENSIEVE_ROOT/Vendor/codescribe-ffi/debug" \
    "$PENSIEVE_ROOT/Vendor/codescribe-ffi/release" \
    "$PENSIEVE_ROOT/Vendor/qube-ffi/debug"

write_dylib() {
    local path="$1" payload="$2"
    printf '%s\n' "$payload" >"$path"
}

dylib_sha() {
    shasum -a 256 "$1" | awk '{print $1}'
}

git_commit_tree() {
    local repo="$1" message="$2"
    mkdir -p "$repo"
    git -C "$repo" init -q
    git -C "$repo" checkout -q -b main 2>/dev/null || git -C "$repo" checkout -q -B main
    printf '%s\n' "$message" >"$repo/README"
    git -C "$repo" add README
    git -C "$repo" \
        -c user.email=ffi-check@test \
        -c user.name=ffi-check \
        commit -q -m "$message"
}

write_codescribe_provenance() {
    local head="$1" sha="$2" profile="${3:-debug}" describe="${4:-}"
    if [[ -z "$describe" ]]; then
        describe="$head"
    fi
    cat >"$PENSIEVE_ROOT/Vendor/codescribe-ffi/PROVENANCE.txt" <<EOF
codescribe-root=$CODESCRIBE_DEFAULT
codescribe-head=$head
codescribe-describe=$describe
ffi-profile=$profile
dylib-sha256=$sha
built-at=2026-01-01T00:00:00Z
host=ffi-freshness-fixture
EOF
}

write_qube_provenance() {
    local head="$1" describe="${2:-$1}"
    cat >"$PENSIEVE_ROOT/Vendor/qube-ffi/PROVENANCE.txt" <<EOF
vista-kernel-root=$VISTA_DEFAULT
vista-kernel-head=$head
vista-kernel-describe=$describe
ffi-profile=debug
built-at=2026-01-01T00:00:00Z
host=ffi-freshness-fixture
EOF
}

# run_check [CODESCRIBE_ROOT|-] [VISTA_KERNEL_ROOT|-] [FFI_CHECK_STRICT]
# `-` or omitted means unset. Sets CHECK_STATUS, CHECK_OUT.
run_check() {
    local env_codescribe="${1:-}"
    local env_vista="${2:-}"
    local env_strict="${3:-}"
    local env_args
    CHECK_OUT=""
    CHECK_STATUS=0
    env_args=(env -u VISTA_KERNEL_ROOT -u CODESCRIBE_ROOT -u FFI_CHECK_STRICT
        PENSIEVE_ROOT="$PENSIEVE_ROOT")
    if [[ -n "$env_codescribe" && "$env_codescribe" != "-" ]]; then
        env_args+=(CODESCRIBE_ROOT="$env_codescribe")
    fi
    if [[ -n "$env_vista" && "$env_vista" != "-" ]]; then
        env_args+=(VISTA_KERNEL_ROOT="$env_vista")
    fi
    if [[ -n "$env_strict" ]]; then
        env_args+=(FFI_CHECK_STRICT="$env_strict")
    fi
    env_args+=(/bin/bash "$CHECK")
    CHECK_OUT="$("${env_args[@]}" 2>&1)" || CHECK_STATUS=$?
}

assert_contains() {
    local desc="$1" needle="$2"
    if [[ "$CHECK_OUT" == *"$needle"* ]]; then
        pass "$desc"
    else
        fail "$desc" "expected to contain [$needle], got: ${CHECK_OUT:-<empty>}"
    fi
}

assert_not_contains() {
    local desc="$1" needle="$2"
    if [[ "$CHECK_OUT" == *"$needle"* ]]; then
        fail "$desc" "did not expect [$needle] in: $CHECK_OUT"
    else
        pass "$desc"
    fi
}

assert_exit() {
    local desc="$1" expected="$2"
    if [[ "$CHECK_STATUS" -eq "$expected" ]]; then
        pass "$desc"
    else
        fail "$desc" "expected exit $expected, got $CHECK_STATUS: ${CHECK_OUT:-<empty>}"
    fi
}

printf "Testing ffi-freshness (fixtures: %s)\n\n" "$FIXTURE_ROOT"

# ── A. no sibling checkouts ───────────────────────────────────────────────
run_check
assert_exit "missing codescribe is warn-only (exit 0)" 0
assert_contains "missing codescribe names the default sibling" "codescribe checkout not found"
assert_not_contains "missing vista-kernel is silent when unset" "vista-kernel checkout not found"

# ── B. matching codescribe pin ────────────────────────────────────────────
git_commit_tree "$CODESCRIBE_DEFAULT" "donor-a"
HEAD_A="$(git -C "$CODESCRIBE_DEFAULT" rev-parse HEAD)"
write_dylib "$PENSIEVE_ROOT/Vendor/codescribe-ffi/debug/libcodescribe_ffi.dylib" "blob-a"
SHA_A="$(dylib_sha "$PENSIEVE_ROOT/Vendor/codescribe-ffi/debug/libcodescribe_ffi.dylib")"
write_codescribe_provenance "$HEAD_A" "$SHA_A" debug
run_check
assert_exit "matching codescribe pin is exit 0" 0
assert_contains "matching codescribe pin prints HEAD" "$HEAD_A"
assert_not_contains "matching pin does not mention missing vista" "vista-kernel checkout not found"

# ── C. stale HEAD ─────────────────────────────────────────────────────────
git_commit_tree "$CODESCRIBE_DEFAULT" "donor-b"
HEAD_B="$(git -C "$CODESCRIBE_DEFAULT" rev-parse HEAD)"
run_check
assert_exit "stale codescribe is warn-only by default" 0
assert_contains "stale codescribe names both HEADs" "provenance $HEAD_A != codescribe HEAD $HEAD_B"
assert_contains "stale hint names the vendor script" "build-codescribe-ffi.sh"

# ── D. FFI_CHECK_STRICT fails closed on stale ─────────────────────────────
run_check "-" "-" "1"
assert_exit "strict mode fails on stale codescribe" 1
assert_contains "strict stale still names the HEADs" "provenance $HEAD_A != codescribe HEAD $HEAD_B"

# ── E. missing provenance ─────────────────────────────────────────────────
rm -f "$PENSIEVE_ROOT/Vendor/codescribe-ffi/PROVENANCE.txt"
run_check
assert_exit "missing provenance is warn-only" 0
assert_contains "missing provenance names the stamp script" "build-codescribe-ffi.sh"

# ── F. UNSTAMPED pin ──────────────────────────────────────────────────────
write_codescribe_provenance "UNSTAMPED" "$SHA_A" debug
run_check
assert_contains "UNSTAMPED pin asks for a rebuild" "unpinned"

# ── G. sha mismatch ───────────────────────────────────────────────────────
write_codescribe_provenance "$HEAD_B" "$SHA_A" debug
write_dylib "$PENSIEVE_ROOT/Vendor/codescribe-ffi/debug/libcodescribe_ffi.dylib" "blob-b"
run_check
assert_contains "dylib sha mismatch is reported" "dylib sha256"

# ── H. explicit missing VISTA_KERNEL_ROOT warns ───────────────────────────
write_dylib "$PENSIEVE_ROOT/Vendor/codescribe-ffi/debug/libcodescribe_ffi.dylib" "blob-b"
SHA_B="$(dylib_sha "$PENSIEVE_ROOT/Vendor/codescribe-ffi/debug/libcodescribe_ffi.dylib")"
write_codescribe_provenance "$HEAD_B" "$SHA_B" debug
run_check "-" "$FIXTURE_ROOT/no-such-vista"
assert_contains "explicit missing vista-kernel still warns" "vista-kernel checkout not found"

# ── I. optional qube-ffi when vista-kernel exists ─────────────────────────
git_commit_tree "$VISTA_DEFAULT" "vista-a"
VISTA_HEAD="$(git -C "$VISTA_DEFAULT" rev-parse HEAD)"
write_qube_provenance "$VISTA_HEAD"
run_check
assert_contains "vista present and matching prints qube pin" "qube-ffi provenance matches vista-kernel HEAD $VISTA_HEAD"
assert_contains "codescribe still checked when vista is present" "codescribe-ffi provenance matches codescribe HEAD $HEAD_B"

# ── J. dirty vista describe ───────────────────────────────────────────────
write_qube_provenance "$VISTA_HEAD" "${VISTA_HEAD}-dirty"
run_check
assert_contains "dirty vista-kernel describe is reported" "DIRTY vista-kernel"

printf '\n'
if (( FAIL_COUNT > 0 )); then
    printf "${C_RED}[fail]${C_RESET} ffi-freshness: %d passed, %d failed\n" "$PASS_COUNT" "$FAIL_COUNT"
    exit 1
fi
printf "${C_GREEN}[ ok ]${C_RESET} ffi-freshness: %d passed, 0 failed\n" "$PASS_COUNT"
