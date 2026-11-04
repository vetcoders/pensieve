#!/usr/bin/env bash
# Contract tests for `make release-local NOTARIZE=true`, the local lane that
# notarizes without publishing.
#
# A notarized DMG used to exist only in the publishing lane (`make release`,
# `make notarize`), which also creates a GitHub release marked latest. This
# test pins the separation: NOTARIZE selects `build-release.sh --no-publish`,
# the default stays a signed .app only, a bad value fails before the gates, and
# the internal release shelf follows the publishing condition.
#
# Self-contained: `make -n` and `--help` only, no build, no codesign, no
# network. Belongs in `make gates` (see the test-scripts target).
#
# Usage: ./scripts/test-release-local-notarize.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RELEASE_SCRIPT="$SCRIPT_DIR/build-release.sh"

C_GREEN='\033[32m'
C_RED='\033[31m'
C_RESET='\033[0m'
FAILURES=0

pass() { printf "%b  ok%b  %s\n" "$C_GREEN" "$C_RESET" "$1"; }
fail() {
    printf "%bFAIL%b  %s\n      %s\n" "$C_RED" "$C_RESET" "$1" "$2"
    FAILURES=$((FAILURES + 1))
}

# The release-local recipe line(s) that `make -n` prints for a NOTARIZE value.
# The gates run this test from inside `make release-local NOTARIZE=true`, and
# make hands its command-line variables to every child through MAKEFLAGS. Clear
# them, and any NOTARIZE in the environment, so each case sees only its own
# arguments.
dry_run() {
    env -u MAKEFLAGS -u MFLAGS -u MAKELEVEL -u NOTARIZE \
        make --no-print-directory -n -C "$REPO_ROOT" release-local "$@" 2>&1
}

DEFAULT_OUT="$(dry_run)"
if grep -q 'build-release.sh --no-notarize --no-dmg' <<<"$DEFAULT_OUT" \
    && ! grep -q 'build-release.sh --no-publish' <<<"$DEFAULT_OUT"; then
    pass "release-local without NOTARIZE stays a signed .app only"
else
    fail "release-local without NOTARIZE stays a signed .app only" \
        "make -n printed no '--no-notarize --no-dmg' call, or a '--no-publish' one"
fi

FALSE_OUT="$(dry_run NOTARIZE=false)"
if grep -q 'build-release.sh --no-notarize --no-dmg' <<<"$FALSE_OUT"; then
    pass "NOTARIZE=false is the default lane"
else
    fail "NOTARIZE=false is the default lane" \
        "make -n printed no '--no-notarize --no-dmg' call"
fi

TRUE_OUT="$(dry_run NOTARIZE=true)"
if grep -q 'build-release.sh --no-publish$' <<<"$TRUE_OUT" \
    && ! grep -q 'build-release.sh --no-notarize' <<<"$TRUE_OUT"; then
    pass "NOTARIZE=true runs the notarized lane with --no-publish"
else
    fail "NOTARIZE=true runs the notarized lane with --no-publish" \
        "make -n printed no bare '--no-publish' call, or still a '--no-notarize' one"
fi

if BAD_OUT="$(dry_run NOTARIZE=yes)"; then
    fail "an unknown NOTARIZE value is refused" "make -n release-local NOTARIZE=yes exited 0"
elif grep -q 'NOTARIZE must be true or false, got: yes' <<<"$BAD_OUT" \
    && ! grep -q 'swift test' <<<"$BAD_OUT"; then
    pass "an unknown NOTARIZE value is refused before the gates"
else
    fail "an unknown NOTARIZE value is refused before the gates" \
        "missing the NOTARIZE error, or the gates' recipes were reached: $BAD_OUT"
fi

if HELP_OUT="$("$RELEASE_SCRIPT" --no-publish --help 2>&1)" \
    && grep -q -- '--no-publish' <<<"$HELP_OUT"; then
    pass "build-release.sh accepts --no-publish and documents it"
else
    fail "build-release.sh accepts --no-publish and documents it" \
        "'--no-publish --help' failed or the help text does not name the flag"
fi

if "$RELEASE_SCRIPT" --no-publsh >/dev/null 2>&1; then
    fail "a misspelled flag is still refused" "'--no-publsh' was accepted"
else
    pass "a misspelled flag is still refused"
fi

# The internal shelf copy must sit behind the same guard as the page stamp and
# the GitHub publish, so a --no-publish run cannot land on the team shelf.
UNGUARDED_SHELF="$(awk '
    /^if \(\( PUBLISHES_DMG \)\); then$/ { guard = 1; next }
    /^fi$/ { guard = 0; next }
    /INTERNAL_DIR=/ { if (!guard) printf "%d: %s\n", NR, $0 }
' "$RELEASE_SCRIPT")"
SHELF_LINES="$(grep -c 'INTERNAL_DIR=' "$RELEASE_SCRIPT" || true)"
if [[ "$SHELF_LINES" != "0" && -z "$UNGUARDED_SHELF" ]]; then
    pass "the internal release shelf sits behind the publishing guard"
else
    fail "the internal release shelf sits behind the publishing guard" \
        "INTERNAL_DIR assignments: $SHELF_LINES; unguarded: ${UNGUARDED_SHELF:-none}"
fi

if (( FAILURES )); then
    printf "%b%d release-local NOTARIZE contract check(s) failed%b\n" "$C_RED" "$FAILURES" "$C_RESET"
    exit 1
fi
printf "%brelease-local NOTARIZE contract: all checks passed%b\n" "$C_GREEN" "$C_RESET"
