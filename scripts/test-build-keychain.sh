#!/usr/bin/env bash
# Unit tests for the build-keychain preflight in scripts/build-release.sh — the
# guard that unlocks the dedicated Developer ID keychain inside the very session
# that runs codesign, so a release driven over SSH stops dying on
# `errSecInternalComponent`.
#
# The preflight lives in build-release.sh rather than in scripts/lib/, because a
# new release helper has to be sealed into every provenance list at once and
# this code contributes nothing to the artifact's bytes. So these tests extract
# the fenced block verbatim and source that. The fence markers are asserted
# below: renaming or deleting them fails this suite instead of silently
# skipping it.
#
# NOTHING here touches a real keychain. `security` and `launchctl` are replaced
# by PATH shims, and that is not merely convenient — `security
# show-keychain-info` against a LOCKED keychain raises a SecurityAgent panel on
# the operator's screen and blocks there. Keeping that call out of every
# session that cannot answer it is precisely what this suite verifies, so it
# must not reproduce the hang while testing for it.
#
# Usage: ./scripts/test-build-keychain.sh

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "$0")" && pwd -P)"
RELEASE_SCRIPT="$SCRIPT_DIR/build-release.sh"
FIXTURE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/pensieve-build-keychain.XXXXXX")"
EXTRACTED="$FIXTURE_ROOT/preflight.sh"
DRIVER="$FIXTURE_ROOT/driver.sh"
SHIM_DIR="$FIXTURE_ROOT/bin"
CALL_LOG="$FIXTURE_ROOT/calls.log"
ALL_CALLS="$FIXTURE_ROOT/all-calls.log"
KEYCHAIN="$FIXTURE_ROOT/pensieve-build.keychain-db"
PASSWORD_FILE="$FIXTURE_ROOT/.build-keychain-pw"
TEST_PASSWORD='s3cr3t-pw'

C_GREEN='\033[32m'
C_RED='\033[31m'
C_RESET='\033[0m'
PASS_COUNT=0
FAIL_COUNT=0

RUN_OUTPUT=""
RUN_CALLS=""
RUN_STATUS=0

cleanup() {
    local original_status="$?"
    trap - EXIT INT TERM
    if [[ -n "${FIXTURE_ROOT:-}" && -d "$FIXTURE_ROOT" ]]; then
        rm -rf "$FIXTURE_ROOT" >/dev/null 2>&1 || true
    fi
    exit "$original_status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

pass() {
    printf "${C_GREEN}[PASS]${C_RESET} %s\n" "$1"
    PASS_COUNT=$((PASS_COUNT + 1))
}

fail() {
    printf "${C_RED}[FAIL]${C_RESET} %s\n       %s\n" "$1" "$2"
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

assert_contains() {
    local label="$1" needle="$2" haystack="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        pass "$label"
    else
        fail "$label" "expected [$needle] in: ${haystack//$'\n'/ | }"
    fi
}

assert_absent() {
    local label="$1" needle="$2" haystack="$3"
    if [[ "$haystack" != *"$needle"* ]]; then
        pass "$label"
    else
        fail "$label" "did NOT expect [$needle] in: ${haystack//$'\n'/ | }"
    fi
}

assert_status() {
    local label="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        pass "$label"
    else
        fail "$label" "expected exit $expected, got $actual"
    fi
}

# ─── Extract the fenced preflight block ───────────────────────────────────
[[ -f "$RELEASE_SCRIPT" ]] || {
    printf "${C_RED}[fail]${C_RESET} build-release.sh not found at %s\n" "$RELEASE_SCRIPT"
    exit 1
}

/usr/bin/awk '
    /^# >>> build-keychain preflight/ { inside = 1; next }
    /^# <<< build-keychain preflight/ { inside = 0; next }
    inside { print }
' "$RELEASE_SCRIPT" >"$EXTRACTED"

if [[ ! -s "$EXTRACTED" ]]; then
    printf "${C_RED}[fail]${C_RESET} %s\n" \
        "build-release.sh has no '# >>> build-keychain preflight' … '# <<< build-keychain preflight' fence — the block these tests source was renamed or removed."
    exit 1
fi

for required_function in \
    session_can_prompt \
    build_keychain_is_locked \
    unlock_build_keychain \
    preflight_build_keychain
do
    if ! /usr/bin/grep -q "^${required_function}()" "$EXTRACTED"; then
        printf "${C_RED}[fail]${C_RESET} the fenced block no longer defines %s()\n" \
            "$required_function"
        exit 1
    fi
done
pass "fenced preflight block extracts with all four functions"

# ─── PATH shims ───────────────────────────────────────────────────────────
# Every invocation is recorded, so a test can assert what was NOT run as well
# as what was. The anti-prompt invariants below rest on the absence of a call
# exactly as much as on the presence of one.
mkdir -p "$SHIM_DIR"

cat >"$SHIM_DIR/security" <<'SHIM'
#!/bin/bash
printf 'security %s\n' "$*" >>"$PENSIEVE_TEST_CALL_LOG"
case "${1:-}" in
    unlock-keychain)    exit "${PENSIEVE_TEST_UNLOCK_RESULT:-0}" ;;
    show-keychain-info) exit "${PENSIEVE_TEST_SHOWINFO_RESULT:-0}" ;;
    *) printf 'security UNEXPECTED-SUBCOMMAND %s\n' "$*" >>"$PENSIEVE_TEST_CALL_LOG"; exit 3 ;;
