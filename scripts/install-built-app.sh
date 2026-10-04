#!/usr/bin/env bash
# Install an existing Developer ID build; --restart requests a normal app Quit.
# Sourceable so the transaction can be tested entirely inside a fixture root.

PENSIEVE_INSTALL_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

pensieve_install_error() {
    printf 'install: %s\n' "$*" >&2
}

pensieve_install_running_pids() { /usr/bin/pgrep -x Pensieve; }
pensieve_install_process_path() { /bin/ps -p "$1" -o comm=; }
pensieve_install_pause() { /bin/sleep 0.2; }
pensieve_install_launch() { /usr/bin/open "$1"; }

pensieve_install_request_quit() {
    /usr/bin/osascript - "$1" <<'APPLESCRIPT'
on run argv
    set appPath to item 1 of argv
    with timeout of 120 seconds
        if application appPath is running then
            tell application appPath to quit
        end if
    end timeout
end run
APPLESCRIPT
}

pensieve_install_quit_running_app() {
    local destination="$1" pids status pid executable attempt=0
    if pids="$(pensieve_install_running_pids)"; then
        # Do not send Quit to a different checkout/debug build merely because
        # its executable has the same name. Never escalate to a signal.
        for pid in $pids; do
            executable="$(pensieve_install_process_path "$pid")" || return 1
            [[ "$executable" == "$destination/Contents/MacOS/Pensieve" ]] || {
                pensieve_install_error "PID $pid is not the installed destination; no Quit was sent"
                return 1
            }
        done
    else
        status=$?
        [[ "$status" == 1 ]] && return 0
        pensieve_install_error 'could not establish whether Pensieve is running'
        return 1
    fi
    printf 'install: asking Pensieve to quit normally; save or cancel in the app if prompted\n'
    pensieve_install_request_quit "$destination" || {
        pensieve_install_error 'Quit was cancelled or failed; no bundle was changed'
        return 1
    }
    while [[ "$attempt" -lt 150 ]]; do
        if pensieve_install_running_pids >/dev/null; then
            pensieve_install_pause
            attempt=$((attempt + 1))
        else
            status=$?
            [[ "$status" == 1 ]] && return 0
            pensieve_install_error 'could not verify that Pensieve quit'
            return 1
        fi
    done
    pensieve_install_error 'Pensieve is still running (Quit may have been cancelled); no bundle was changed'
    return 1
}

pensieve_install_assert_idle() {
    local pids status
    if pids="$(pensieve_install_running_pids)"; then
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

pensieve_install_resolve_package() {
    swift package --package-path "$1" --force-resolved-versions resolve
}

pensieve_install_prepare_dependencies() {
    local package="$1/Pensieve" pin_before pin_after
    [[ -d "$package/.build/checkouts" ]] && return 0
    [[ -f "$package/Package.resolved" ]] || {
        pensieve_install_error 'cannot restore dependencies without Package.resolved'
        return 1
    }
    pin_before="$(/usr/bin/shasum -a 256 "$package/Package.resolved")" || return 1
    printf 'install: restoring missing SwiftPM checkouts from Package.resolved\n' >&2
    pensieve_install_resolve_package "$package" >&2 || {
        pensieve_install_error 'could not restore pinned dependencies; no bundle was changed'
        return 1
    }
    pin_after="$(/usr/bin/shasum -a 256 "$package/Package.resolved")" || return 1
    [[ "$pin_before" == "$pin_after" && -d "$package/.build/checkouts" ]] || {
        pensieve_install_error 'dependency restoration changed the pins or left checkouts missing'
        return 1
    }
}

pensieve_install_verify() {
    local bundle="$1"
    local repo_root
    repo_root="$(cd "$PENSIEVE_INSTALL_SCRIPT_DIR/.." && pwd)" || return 1
    # .build is disposable. Restore absent checkouts, then let the existing
    # byte-level verifier authenticate them; never repair or hide dirty ones.
    pensieve_install_prepare_dependencies "$repo_root" || return 1
    # Reuse only the read-only verification seam; no smoke identity is created.
    # No historical or dirty-source override is accepted for installation.
    source "$PENSIEVE_INSTALL_SCRIPT_DIR/lib/isolated-app.sh"
    isolated_app_assert_source_provenance \
        "$repo_root" "$bundle" 0 0 >/dev/null
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
    local source_bundle="$1" destination="$2" restart="${3:-false}"
    local parent capsule had_previous=false
    [[ "$restart" == true || "$restart" == false ]] || return 2
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
    if [[ "$restart" == false ]]; then
        pensieve_install_assert_idle || return 1
    fi
    pensieve_install_verify "$source_bundle" || return 1
    capsule="$(/usr/bin/mktemp -d "$parent/.pensieve-install.XXXXXX")" || return 1
    # Preserve every candidate/backup on failure, with its exact recovery path.
    printf 'install_transaction: %s\n' "$capsule"
    pensieve_install_copy "$source_bundle" "$capsule/Pensieve.app" || return 1
    pensieve_install_verify "$capsule/Pensieve.app" || return 1
    pensieve_install_compare "$source_bundle" "$capsule/Pensieve.app" || return 1
    if [[ "$restart" == true ]]; then
        pensieve_install_quit_running_app "$destination" || return 1
    fi
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
    if [[ "$restart" == true ]]; then
        pensieve_install_launch "$destination" || {
            pensieve_install_error 'installation verified, but launching Pensieve failed'
            return 1
        }
        printf 'install: verified; launch requested for %s\n' "$destination"
    else
        printf 'install: verified; ready for an intentional production-profile launch\n'
    fi
)

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    set -euo pipefail
    if [[ "${1:-}" == --check-idle && $# == 1 ]]; then
        pensieve_install_assert_idle
        exit $?
    fi
    restart=false
    if [[ "${1:-}" == --restart ]]; then
        restart=true
        shift
    fi
    [[ $# -le 1 && "${1:-}" != --* ]] || {
        pensieve_install_error 'usage: install-built-app.sh [--restart] [source.app]'
        exit 2
    }
    pensieve_install_built_app \
        "${1:-$(cd "$PENSIEVE_INSTALL_SCRIPT_DIR/.." && pwd)/dist/Pensieve.app}" \
        /Applications/Pensieve.app "$restart"
fi
