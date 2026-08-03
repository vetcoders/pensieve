#!/usr/bin/env bash
# LC_RPATH hygiene for shipped Mach-O binaries.
#
# SwiftPM links the executable with an ABSOLUTE runtime search path: Package.swift
# passes `-Xlinker -rpath -Xlinker <packageRoot>/Vendor/qube-ffi/<profile>` so a
# plain `swift build` can find the vendored libqube_ffi.dylib. The toolchain adds
# absolute rpaths of its own (the Xcode toolchain's Swift libs, /usr/lib/swift).
# All of them survive into dist/Pensieve.app and ship to users.
#
# Two problems, one of them a real load-path bug:
#
#   1. dyld searches LC_RPATH entries IN ORDER. The builder's Vendor path is
#      linked in before the release script appends @executable_path/../Frameworks,
#      so on any machine where that path happens to exist — the builder's own, or
#      any checkout at the same location — @rpath/libqube_ffi.dylib resolves to
#      the un-embedded, ad-hoc signed dylib instead of the signed copy inside the
#      bundle. The app then runs a library the bundle's signature does not cover.
#   2. Every absolute rpath is a plain-text copy of the builder's filesystem
#      layout (home directory, checkout path, toolchain version) in a public
#      artifact.
#
# Nothing in the bundle needs an absolute rpath. Only one load command resolves
# through @rpath (@rpath/libqube_ffi.dylib → Contents/Frameworks); the Swift
# runtime and every system framework are linked by absolute install name, which
# dyld resolves without consulting LC_RPATH at all. So the correct shipped state
# is: loader-relative rpaths only.
#
# This file is meant to be SOURCED. It defines functions only: no `set` calls, no
# global state, no `exit`/`die`. Failures return non-zero and explain themselves
# on stderr, so the caller decides what fatal means.
#
# Usage:
#   source "$SCRIPT_DIR/lib/rpath-hygiene.sh"
#   rpath_strip_absolute "$APP/Contents/MacOS/Pensieve" || …   # BEFORE codesign
#   rpath_assert_clean   "$APP/Contents/MacOS/Pensieve" || …

# rpath_entries <binary>
#
# Print every LC_RPATH path of <binary>, one per line, in load-command order.
# Paths containing spaces survive intact. A binary with no rpaths prints nothing
# and succeeds — that is a legitimate state, not an error.
#
#   0 — entries printed (possibly none)
#   1 — missing file or not a readable Mach-O binary
#   2 — called wrong
rpath_entries() {
    local binary="${1:-}"
    local load_commands

    if [[ -z "$binary" ]]; then
        printf 'rpath-hygiene: usage: rpath_entries <binary>\n' >&2
        return 2
    fi
    if [[ ! -f "$binary" ]]; then
        printf 'rpath-hygiene: no file at %s\n' "$binary" >&2
        return 1
    fi
    # `otool -l` exits 0 and prints "<file>: is not an object file" for anything
    # that is not Mach-O, so its exit status alone cannot be trusted: without the
    # structural check below, a text file would read as "no rpaths found" and
    # sail through the gate. Every real Mach-O has at least one load command.
    load_commands="$(otool -l "$binary" 2>/dev/null)" || load_commands=""
    if ! printf '%s\n' "$load_commands" | grep -q '^Load command '; then
        printf 'rpath-hygiene: %s is not a readable Mach-O binary\n' "$binary" >&2
        return 1
    fi

    # otool prints each rpath as a three-line block:
    #     cmd LC_RPATH
    #     cmdsize 48
    #     path @executable_path/../Frameworks (offset 12)
    # A universal binary repeats the blocks per architecture, so duplicates in
    # this stream are expected; callers that mutate dedupe before acting.
    printf '%s\n' "$load_commands" | awk '
        $1 == "cmd" && $2 == "LC_RPATH" { in_rpath = 1; next }
        in_rpath && $1 == "path" {
            entry = $0
            sub(/^[[:space:]]*path[[:space:]]/, "", entry)
            sub(/[[:space:]]\(offset[[:space:]][0-9]+\)[[:space:]]*$/, "", entry)
            print entry
            in_rpath = 0
        }
    '
}

# rpath_absolute_entries <binary>
#
# Print only the LC_RPATH entries that are NOT loader-relative, i.e. everything
# that does not start with `@` (@executable_path, @loader_path, @rpath). Those
# are the entries that must never reach a shipped artifact.
rpath_absolute_entries() {
    local entries entry

    entries="$(rpath_entries "$@")" || return $?

    while IFS= read -r entry; do
        case "$entry" in
            '' | '@'*) ;;
            *) printf '%s\n' "$entry" ;;
        esac
    done <<RPATH_ENTRIES
$entries
RPATH_ENTRIES
}

# rpath_assert_clean <binary>
#
# The gate. Non-zero (and a diagnostic naming every offender on stderr) when the
# binary still carries an absolute LC_RPATH.
#
#   0 — loader-relative rpaths only
#   1 — at least one absolute rpath, or the binary is unreadable
#   2 — called wrong
rpath_assert_clean() {
    local binary="${1:-}"
    local absolute entry

    if [[ -z "$binary" ]]; then
        printf 'rpath-hygiene: usage: rpath_assert_clean <binary>\n' >&2
        return 2
    fi

    absolute="$(rpath_absolute_entries "$binary")" || return 1
    [[ -n "$absolute" ]] || return 0

    printf 'rpath-hygiene: %s carries absolute LC_RPATH entries:\n' "$binary" >&2
    while IFS= read -r entry; do
        [[ -n "$entry" ]] || continue
        printf '    %s\n' "$entry" >&2
    done <<RPATH_ABSOLUTE
$absolute
RPATH_ABSOLUTE
    printf 'rpath-hygiene: dyld searches these BEFORE @executable_path/../Frameworks, so the\n' >&2
    printf 'rpath-hygiene: bundle can load a dylib from outside itself, and the paths leak the\n' >&2
    printf "rpath-hygiene: builder's filesystem layout into a public artifact.\n" >&2
    return 1
}

