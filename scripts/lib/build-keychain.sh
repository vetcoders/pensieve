#!/usr/bin/env bash
# shellcheck shell=bash
# Build-keychain preflight — the guard that unlocks the dedicated Developer ID
# keychain inside the very session that runs codesign.
#
# The Developer ID identity lives in a dedicated build keychain, not in the
# login keychain. A keychain's unlocked state belongs to the security session
# that unlocked it, so a keychain the operator opened in their GUI session is
# still LOCKED for a release driven over SSH — and codesign then dies with the
# famously unhelpful `errSecInternalComponent`, minutes into the build. That is
# why the unlock has to happen inside the process tree that runs codesign:
# unlocking beforehand from another session provably does not carry over, which
# is the trap this preflight exists to close.
#
# It lives in a sourceable lib rather than inside build-release.sh because it
# has two callers, in two different security postures. build-release.sh sources
# it for the strict preflight (`preflight_build_keychain`, which may `die`), and
# scripts/test-isolated-app.sh sources it for the opportunistic, non-fatal
# `unlock_build_keychain` it needs before deciding whether it can sign at all —
# `make gates` runs long before any release lane, so without that call the
# gates could not reach the identity the release later signs with.
#
# Being a release helper, this file is a runtime input: it is sealed into the
# provenance digest and must appear in EVERY release-helper enumeration at once
# (build-release.sh's snapshot archive, build-provenance.sh's digest, existence
# and status lists, isolated-app.sh's dirty-input list). test-landing-page.sh
# asserts that structurally.
#
# The callers supply `ok`/`warn`/`die`; only preflight_build_keychain uses them.
# Sourced, never executed.

# >>> build-keychain preflight — extracted verbatim by scripts/test-build-keychain.sh >>>
# Both locations are overridable so a second build machine (or a test) can point
# them elsewhere without editing this file. KEYS_DIR carries its own default
# here — identical to the one build-release.sh assigns — so a caller running
# under `set -u` that has no reason to know about ~/.keys can still source this.
BUILD_KEYCHAIN="${PENSIEVE_BUILD_KEYCHAIN:-$HOME/Library/Keychains/pensieve-build.keychain-db}"
BUILD_KEYCHAIN_PASSWORD_FILE="${PENSIEVE_BUILD_KEYCHAIN_PASSWORD_FILE:-${KEYS_DIR:-$HOME/.keys}/.build-keychain-pw}"

# session_can_prompt — true only in an Aqua (GUI login) session, the one place
# where Security can put a SecurityAgent unlock panel on a screen. An SSH or
# launchd-driven session cannot, so there a keychain call fails closed instead
# of blocking forever on a modal nobody can see.
session_can_prompt() {
    [[ -z "${SSH_CONNECTION:-}${SSH_TTY:-}" ]] || return 1
    [[ "$(launchctl managername 2>/dev/null)" == "Aqua" ]]
}

# build_keychain_is_locked — called ONLY from the branch that has already
# established this session cannot prompt. `show-keychain-info` on a locked
# keychain is not a passive read: in an Aqua session it raises a modal unlock
# panel and blocks until somebody answers it. Fenced behind session_can_prompt
# it is a deterministic non-interactive lock probe; used anywhere else it is a
# hang waiting to happen, so do not lift it out of this branch.
build_keychain_is_locked() {
    ! security show-keychain-info "$BUILD_KEYCHAIN" >/dev/null 2>&1
}

# unlock_build_keychain — idempotent and never interactive: given -p, `security
# unlock-keychain` also succeeds on an already-unlocked keychain and never
# reaches SecurityAgent. Cheap enough to call before every signing step, which
# is the point — a keychain carries an inactivity auto-lock timeout, while a
# release spends minutes inside `swift build` and minutes more inside
# notarization between two signatures. Re-asserting the unlock at each signing
# site beats raising the operator's auto-lock timeout, because it leaves no
# persistent change to their security posture behind.
#
# The password does travel through argv, where `ps` can see it for the lifetime
# of one exec. Accepted deliberately: `security` has no stdin or password-file
# mode, so the only alternative is the interactive prompt this whole preflight
# exists to avoid. The window is milliseconds on a single-operator build
# machine, and the source is already a 0600 secret in $HOME.

