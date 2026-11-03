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

# Restart fixtures exercise the real graceful-Quit policy with process and
# AppleEvent seams. No fixture can inspect or signal a desktop process.
pensieve_install_running_pids() {
    [[ "$process_lookup_fails" == false ]] || return 2
    [[ -f "$case_root/running" ]] || return 1
    cat "$case_root/running"
}
pensieve_install_process_path() { cat "$case_root/process-path"; }
pensieve_install_pause() { :; }
pensieve_install_verify() {
    [[ -f "$1/trusted" ]] || return 1
    printf 'verify\n' >> "$case_root/events"
}
pensieve_install_request_quit() {
    # Both source and staged copies must be verified before interrupting work.
    [[ "$(grep -c '^verify$' "$case_root/events")" == 2 ]] || return 1
    printf 'quit\n' >> "$case_root/events"
    [[ "$quit_mode" != cancelled ]] || return 1
    if [[ "$quit_mode" == accepted ]]; then rm "$case_root/running"; fi
}
pensieve_install_launch() {
    [[ "$(cat "$1/payload")" == new && -f "$1/trusted" ]] || return 1
    printf 'launch\n' >> "$case_root/events"
    [[ "$launch_fails" == false ]]
}
restart_case() {
    setup_case "$1"
    quit_mode=accepted
    launch_fails=false
    process_lookup_fails=false
    printf '123\n' > "$case_root/running"
    printf '%s\n' "$case_root/apps/Pensieve.app/Contents/MacOS/Pensieve" > "$case_root/process-path"
    : > "$case_root/events"
}
restart_install() {
    pensieve_install_built_app "$case_root/source.app" "$case_root/apps/Pensieve.app" true
}
reject_restart() {
    if restart_install; then
        printf 'FAIL: unsafe restart installation unexpectedly succeeded\n' >&2
        exit 1
    fi
    assert_old
    [[ ! -e "$case_root/apps/.pensieve-install-lock" ]]
    ! grep -q '^launch$' "$case_root/events"
}

restart_case normal_restart
restart_install
[[ "$(cat "$case_root/events")" == $'verify\nverify\nquit\nlaunch' ]]
[[ ! -e "$case_root/running" ]]

restart_case cancelled_quit
quit_mode=cancelled
reject_restart
[[ -f "$case_root/running" ]]

restart_case quit_returned_but_app_still_running
quit_mode=deferred
reject_restart
[[ -f "$case_root/running" ]]

restart_case different_running_bundle
printf '/another/checkout/Pensieve\n' > "$case_root/process-path"
reject_restart
! grep -q '^quit$' "$case_root/events"

restart_case failed_process_census
process_lookup_fails=true
reject_restart
! grep -q '^quit$' "$case_root/events"

restart_case untrusted_candidate_does_not_quit
rm "$case_root/source.app/trusted"
reject_restart
[[ ! -s "$case_root/events" ]]

restart_case app_reopened_before_swap
busy_call=1
reject_restart

restart_case failed_install_does_not_launch
pensieve_install_verify_signature() { return 1; }
reject_restart
pensieve_install_verify_signature() { [[ -f "$1/trusted" ]]; }

restart_case failed_launch_keeps_verified_install
launch_fails=true
if restart_install; then exit 1; fi
[[ "$(cat "$case_root/apps/Pensieve.app/payload")" == new ]]
[[ ! -e "$case_root/apps/.pensieve-install-lock" ]]

restart_case already_idle
rm "$case_root/running"
restart_install
[[ "$(cat "$case_root/events")" == $'verify\nverify\nlaunch' ]]

restart_case fresh_install
rm -rf "$case_root/apps/Pensieve.app"
rm "$case_root/running"
restart_install
[[ "$(cat "$case_root/apps/Pensieve.app/payload")" == new ]]

# The build target must leave the running app alone until the new build exists.
python3 - "$SCRIPT_DIR/../Makefile" <<'PY'
from pathlib import Path
import sys
text = Path(sys.argv[1]).read_text()
target = text.split('install-app: init-hooks', 1)[1].split('\n\n', 1)[0]
assert '--check-idle' not in target
assert target.index('$(MAKE) release-local') < target.index('--restart')
PY
printf 'PASS: graceful restart, cancellation, ownership, failure and target-ordering cases\n'

# A missing disposable cache must be reconstructed before provenance checks,
# without updating the graph or replacing any existing checkout bytes.
dependency_root="$fixture/dependencies"
mkdir -p "$dependency_root/Pensieve"
printf 'pinned graph\n' > "$dependency_root/Pensieve/Package.resolved"
resolve_mode=success
pensieve_install_resolve_package() {
    printf 'resolve\n' >> "$dependency_root/calls"
    [[ "$resolve_mode" != failure ]] || return 1
    [[ "$resolve_mode" != missing ]] || return 0
    mkdir -p "$1/.build/checkouts"
    if [[ "$resolve_mode" == rewrite ]]; then
        printf 'changed graph\n' > "$1/Package.resolved"
    fi
}
pensieve_install_prepare_dependencies "$dependency_root"
[[ "$(cat "$dependency_root/Pensieve/Package.resolved")" == 'pinned graph' ]]
[[ "$(wc -l < "$dependency_root/calls" | tr -d ' ')" == 1 ]]
printf 'existing checkout evidence\n' > "$dependency_root/Pensieve/.build/checkouts/evidence"
pensieve_install_prepare_dependencies "$dependency_root"
[[ "$(wc -l < "$dependency_root/calls" | tr -d ' ')" == 1 ]]
[[ -f "$dependency_root/Pensieve/.build/checkouts/evidence" ]]
for resolve_mode in failure missing rewrite; do
    rm -rf "$dependency_root/Pensieve/.build"
    printf 'pinned graph\n' > "$dependency_root/Pensieve/Package.resolved"
    if pensieve_install_prepare_dependencies "$dependency_root"; then
        printf 'FAIL: unsafe dependency restoration accepted (%s)\n' "$resolve_mode" >&2
        exit 1
    fi
done
rm -rf "$dependency_root/Pensieve/.build"
rm "$dependency_root/Pensieve/Package.resolved"
if pensieve_install_prepare_dependencies "$dependency_root"; then exit 1; fi
python3 - "$SCRIPT_DIR/install-built-app.sh" <<'PY'
from pathlib import Path
import sys
s = Path(sys.argv[1]).read_text()
resolver = s.split('pensieve_install_resolve_package() {', 1)[1].split('\n}', 1)[0]
assert '--force-resolved-versions resolve' in resolver
verify = s.split('pensieve_install_verify() {', 1)[1].split('\n}', 1)[0]
assert verify.index('pensieve_install_prepare_dependencies') < verify.index('isolated_app_assert_source_provenance')
PY
printf 'PASS: missing dependency recovery preserves pins and existing checkout evidence\n'