# rpath_dependencies <binary>
#
# Print the @rpath-prefixed install names <binary> links against, one per line.
# Intended for EXECUTABLES: `otool -L` lists a dylib's own LC_ID_DYLIB first, so
# on a dylib the output would include its own id as if it were a dependency.
rpath_dependencies() {
    local binary="${1:-}"
    local linked

    if [[ -z "$binary" ]]; then
        printf 'rpath-hygiene: usage: rpath_dependencies <binary>\n' >&2
        return 2
    fi
    rpath_entries "$binary" >/dev/null || return 1

    linked="$(otool -L "$binary" 2>/dev/null)" || linked=""
    printf '%s\n' "$linked" | awk '
        NR > 1 && /^[[:space:]]+@rpath\// {
            entry = $0
            sub(/^[[:space:]]+/, "", entry)
            sub(/[[:space:]]\(compatibility version.*$/, "", entry)
            print entry
        }
    '
}

# rpath_assert_resolvable <binary> <search_dir>
#
# The other half of the gate. Stripping absolute rpaths is only safe while every
# @rpath dependency can still be found through a loader-relative one — so assert
# that each @rpath/X the binary links against exists at <search_dir>/X. Turns
# "the Swift runtime is linked by absolute install name, so /usr/lib/swift was
# dead weight" from a claim someone verified once into an invariant every build
# re-checks.
#
#   0 — every @rpath dependency resolves inside <search_dir> (or there are none)
#   1 — a dependency is unresolvable, or the binary is unreadable
#   2 — called wrong
rpath_assert_resolvable() {
    local binary="${1:-}"
    local search_dir="${2:-}"
    local dependencies dependency relative rc=0

    if [[ -z "$binary" || -z "$search_dir" ]]; then
        printf 'rpath-hygiene: usage: rpath_assert_resolvable <binary> <search_dir>\n' >&2
        return 2
    fi

    dependencies="$(rpath_dependencies "$binary")" || return 1
    [[ -n "$dependencies" ]] || return 0

    while IFS= read -r dependency; do
        [[ -n "$dependency" ]] || continue
        relative="${dependency#@rpath/}"
        if [[ ! -e "$search_dir/$relative" ]]; then
            printf 'rpath-hygiene: %s links %s, but %s does not exist\n' \
                "$binary" "$dependency" "$search_dir/$relative" >&2
            rc=1
        fi
    done <<RPATH_DEPENDENCIES
$dependencies
RPATH_DEPENDENCIES

    if (( rc != 0 )); then
        printf 'rpath-hygiene: with no absolute LC_RPATH left, an @rpath dependency that is not in\n' >&2
        printf 'rpath-hygiene: the bundle cannot be found by dyld — the app would abort at launch.\n' >&2
    fi
    return $rc
}

# rpath_strip_absolute <binary>
#
# Delete every absolute LC_RPATH, leaving the loader-relative ones untouched and
# in order. Idempotent; a binary that is already clean is a no-op success.
#
# MUST run before codesign: install_name_tool invalidates the signature.
#
#   0 — binary now carries loader-relative rpaths only
#   1 — unreadable binary, or install_name_tool refused a deletion
#   2 — called wrong
rpath_strip_absolute() {
    local binary="${1:-}"
    local absolute entry
    local pass=0

    if [[ -z "$binary" ]]; then
        printf 'rpath-hygiene: usage: rpath_strip_absolute <binary>\n' >&2
        return 2
    fi
    # Explicit readability gate: the pipelines below can otherwise mask an
    # unreadable binary as "no absolute rpaths found" when the caller has not
    # set `pipefail`.
    rpath_entries "$binary" >/dev/null || return 1

    # `install_name_tool -delete_rpath` removes ONE matching load command per
    # call, so a path present more than once (universal binary, or a genuinely
    # duplicated entry) needs another pass. The bound turns a hypothetical
    # non-converging case into a loud failure instead of a hang.
    while :; do
        absolute="$(rpath_absolute_entries "$binary" | awk '!seen[$0]++')"
        [[ -n "$absolute" ]] || break

        pass=$((pass + 1))
        if (( pass > 32 )); then
            printf 'rpath-hygiene: %s still has absolute LC_RPATH entries after %d passes — giving up\n' \
                "$binary" "$((pass - 1))" >&2
            return 1
        fi

        while IFS= read -r entry; do
            [[ -n "$entry" ]] || continue
            if ! install_name_tool -delete_rpath "$entry" "$binary" 2>/dev/null; then
                printf 'rpath-hygiene: install_name_tool could not delete LC_RPATH %s from %s\n' \
                    "$entry" "$binary" >&2
                return 1
            fi
        done <<RPATH_STRIP
$absolute
RPATH_STRIP
    done

    return 0
}