esac
SHIM

cat >"$SHIM_DIR/launchctl" <<'SHIM'
#!/bin/bash
printf 'launchctl %s\n' "$*" >>"$PENSIEVE_TEST_CALL_LOG"
if [[ "${1:-}" == "managername" ]]; then
    printf '%s\n' "${PENSIEVE_TEST_MANAGERNAME:-Aqua}"
    exit 0
fi
exit 3
SHIM

chmod +x "$SHIM_DIR/security" "$SHIM_DIR/launchctl"

# ─── Driver ───────────────────────────────────────────────────────────────
# Sources the extracted block with the logging helpers stubbed, so each branch's
# verdict lands as one parseable line. `die` leaves through exit 9, which is how
# a test tells "refused the build" apart from "let it through".
cat >"$DRIVER" <<'DRIVER_BODY'
set -u
# shellcheck disable=SC1090
source "$1"
ok()   { printf 'OK|%s\n' "$*"; }
warn() { printf 'WARN|%s\n' "$*"; }
log()  { printf 'LOG|%s\n' "$*"; }
die()  { printf 'DIE|%s\n' "$*"; exit 9; }
preflight_build_keychain
DRIVER_BODY

# run_preflight — fills RUN_OUTPUT / RUN_CALLS / RUN_STATUS.
# Both paths are pushed into the fixture directory by environment override, so
# no test can reach a real keychain even if a shim were somehow bypassed.
run_preflight() {
    : >"$CALL_LOG"
    RUN_STATUS=0
    RUN_OUTPUT="$(
        PATH="$SHIM_DIR:$PATH" \
        HOME="$FIXTURE_ROOT/home" \
        KEYS_DIR="$FIXTURE_ROOT/keys" \
        PENSIEVE_BUILD_KEYCHAIN="$KEYCHAIN" \
        PENSIEVE_BUILD_KEYCHAIN_PASSWORD_FILE="$PASSWORD_FILE" \
        PENSIEVE_TEST_CALL_LOG="$CALL_LOG" \
        PENSIEVE_TEST_UNLOCK_RESULT="${UNLOCK_RESULT:-0}" \
        PENSIEVE_TEST_SHOWINFO_RESULT="${SHOWINFO_RESULT:-0}" \
        PENSIEVE_TEST_MANAGERNAME="${MANAGERNAME:-Aqua}" \
        LANE_SIGNS_FROM_BUILD_KEYCHAIN="${LANE_KEYCHAIN:-1}" \
        SSH_CONNECTION="${FAKE_SSH_CONNECTION:-}" \
        SSH_TTY="" \
            /bin/bash "$DRIVER" "$EXTRACTED" 2>&1
    )" || RUN_STATUS=$?
    RUN_CALLS="$(cat "$CALL_LOG")"
    # Kept across cases so the non-interactive-usage invariant below can judge
    # every call this suite ever made, not just the last one.
    cat "$CALL_LOG" >>"$ALL_CALLS"
}

