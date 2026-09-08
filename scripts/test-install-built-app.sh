#!/usr/bin/env bash
# Hermetic transaction tests: never inspect/stop a real app or touch /Applications.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/install-built-app.sh"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/pensieve-install-test.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT

pensieve_install_verify() { [[ -f "$1/trusted" ]]; }
pensieve_install_verify_signature() { [[ -f "$1/trusted" ]]; }
pensieve_install_copy() { /bin/cp -R "$1" "$2"; }
pensieve_install_receipt() { printf 'fixture receipt: %s\n' "$1"; }
pensieve_install_assert_idle() {
    idle_calls=$((idle_calls + 1))
    [[ "$busy_call" != "$idle_calls" ]]
}

setup_case() {
    case_root="$fixture/$1"
    mkdir -p "$case_root/source.app" "$case_root/apps/Pensieve.app"
    printf new > "$case_root/source.app/payload"
    touch "$case_root/source.app/trusted"
    printf old > "$case_root/apps/Pensieve.app/payload"
    idle_calls=0
    busy_call=0
}
assert_old() { [[ "$(cat "$case_root/apps/Pensieve.app/payload")" == old ]]; }
reject_install() {
    if pensieve_install_built_app "$case_root/source.app" "$case_root/apps/Pensieve.app"; then
        printf 'FAIL: unsafe installation unexpectedly succeeded\n' >&2
        exit 1
    fi
    assert_old
    [[ ! -e "$case_root/apps/.pensieve-install-lock" ]]
}

setup_case initially_busy
busy_call=1
reject_install
[[ "$(find "$case_root/apps" -name '.pensieve-install.*' | wc -l | tr -d ' ')" == 0 ]]

setup_case becomes_busy_during_copy
busy_call=2
reject_install

setup_case untrusted_source
rm "$case_root/source.app/trusted"
reject_install

setup_case copy_failure
pensieve_install_copy() { return 1; }
reject_install
pensieve_install_copy() { /bin/cp -R "$1" "$2"; }

setup_case rejected_installed_payload
pensieve_install_verify_signature() { return 1; }
reject_install
pensieve_install_verify_signature() { [[ -f "$1/trusted" ]]; }

setup_case successful_swap
pensieve_install_built_app "$case_root/source.app" "$case_root/apps/Pensieve.app"
[[ "$(cat "$case_root/apps/Pensieve.app/payload")" == new ]]
[[ ! -e "$case_root/apps/.pensieve-install-lock" ]]
backup="$(find "$case_root/apps" -path '*/previous/Pensieve.app/payload')"
[[ "$(cat "$backup")" == old ]]

# The real source-provenance helper rejects the production install path. It
# must still authenticate source and staging, while the final path uses strict
# signature verification and byte comparison against that authenticated source.
setup_case production_path_is_not_smoke_source
pensieve_install_verify() {
    [[ "$1" != "$case_root/apps/Pensieve.app" && -f "$1/trusted" ]] || return 1
    printf '%s\n' "$1" >> "$case_root/source-verifications"
}
pensieve_install_verify_signature() {
    [[ "$1" == "$case_root/apps/Pensieve.app" && -f "$1/trusted" ]] || return 1
    printf '%s\n' "$1" >> "$case_root/signature-verifications"
}
pensieve_install_built_app "$case_root/source.app" "$case_root/apps/Pensieve.app"
[[ "$(cat "$case_root/apps/Pensieve.app/payload")" == new ]]
[[ "$(wc -l < "$case_root/source-verifications" | tr -d ' ')" == 2 ]]
[[ "$(cat "$case_root/signature-verifications")" == "$case_root/apps/Pensieve.app" ]]
pensieve_install_verify() { [[ -f "$1/trusted" ]]; }
pensieve_install_verify_signature() { [[ -f "$1/trusted" ]]; }

setup_case concurrent_installer
mkdir "$case_root/apps/.pensieve-install-lock"
if pensieve_install_built_app "$case_root/source.app" "$case_root/apps/Pensieve.app"; then exit 1; fi
assert_old
[[ -d "$case_root/apps/.pensieve-install-lock" ]]

setup_case symlink_destination
mv "$case_root/apps/Pensieve.app" "$case_root/original.app"
ln -s "$case_root/original.app" "$case_root/apps/Pensieve.app"
if pensieve_install_built_app "$case_root/source.app" "$case_root/apps/Pensieve.app"; then exit 1; fi
assert_old
[[ -L "$case_root/apps/Pensieve.app" ]]
printf 'PASS: nine idle-safe installation transaction cases\n'
