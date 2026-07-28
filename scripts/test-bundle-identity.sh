#!/usr/bin/env bash
# Unit tests for scripts/lib/bundle-identity.sh — the guard that stops the
# --dmg-only lane from packaging a stale .app under a fresh version label.
#
# Self-contained: synthetic .app fixtures in a mktemp dir, no codesign, no
# swift build, no network. Runs in well under a second, so it belongs in
# `make gates` (see the test-scripts target).
#
# Usage: ./scripts/test-bundle-identity.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/bundle-identity.sh
source "$SCRIPT_DIR/lib/bundle-identity.sh"

C_GREEN='\033[32m'
C_RED='\033[31m'
C_RESET='\033[0m'

FIXTURE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/pensieve-bundle-identity.XXXXXX")"
cleanup() {
    if [[ -n "${FIXTURE_ROOT:-}" && -d "$FIXTURE_ROOT" ]]; then
        rm -rf "$FIXTURE_ROOT"
    fi
    return 0
}
trap cleanup EXIT

# Deliberately synthetic: these are two arbitrary, distinguishable identities,
# NOT any real release of this repo. Using real-looking version/SHA pairs here
# would invite a reader to think the suite encodes some branch's actual state.
VERSION_A="9.9.1"
VERSION_B="9.9.2"
COMMIT_A="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
COMMIT_B="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

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

# make_bundle <name> [key value]… → prints the bundle path
# A bare name with no key/value pairs yields a bundle whose Info.plist has
# neither identity key.
make_bundle() {
    local name="$1"
    shift
    local bundle="$FIXTURE_ROOT/$name.app"
    local plist="$bundle/Contents/Info.plist"

    mkdir -p "$bundle/Contents"
    /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string io.vetcoders.pensieve.fixture" "$plist" >/dev/null
    while (( $# >= 2 )); do
        /usr/libexec/PlistBuddy -c "Add :$1 string $2" "$plist" >/dev/null
        shift 2
    done
    printf '%s\n' "$bundle"
}

# assert_accepts <description> <bundle> <version> <commit>
assert_accepts() {
    local desc="$1"
    shift
    local output status=0
    output="$(bundle_identity_matches "$@" 2>&1)" || status=$?
    if (( status == 0 )); then
        pass "$desc"
    else
        fail "$desc" "expected acceptance, got exit $status: ${output:-<no output>}"
    fi
}

# assert_rejects <description> <expected stderr substring> <bundle> <version> <commit>
assert_rejects() {
    local desc="$1"
    local needle="$2"
    shift 2
    local output status=0
    output="$(bundle_identity_matches "$@" 2>&1)" || status=$?
    if (( status == 0 )); then
        fail "$desc" "expected rejection, but the bundle was accepted"
    elif [[ "$output" != *"$needle"* ]]; then
        fail "$desc" "rejected, but the diagnostic never mentions '$needle': ${output:-<no output>}"
    else
        pass "$desc"
    fi
}

printf "Testing bundle_identity_matches (fixtures: %s)\n\n" "$FIXTURE_ROOT"

COMPLETE="$(make_bundle complete \
    CFBundleShortVersionString "$VERSION_A" \
    PensieveBuildCommit "$COMMIT_A")"
NO_COMMIT="$(make_bundle no-commit CFBundleShortVersionString "$VERSION_A")"
NO_VERSION="$(make_bundle no-version PensieveBuildCommit "$COMMIT_A")"
NO_KEYS="$(make_bundle no-keys)"
EMPTY_COMMIT="$(make_bundle empty-commit \
    CFBundleShortVersionString "$VERSION_A" \
    PensieveBuildCommit "")"
NO_PLIST="$FIXTURE_ROOT/no-plist.app"
mkdir -p "$NO_PLIST/Contents"

assert_accepts "matching version + matching commit is accepted" \
    "$COMPLETE" "$VERSION_A" "$COMMIT_A"

assert_rejects "matching version + WRONG commit is rejected" \
    "PensieveBuildCommit mismatch" \
    "$COMPLETE" "$VERSION_A" "$COMMIT_B"

assert_rejects "WRONG version + matching commit is rejected" \
    "CFBundleShortVersionString mismatch" \
    "$COMPLETE" "$VERSION_B" "$COMMIT_A"

assert_rejects "both fields wrong is rejected on the version" \
    "CFBundleShortVersionString mismatch" \
    "$COMPLETE" "$VERSION_B" "$COMMIT_B"

assert_rejects "both fields wrong is rejected on the commit too" \
    "PensieveBuildCommit mismatch" \
    "$COMPLETE" "$VERSION_B" "$COMMIT_B"

assert_rejects "missing PensieveBuildCommit is rejected, not passed" \
    "PensieveBuildCommit is missing or empty" \
    "$NO_COMMIT" "$VERSION_A" "$COMMIT_A"

assert_rejects "missing CFBundleShortVersionString is rejected, not passed" \
    "CFBundleShortVersionString is missing or empty" \
    "$NO_VERSION" "$VERSION_A" "$COMMIT_A"

assert_rejects "a bundle with neither identity key is rejected" \
    "is missing or empty" \
    "$NO_KEYS" "$VERSION_A" "$COMMIT_A"

# PlistBuddy exits 0 for a present-but-empty key; an empty stamp is no identity.
assert_rejects "an empty PensieveBuildCommit is rejected" \
    "PensieveBuildCommit is missing or empty" \
    "$EMPTY_COMMIT" "$VERSION_A" "$COMMIT_A"

assert_rejects "a bundle path that does not exist is rejected" \
    "no bundle at" \
    "$FIXTURE_ROOT/absent.app" "$VERSION_A" "$COMMIT_A"

assert_rejects "a bundle without Contents/Info.plist is rejected" \
    "has no Contents/Info.plist" \
    "$NO_PLIST" "$VERSION_A" "$COMMIT_A"

printf '\n'
if (( FAIL_COUNT > 0 )); then
    printf "${C_RED}[fail]${C_RESET} bundle-identity: %d passed, %d failed\n" "$PASS_COUNT" "$FAIL_COUNT"
    exit 1
fi
printf "${C_GREEN}[ ok ]${C_RESET} bundle-identity: %d passed, 0 failed\n" "$PASS_COUNT"