give_keychain()   { : >"$KEYCHAIN"; }
drop_keychain()   { /bin/rm -f "$KEYCHAIN"; }
give_password()   { printf '%s\n' "$TEST_PASSWORD" >"$PASSWORD_FILE"; chmod 600 "$PASSWORD_FILE"; }
drop_password()   { /bin/rm -f "$PASSWORD_FILE"; }

# Defaults for the knobs run_preflight reads; each case overrides what it needs.
UNLOCK_RESULT=0
SHOWINFO_RESULT=0
MANAGERNAME=Aqua
FAKE_SSH_CONNECTION=""
LANE_KEYCHAIN=1

# ─── 1. No dedicated build keychain on this machine ───────────────────────
# A machine that signs out of the default search list must be left alone
# entirely: no unlock, no probe, no failure.
drop_keychain
give_password
UNLOCK_RESULT=0 SHOWINFO_RESULT=0 MANAGERNAME=Aqua FAKE_SSH_CONNECTION=""
run_preflight
assert_status "no build keychain: preflight succeeds" 0 "$RUN_STATUS"
assert_absent "no build keychain: security is never invoked" "security" "$RUN_CALLS"

# ─── 2. Password file present, unlock succeeds ────────────────────────────
# The headline fix: the script unlocks itself, non-interactively, in its own
# session.
give_keychain
give_password
UNLOCK_RESULT=0
run_preflight
assert_status "unlock lane: preflight succeeds" 0 "$RUN_STATUS"
assert_contains "unlock lane: reports the keychain unlocked" \
    "OK|Build keychain unlocked" "$RUN_OUTPUT"
assert_contains "unlock lane: passes -p and the keychain path to security" \
    "security unlock-keychain -p $TEST_PASSWORD $KEYCHAIN" "$RUN_CALLS"
assert_absent "unlock lane: never probes with show-keychain-info" \
    "show-keychain-info" "$RUN_CALLS"

# ─── 3. Password file present but wrong ───────────────────────────────────
# A stored password that does not open the keychain has to cost a preflight
# failure, not an errSecInternalComponent eight minutes into the build.
give_keychain
give_password
UNLOCK_RESULT=1
run_preflight
UNLOCK_RESULT=0
assert_status "wrong password: preflight refuses the build" 9 "$RUN_STATUS"
assert_contains "wrong password: names the password file" \
    "DIE|The password in $PASSWORD_FILE does not unlock" "$RUN_OUTPUT"

# ─── 4. No password file, GUI session ─────────────────────────────────────
# THE anti-prompt invariant. In an Aqua session `show-keychain-info` against a
# locked keychain raises a modal panel, so the locked-state probe must not run
# here at all — the build proceeds with a warning and lets codesign raise the
# panel it would have raised anyway.
give_keychain
drop_password
MANAGERNAME=Aqua
FAKE_SSH_CONNECTION=""
run_preflight
assert_status "GUI, no password: preflight lets the build proceed" 0 "$RUN_STATUS"
assert_contains "GUI, no password: warns about the missing password file" \
    "WARN|No build-keychain password at $PASSWORD_FILE" "$RUN_OUTPUT"
assert_absent "GUI, no password: NEVER calls show-keychain-info (it would raise a panel)" \
    "show-keychain-info" "$RUN_CALLS"

# ─── 5. No password file, headless session, keychain locked ───────────────
# The measured SSH failure. No password to unlock with, no session that could
# be prompted: fail now, with the remedy printed.
give_keychain
drop_password
MANAGERNAME=Background
FAKE_SSH_CONNECTION="10.0.0.2 51000 10.0.0.3 22"
SHOWINFO_RESULT=1
run_preflight
assert_status "SSH, locked: preflight refuses the build" 9 "$RUN_STATUS"
assert_contains "SSH, locked: names the locked keychain" \
    "DIE|Build keychain is LOCKED and this session cannot unlock it: $KEYCHAIN" "$RUN_OUTPUT"
