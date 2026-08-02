#!/usr/bin/env bash
# Bundle identity verification for reused .app bundles.
#
# A code signature proves a bundle was not modified AFTER it was signed. It
# says nothing about WHICH source produced it. Any lane that reuses an already
# built dist/Pensieve.app (notably `--dmg-only`) must therefore compare the
# identity stamped into the bundle at build time against the identity of the
# tree it is packaging for, or it will happily wrap a stale app in a DMG named
# after the current VERSION + HEAD.
#
# The build lane stamps CFBundleShortVersionString and PensieveBuildCommit into
# Contents/Info.plist, so both fields exist on every bundle this repo produces.
# A bundle missing either one predates that stamping (or was not produced here)
# and is therefore unverifiable — which counts as a mismatch, not a pass.
#
# This file is meant to be SOURCED. It defines functions only: no `set` calls,
# no global state, no `exit`/`die`. Failures return non-zero and explain
# themselves on stderr, so the caller decides what fatal means.
#
# Usage:
#   source "$SCRIPT_DIR/lib/bundle-identity.sh"
#   bundle_identity_matches "$APP_BUNDLE" "$APP_VERSION" "$COMMIT_FULL" || …

# Print the string value of an Info.plist key on stdout.
#
# PlistBuddy exits 1 and writes `Print: Entry, ":Key", Does Not Exist` to stderr
# for a missing key, but exits 0 with empty output for a key that exists with an
# empty value — neither is usable as an identity, so both return non-zero here.
bundle_identity_plist_value() {
    local plist="${1:-}"
    local key="${2:-}"
    local value

    value="$(/usr/libexec/PlistBuddy -c "Print :$key" "$plist" 2>/dev/null)" || return 1
    [[ -n "$value" ]] || return 1
    printf '%s\n' "$value"
}

# bundle_identity_matches <app_bundle> <expected_version> <expected_commit_full>
#
#   0 — the bundle's stamped identity equals the expected one
#   1 — bundle unreadable, identity keys missing/empty, or a field mismatches
#   2 — called wrong (missing arguments)
#
# Every rejection names the offending field and both values on stderr. All
# fields are checked before returning, so a doubly stale bundle reports both.
bundle_identity_matches() {
    local app_bundle="${1:-}"
    local expected_version="${2:-}"
    local expected_commit="${3:-}"
    local plist actual_version actual_commit
    local rc=0

    if [[ -z "$app_bundle" || -z "$expected_version" || -z "$expected_commit" ]]; then
        printf 'bundle-identity: usage: bundle_identity_matches <app_bundle> <expected_version> <expected_commit>\n' >&2
        return 2
    fi

    if [[ ! -d "$app_bundle" ]]; then
        printf 'bundle-identity: no bundle at %s\n' "$app_bundle" >&2
        return 1
    fi

    plist="$app_bundle/Contents/Info.plist"
    if [[ ! -f "$plist" ]]; then
        printf 'bundle-identity: %s has no Contents/Info.plist — nothing to verify\n' "$app_bundle" >&2
        return 1
    fi

    if ! actual_version="$(bundle_identity_plist_value "$plist" CFBundleShortVersionString)"; then
        printf 'bundle-identity: %s: CFBundleShortVersionString is missing or empty — the bundle carries no version to compare against %s\n' \
            "$plist" "$expected_version" >&2
        rc=1
    elif [[ "$actual_version" != "$expected_version" ]]; then
        printf 'bundle-identity: %s: CFBundleShortVersionString mismatch — bundle has %s, expected %s\n' \
            "$plist" "$actual_version" "$expected_version" >&2
        rc=1
    fi

    if ! actual_commit="$(bundle_identity_plist_value "$plist" PensieveBuildCommit)"; then
        printf 'bundle-identity: %s: PensieveBuildCommit is missing or empty — the bundle carries no commit to compare against %s\n' \
            "$plist" "$expected_commit" >&2
        rc=1
    elif [[ "$actual_commit" != "$expected_commit" ]]; then
        printf 'bundle-identity: %s: PensieveBuildCommit mismatch — bundle has %s, expected %s\n' \
            "$plist" "$actual_commit" "$expected_commit" >&2
        rc=1
    fi

    return $rc
}