# build_keychain_password_file_is_private — the "already a 0600 secret" above is
# a contract (AGENTS.md), and until here nothing checked it. $HOME is
# world-executable on macOS, so this file's confidentiality rests entirely on
# its own mode: a stray `chmod 644` hands the keychain password to every local
# account and, before this check, did so silently. Required: owned by the user
# running the build, with no group or other bits at all — 0600, or 0400 for a
# file deliberately kept read-only. Anything wider is refused rather than read,
# because reading it anyway would make the mode contract decorative.
#
# `stat -L` resolves a symlink on purpose: the mode that matters belongs to the
# file whose bytes we are about to hand to `security`, not to the link.
build_keychain_password_file_is_private() {
    local metadata owner mode

    metadata="$(/usr/bin/stat -L -f '%u %Lp' "$BUILD_KEYCHAIN_PASSWORD_FILE" 2>/dev/null)" || return 1
    owner="${metadata%% *}"
    mode="${metadata##* }"
    [[ -n "$owner" && -n "$mode" ]] || return 1
    [[ "$owner" == "$(/usr/bin/id -u)" ]] || return 1
    (( 8#$mode & 8#077 )) && return 1
    return 0
}

# Status: 0 unlocked (or no dedicated build keychain here), 1 no readable
# password file, 2 the stored password did not unlock the keychain, 3 the
# password file is not an owner-only secret (wrong owner, unreadable owner or
# mode, or group/other bits set).
unlock_build_keychain() {
    local password

    [[ -f "$BUILD_KEYCHAIN" ]] || return 0
    [[ -r "$BUILD_KEYCHAIN_PASSWORD_FILE" ]] || return 1
    build_keychain_password_file_is_private || return 3
    password="$(head -n1 "$BUILD_KEYCHAIN_PASSWORD_FILE")" || return 1
    [[ -n "$password" ]] || return 1
    security unlock-keychain -p "$password" "$BUILD_KEYCHAIN" >/dev/null 2>&1 || return 2
    return 0
}

# Fail here, with the keychain named and the remedy spelled out, rather than
# eight minutes later inside codesign with an errSecInternalComponent.
#
# Only the lane whose signing identity lives in this keychain may be *gated* on
# it. LANE_SIGNS_FROM_BUILD_KEYCHAIN is decided up in the arg block, long before
# this runs, and defaults to 1 here: an unset flag keeps the strict gate rather
# than silently opening it, so a future lane cannot lose the check by omission.
preflight_build_keychain() {
    local status=0

    (( ${LANE_SIGNS_FROM_BUILD_KEYCHAIN:-1} )) || return 0
    [[ -f "$BUILD_KEYCHAIN" ]] || return 0

    unlock_build_keychain || status=$?
    case "$status" in
        0)
            ok "Build keychain unlocked for this session: $BUILD_KEYCHAIN"
            ;;
        2)
            die "The password in $BUILD_KEYCHAIN_PASSWORD_FILE does not unlock $BUILD_KEYCHAIN.
       Correct the stored password, or unlock the keychain by hand from THIS
       session before re-running:
         security unlock-keychain '$BUILD_KEYCHAIN'"
            ;;
        3)
            die "Build-keychain password file is not an owner-only secret: $BUILD_KEYCHAIN_PASSWORD_FILE
       It holds the keychain password in cleartext and \$HOME is
       world-executable, so the file's own mode is the whole of its
       confidentiality. One of three things is wrong: it is not owned by the
       user running the build, its owner and mode could not be read at all, or
       it carries group or other permission bits — any of which leaves the
       password reachable by an account that is not this one. Refusing to use
       it until it is owned by this user and mode 0600, or 0400 for a file
       deliberately kept read-only:
         ls -l \"$BUILD_KEYCHAIN_PASSWORD_FILE\"
         sudo chown \"\$(/usr/bin/id -un)\" \"$BUILD_KEYCHAIN_PASSWORD_FILE\"
         chmod 600 \"$BUILD_KEYCHAIN_PASSWORD_FILE\"
       If it was group- or world-accessible, treat the stored password as
       disclosed: change it on the keychain and re-store it."
            ;;
        *)
            # No readable password file. Signing can still succeed if this
            # session already holds the keychain open, or — in a GUI session —
            # if somebody answers the panel codesign will raise anyway.
            if session_can_prompt; then
                warn "No build-keychain password at $BUILD_KEYCHAIN_PASSWORD_FILE — signing may raise an interactive unlock panel."
            elif build_keychain_is_locked; then
                die "Build keychain is LOCKED and this session cannot unlock it: $BUILD_KEYCHAIN
       Unlocking does not cross security sessions, so opening it in a GUI
       session does not help a release driven over SSH — codesign would fail
       with errSecInternalComponent minutes into the build.
       Store the keychain password so this script unlocks itself:
         printf '%s' 'PASSWORD' > \"$BUILD_KEYCHAIN_PASSWORD_FILE\"
         chmod 600 \"$BUILD_KEYCHAIN_PASSWORD_FILE\"
       Or unlock it by hand from THIS session before re-running:
         security unlock-keychain '$BUILD_KEYCHAIN'"
            else
                ok "Build keychain already unlocked in this session: $BUILD_KEYCHAIN"
            fi
            ;;
    esac
}
# <<< build-keychain preflight <<<