assert_contains "SSH, locked: prints the password-file remedy" \
    "$PASSWORD_FILE" "$RUN_OUTPUT"
assert_contains "SSH, locked: probes the lock state deterministically" \
    "security show-keychain-info $KEYCHAIN" "$RUN_CALLS"

# ─── 6. No password file, headless session, keychain already unlocked ─────
# The operator unlocked it by hand in THIS session. That still works, so the
# preflight must not turn a working build into a failure.
give_keychain
drop_password
MANAGERNAME=Background
FAKE_SSH_CONNECTION="10.0.0.2 51000 10.0.0.3 22"
SHOWINFO_RESULT=0
run_preflight
assert_status "SSH, already unlocked: preflight succeeds" 0 "$RUN_STATUS"
assert_contains "SSH, already unlocked: says so instead of failing" \
    "OK|Build keychain already unlocked" "$RUN_OUTPUT"

# ─── 7. Empty password file is treated as no password ─────────────────────
# An empty file must not be handed to `security` as a password: that turns a
# clear diagnosis into a spurious "wrong password" failure.
give_keychain
: >"$PASSWORD_FILE"
MANAGERNAME=Background
FAKE_SSH_CONNECTION="10.0.0.2 51000 10.0.0.3 22"
SHOWINFO_RESULT=1
run_preflight
assert_status "empty password file: preflight refuses the build" 9 "$RUN_STATUS"
assert_contains "empty password file: diagnosed as LOCKED, not as a bad password" \
    "DIE|Build keychain is LOCKED" "$RUN_OUTPUT"
assert_absent "empty password file: never calls unlock-keychain" \
    "unlock-keychain" "$RUN_CALLS"

# ─── 8. A lane that does not sign out of this keychain is never gated on it ─
# The App Store lane signs with the PENSIEVE_MAS_* identities, which need not
# live in the dedicated build keychain at all. Gating it on that keychain would
# let a stale password file — or a keychain locked in a headless session —
# refuse a build that never opens it. Both fatal branches must stay silent, and
# the keychain must not be touched at all.
give_keychain
give_password
LANE_KEYCHAIN=0
UNLOCK_RESULT=1
MANAGERNAME=Aqua
FAKE_SSH_CONNECTION=""
run_preflight
UNLOCK_RESULT=0
assert_status "foreign lane, wrong password: preflight does not refuse the build" 0 "$RUN_STATUS"
assert_absent "foreign lane, wrong password: never touches the build keychain" \
    "security" "$RUN_CALLS"

give_keychain
drop_password
MANAGERNAME=Background
FAKE_SSH_CONNECTION="10.0.0.2 51000 10.0.0.3 22"
SHOWINFO_RESULT=1
run_preflight
assert_status "foreign lane, locked keychain over SSH: preflight succeeds" 0 "$RUN_STATUS"
assert_absent "foreign lane, locked keychain over SSH: never probes the lock state" \
    "security" "$RUN_CALLS"
LANE_KEYCHAIN=1

# Restore defaults before the structural checks.
SHOWINFO_RESULT=0
MANAGERNAME=Aqua
FAKE_SSH_CONNECTION=""

# ─── 9. The lane flag is decided before the preflight consumes it ─────────
# Same failure family as PUBLISHES_DMG: a lane flag read before it is assigned
# silently degrades to the wrong lane. Pinned by line order, and by the default
# in the preflight itself, which must keep the strict gate when the flag is
# missing rather than open it.
LANE_FLAG_LINE="$(/usr/bin/grep -n '^ *LANE_SIGNS_FROM_BUILD_KEYCHAIN=' "$RELEASE_SCRIPT" | /usr/bin/tail -n 1 | /usr/bin/cut -d: -f1)"
PREFLIGHT_LINE="$(/usr/bin/grep -n '^preflight_build_keychain$' "$RELEASE_SCRIPT" | /usr/bin/head -n 1 | /usr/bin/cut -d: -f1)"
if [[ -n "$LANE_FLAG_LINE" && -n "$PREFLIGHT_LINE" && "$LANE_FLAG_LINE" -lt "$PREFLIGHT_LINE" ]]; then
    pass "the lane flag is assigned before preflight_build_keychain runs"
