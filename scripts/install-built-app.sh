#!/usr/bin/env bash
# Install an existing Developer ID build without interrupting a live session.
# Sourceable so the transaction can be tested entirely inside a fixture root.

PENSIEVE_INSTALL_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

pensieve_install_error() {
    printf 'install: %s\n' "$*" >&2
}

pensieve_install_assert_idle() {
    local pids status
    if pids="$(/usr/bin/pgrep -x Pensieve)"; then
        pensieve_install_error "Pensieve is running (PID: ${pids//$'\n'/, }). Quit it yourself after saving your work, then retry. No process was stopped."
        return 1
    else
        status=$?
        [[ "$status" == 1 ]] || {
            pensieve_install_error "could not establish whether Pensieve is running"
            return 1
        }
    fi
}

pensieve_install_verify() {
    local bundle="$1"
    # Reuse only the read-only verification seam; no smoke identity is created.
    # No historical or dirty-source override is accepted for installation.
    source "$PENSIEVE_INSTALL_SCRIPT_DIR/lib/isolated-app.sh"
    isolated_app_assert_source_provenance \
        "$(cd "$PENSIEVE_INSTALL_SCRIPT_DIR/.." && pwd)" "$bundle" 0 0 >/dev/null
}

pensieve_install_verify_signature() {
    # This is the production destination, not a smoke source. The isolation
    # helper deliberately refuses /Applications/Pensieve.app. Its current-HEAD
    # provenance was established on the source and staged copy; strict signed
    # bundle validation plus the exact source comparison below carries that
    # evidence across the rename without relaxing the isolation helper.
    /usr/bin/codesign --verify --deep --strict "$1"
}

pensieve_install_copy() {
    /usr/bin/ditto "$1" "$2"
}

pensieve_install_compare() {
    /usr/bin/diff -qr "$1" "$2"
}

pensieve_install_receipt() {
    local bundle="$1" key
    printf 'installed_bundle: %s\n' "$bundle"
    for key in CFBundleIdentifier CFBundleShortVersionString CFBundleVersion PensieveBuildCommit; do
        printf '%s: ' "$key"
        /usr/libexec/PlistBuddy -c "Print :$key" "$bundle/Contents/Info.plist" || return 1
    done
    /usr/bin/shasum -a 256 \
        "$bundle/Contents/MacOS/Pensieve" \
        "$bundle/Contents/Frameworks/libqube_ffi.dylib" || return 1
}

pensieve_install_built_app() (
    local source_bundle="$1" destination="$2" parent capsule had_previous=false
    parent="$(dirname "$destination")"
    [[ "$destination" == "$parent/Pensieve.app" && -d "$parent" && ! -L "$parent" \
        && ! -L "$destination" && ! -L "$source_bundle" && -d "$source_bundle" \
        && "$source_bundle" != "$destination" ]] || {
        pensieve_install_error "source/destination must be distinct physical app directories"
        return 1
    }
    [[ ! -e "$destination" || -d "$destination" ]] || {
        pensieve_install_error "destination is not an application directory"
        return 1
    }
    local lock_directory="$parent/.pensieve-install-lock"
    /bin/mkdir "$lock_directory" 2>/dev/null || {
        pensieve_install_error "another install owns $lock_directory; no bundle was changed"
        return 1
    }
    trap '/bin/rmdir "$lock_directory"' EXIT
    pensieve_install_assert_idle || return 1
    pensieve_install_verify "$source_bundle" || return 1
    capsule="$(/usr/bin/mktemp -d "$parent/.pensieve-install.XXXXXX")" || return 1
    # Preserve every candidate/backup on failure, with its exact recovery path.
    printf 'install_transaction: %s\n' "$capsule"
    pensieve_install_copy "$source_bundle" "$capsule/Pensieve.app" || return 1
    pensieve_install_verify "$capsule/Pensieve.app" || return 1
    pensieve_install_compare "$source_bundle" "$capsule/Pensieve.app" || return 1
    # Copy/signature checking can take time: inspect the live process census
    # again immediately before touching the installed path.
    pensieve_install_assert_idle || return 1
    if [[ -e "$destination" ]]; then
        /bin/mkdir "$capsule/previous" || return 1
        /bin/mv "$destination" "$capsule/previous/Pensieve.app" || return 1
        had_previous=true
    fi
    if ! /bin/mv "$capsule/Pensieve.app" "$destination"; then
        if [[ "$had_previous" == true ]]; then
            /bin/mv "$capsule/previous/Pensieve.app" "$destination" || return 1
        fi
        return 1
    fi
    if ! pensieve_install_verify_signature "$destination" \
        || ! pensieve_install_compare "$source_bundle" "$destination"; then
        pensieve_install_error "installed verification failed; candidate and previous bundle retained at $capsule"
        # Never move a newly launched app in order to roll back a failed install.
        if pensieve_install_assert_idle; then
            /bin/mv "$destination" "$capsule/Failed-Pensieve.app" || return 1
            if [[ "$had_previous" == true ]]; then
                /bin/mv "$capsule/previous/Pensieve.app" "$destination" || return 1
            fi
        fi
        return 1
    fi
    pensieve_install_receipt "$destination" || return 1
    if [[ "$had_previous" == true ]]; then
        printf 'previous_bundle: %s/previous/Pensieve.app\n' "$capsule"
    else
        /bin/rmdir "$capsule" || return 1
    fi
    printf 'install: verified; ready for an intentional production-profile launch\n'
)

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    set -euo pipefail
    if [[ "${1:-}" == --check-idle && $# == 1 ]]; then
        pensieve_install_assert_idle
        exit $?
    fi
    [[ $# -le 1 ]] || { pensieve_install_error 'usage: install-built-app.sh [source.app]'; exit 2; }
    pensieve_install_built_app \
        "${1:-$(cd "$PENSIEVE_INSTALL_SCRIPT_DIR/.." && pwd)/dist/Pensieve.app}" \
        /Applications/Pensieve.app
fi