else
    fail "the lane flag is assigned before preflight_build_keychain runs" \
        "assignment at line [${LANE_FLAG_LINE:-none}], preflight call at line [${PREFLIGHT_LINE:-none}]"
fi

assert_contains "the missing lane flag defaults to the strict gate" \
    'LANE_SIGNS_FROM_BUILD_KEYCHAIN:-1' "$(cat "$EXTRACTED")"

# The App Store lane keeps the opportunistic unlock at each signing site: a
# Developer ID identity is a documented MAS dry-run stand-in and it does live in
# the build keychain, so skipping the unlock there would resurrect
# errSecInternalComponent on that path.
assert_absent "sign_code() unlocks in every lane, gate or no gate" \
    "LANE_SIGNS_FROM_BUILD_KEYCHAIN" \
    "$(/usr/bin/awk '/^sign_code\(\) \{/ { inside = 1 } inside { print } inside && /^\}/ { exit }' "$RELEASE_SCRIPT")"

# ─── 10. `security` is only ever used non-interactively ───────────────────
# Across every case above, the only two subcommands the shim saw must be the
# unlock (always with -p, so SecurityAgent is never reached) and the fenced
# lock probe. Anything else — dump-keychain, a bare unlock-keychain, find-key —
# can escalate to a panel.
STRUCTURAL_CALLS="$(/usr/bin/grep '^security ' "$ALL_CALLS" || true)"
if /usr/bin/grep -q 'UNEXPECTED-SUBCOMMAND' "$ALL_CALLS" 2>/dev/null; then
    fail "security is used non-interactively" "an unexpected subcommand was invoked: $STRUCTURAL_CALLS"
else
    pass "security is used non-interactively (no unexpected subcommands)"
fi

if /usr/bin/grep -q '^security unlock-keychain' "$ALL_CALLS" 2>/dev/null \
    && ! /usr/bin/grep -q '^security unlock-keychain -p ' "$ALL_CALLS" 2>/dev/null; then
    fail "unlock always carries -p" "a bare unlock-keychain would raise a SecurityAgent prompt"
else
    pass "unlock always carries -p (no interactive unlock path)"
fi

# ─── 11. Every signing site re-asserts the unlock ─────────────────────────
# A keychain's inactivity auto-lock can close it again while the release sits
# in `swift build` or in notarization, so the unlock has to be re-asserted at
# each signing site rather than only in preflight. Checked structurally,
# because these call sites live outside the sourceable fence.
SIGN_CODE_BODY="$(/usr/bin/awk '/^sign_code\(\) \{/ { inside = 1 } inside { print } inside && /^\}/ { exit }' "$RELEASE_SCRIPT")"
assert_contains "sign_code() re-asserts the unlock before codesign" \
    "unlock_build_keychain" "$SIGN_CODE_BODY"

# Anchored on the only top-level (unindented) codesign invocation in the
# script — the DMG signature. sign_code()'s own calls are indented.
DMG_SIGN_CONTEXT="$(/usr/bin/grep -B 5 '^codesign --force --sign' "$RELEASE_SCRIPT" || true)"
assert_contains "DMG signing re-asserts the unlock after notarization" \
    "unlock_build_keychain" "$DMG_SIGN_CONTEXT"

PREFLIGHT_CALL="$(/usr/bin/grep -c '^preflight_build_keychain$' "$RELEASE_SCRIPT" || true)"
if [[ "$PREFLIGHT_CALL" -ge 1 ]]; then
    pass "build-release.sh actually runs the preflight"
else
    fail "build-release.sh actually runs the preflight" "no top-level preflight_build_keychain call"
fi

printf '\n%b%d passed, %d failed%b\n' "$C_GREEN" "$PASS_COUNT" "$FAIL_COUNT" "$C_RESET"
[[ "$FAIL_COUNT" -eq 0 ]]
