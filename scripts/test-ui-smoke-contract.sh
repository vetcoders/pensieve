#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "$0")" && pwd -P)"
UI_SMOKE_SCRIPT="$SCRIPT_DIR/ui-smoke.sh"
MANUAL_SMOKE_SCRIPT="$SCRIPT_DIR/stage-manual-smoke.sh"
ISOLATED_APP_LIBRARY="$SCRIPT_DIR/lib/isolated-app.sh"
SYSTEM_EVENTS_PREFLIGHT_SCRIPT="$SCRIPT_DIR/lib/system-events-preflight.applescript"
NATIVE_TAB_AX_PROBE_SOURCE="$SCRIPT_DIR/lib/native-tab-ax-probe.swift"
FIXTURE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/pensieve-ui-smoke-contract.XXXXXX")"
AX_SCRIPT_FIXTURE="$FIXTURE_ROOT/toolbar-census.applescript"
COMPILED_AX_SCRIPT="$FIXTURE_ROOT/toolbar-census.scpt"
SETTINGS_SCRIPT_FIXTURE="$FIXTURE_ROOT/settings-lifecycle.applescript"
COMPILED_SETTINGS_SCRIPT="$FIXTURE_ROOT/settings-lifecycle.scpt"
SETTINGS_CG_GUARD_FIXTURE="$FIXTURE_ROOT/settings-onboarding-cg.swift"
BOUNDED_RUNNER_FIXTURE="$FIXTURE_ROOT/bounded-runner.sh"
SETTINGS_CG_REAPER_FIXTURE="$FIXTURE_ROOT/settings-cg-reaper.sh"
CG_REAPER_TEST_PIDS=""

combined_exit_status() {
  local original_status="$1" cleanup_status="$2"
  if [[ "$original_status" -ne 0 ]]; then
    printf '%s\n' "$original_status"
  else
    printf '%s\n' "$cleanup_status"
  fi
}

cleanup() {
  local original_status="$?"
  local cleanup_status=0
  trap - EXIT INT TERM
  set +e
  for child_pid in $CG_REAPER_TEST_PIDS; do
    kill -KILL "$child_pid" 2>/dev/null || true
    wait "$child_pid" 2>/dev/null || true
  done
  if [[ -d "$FIXTURE_ROOT" ]]; then
    /bin/rm -R -- "$FIXTURE_ROOT"
    cleanup_status=$?
  fi
  exit "$(combined_exit_status "$original_status" "$cleanup_status")"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

fail() {
  printf '[ui-smoke contract FAIL] %s\n' "$*" >&2
  exit 1
}

pass() {
  printf '[ui-smoke contract PASS] %s\n' "$*"
}

fixed_count_in() {
  local file="$1"
  local needle="$2"
  /usr/bin/grep -F -c -- "$needle" "$file" || true
}

regex_count_in() {
  local file="$1"
  local pattern="$2"
  /usr/bin/grep -E -c -- "$pattern" "$file" || true
}

fixed_count() {
  local needle="$1"
  fixed_count_in "$UI_SMOKE_SCRIPT" "$needle"
}

assert_fixed_count() {
  local needle="$1"
  local expected="$2"
  local actual
  actual="$(fixed_count "$needle")"
  [[ "$actual" == "$expected" ]] \
    || fail "expected $expected occurrence(s) of [$needle], found $actual"
}

assert_marker_pair() {
  local stage="$1"
  local operation="$2"
  local begin_marker="AX_REGAIN_${stage}_BEGIN"
  local end_marker="AX_REGAIN_${stage}_END"
  local begin_pattern end_pattern begin_count end_count begin_line end_line

  begin_pattern="^[[:space:]]*log \"${begin_marker}\"[[:space:]]*$"
  end_pattern="^[[:space:]]*log \"${end_marker}\"[[:space:]]*$"
  if [[ "$stage" == "EXACT_WINDOW_COUNT" ]]; then
    end_pattern='^[[:space:]]*log "AX_REGAIN_EXACT_WINDOW_COUNT_END=" & postMenuWindowCount[[:space:]]*$'
  fi

  begin_count="$(regex_count_in "$AX_SCRIPT_FIXTURE" "$begin_pattern")"
  end_count="$(regex_count_in "$AX_SCRIPT_FIXTURE" "$end_pattern")"
  [[ "$begin_count" == "1" ]] \
    || fail "expected one [$begin_marker] in toolbar AppleScript, found $begin_count"
  [[ "$end_count" == "1" ]] \
    || fail "expected one [$end_marker] in toolbar AppleScript, found $end_count"

  begin_line="$(/usr/bin/grep -n -E -- "$begin_pattern" "$AX_SCRIPT_FIXTURE" \
    | /usr/bin/cut -d: -f1)"
  end_line="$(/usr/bin/grep -n -E -- "$end_pattern" "$AX_SCRIPT_FIXTURE" \
    | /usr/bin/cut -d: -f1)"
  (( begin_line < end_line )) \
    || fail "[$begin_marker] must precede [$end_marker]"
  /usr/bin/sed -n "${begin_line},${end_line}p" "$AX_SCRIPT_FIXTURE" \
    | /usr/bin/grep -F -q -- "$operation" \
    || fail "[$begin_marker] / [$end_marker] do not enclose [$operation]"
}

# Keep this contract runnable on the same system Bash 3.2 lane as ui-smoke.
/bin/bash -n "$UI_SMOKE_SCRIPT" \
  || fail "ui-smoke.sh does not parse under the system Bash"
[[ -f "$SYSTEM_EVENTS_PREFLIGHT_SCRIPT" ]] \
  || fail "tracked System Events preflight script is missing"
/usr/bin/osacompile -o "$FIXTURE_ROOT/system-events-preflight.scpt" \
  "$SYSTEM_EVENTS_PREFLIGHT_SCRIPT" \
  || fail "System Events preflight AppleScript does not compile"

[[ -f "$NATIVE_TAB_AX_PROBE_SOURCE" ]] \
  || fail "tracked native-tab AX probe source is missing"
/usr/bin/xcrun swiftc -warnings-as-errors -typecheck \
  "$NATIVE_TAB_AX_PROBE_SOURCE" \
  -framework ApplicationServices \
  -framework CoreGraphics \
  || fail "native-tab AX probe does not type-check"
for required_probe_token in \
  'import ApplicationServices' \
  'import CoreGraphics' \
  'let systemWide = AXUIElementCreateSystemWide()' \
  'AXUIElementSetMessagingTimeout(systemWide, messagingTimeout)' \
  'AXUIElementSetMessagingTimeout(systemWide, 0)' \
  'AXUIElementPerformAction(tab, kAXPressAction as CFString)' \
  'case .cannotComplete:' \
  'verifying selected state' \
  'kAXSelectedChildrenAttribute' \
  'kAXSelectedAttribute' \
  'kAXTabGroupRole' \
  'kAXRadioButtonRole' \
  'kCGWindowIsOnscreen' \
  'kCGWindowLayer' \
  'NATIVE_TAB_GROUP_AX=PASS' \
  'NATIVE_TAB_ROUNDTRIP=PASS' \
  'PRESENTED_WINDOW_SURFACES=PASS'
do
  [[ "$(fixed_count_in "$NATIVE_TAB_AX_PROBE_SOURCE" "$required_probe_token")" -ge 1 ]] \
    || fail "native-tab AX probe lost required public-evidence token [$required_probe_token]"
done
[[ "$(fixed_count_in "$NATIVE_TAB_AX_PROBE_SOURCE" 'AXUIElementSetMessagingTimeout(')" == "2" ]] \
  || fail "native-tab AX probe must set and reset exactly one process-global messaging timeout"
[[ "$(fixed_count_in "$NATIVE_TAB_AX_PROBE_SOURCE" 'AXUIElementSetMessagingTimeout(application')" == "0" ]] \
  || fail "native-tab AX probe must not leave descendant calls on an application-only timeout"
for forbidden_probe_token in \
  'import AppKit' \
  'DebugTrace' \
  'PENSIEVE_TRACE' \
  'NSWindowTabGroup' \
  'tabbedWindows' \
  'CGSGet' \
  'CGSCopy'
do
  [[ "$(fixed_count_in "$NATIVE_TAB_AX_PROBE_SOURCE" "$forbidden_probe_token")" == "0" ]] \
    || fail "native-tab AX probe depends on forbidden internal/private token [$forbidden_probe_token]"
done
assert_fixed_count 'NATIVE_TAB_AX_PROBE_SOURCE="$SCRIPT_DIR/lib/native-tab-ax-probe.swift"' 1
assert_fixed_count 'native_tab_ax_probe_path() {' 1
assert_fixed_count 'NATIVE_TAB_AX_PROBE="$(native_tab_ax_probe_path)" \' 1
assert_fixed_count 'native_tab_probe_output="$(run_bounded_command 30 \' 1
assert_fixed_count '"Toolbar cold-frame witness" \' 1
assert_fixed_count '"pensieve-new-tab-smoke-witness" \' 1
assert_fixed_count 'NATIVE_TAB_VERIFIED_PID="$(isolated_app_verify_running_identity \' 1
probe_compile_line="$(/usr/bin/grep -n -F -- 'NATIVE_TAB_AX_PROBE="$(native_tab_ax_probe_path)' "$UI_SMOKE_SCRIPT" | /usr/bin/cut -d: -f1)"
display_wake_line="$(/usr/bin/grep -n -F -- 'caffeinate -u -t 2' "$UI_SMOKE_SCRIPT" | /usr/bin/cut -d: -f1)"
probe_run_line="$(/usr/bin/grep -n -F -- 'native_tab_probe_output="$(run_bounded_command 30' "$UI_SMOKE_SCRIPT" | /usr/bin/cut -d: -f1)"
native_ui_pass_line="$(/usr/bin/grep -n -F -- 'ok "native UI smoke passed"' "$UI_SMOKE_SCRIPT" | /usr/bin/cut -d: -f1)"
(( probe_compile_line < display_wake_line )) \
  || fail "native-tab helper compilation must finish before the smoke wakes or launches UI"
(( probe_run_line < native_ui_pass_line )) \
  || fail "native UI smoke is reported green before the native-tab AX proof runs"
pass "native-tab proof uses public AX/CG evidence, exact PID and a bounded round-trip"

# Stock macOS must never fall through to an unbounded osascript merely because
# Homebrew's gtimeout is absent. Extract the generic watchdog and exercise its
# /usr/bin/perl fallback under a PATH that cannot resolve gtimeout.
/usr/bin/awk '
  /^run_bounded_command\(\) \{$/ { inside = 1 }
  inside { print }
  inside && /^}$/ { closed = 1; exit }
  END { if (!inside || !closed) exit 1 }
' "$UI_SMOKE_SCRIPT" >"$BOUNDED_RUNNER_FIXTURE" \
  || fail "could not extract the bounded command watchdog"
/bin/bash -n "$BOUNDED_RUNNER_FIXTURE" \
  || fail "bounded command watchdog does not parse under the system Bash"
watchdog_started="$SECONDS"
set +e
PATH=/usr/bin:/bin /bin/bash -c \
  '. "$1"; run_bounded_command 1 /bin/sleep 5' _ "$BOUNDED_RUNNER_FIXTURE" \
  >/dev/null 2>&1
watchdog_status=$?
set -e
watchdog_elapsed=$((SECONDS - watchdog_started))
[[ "$watchdog_status" -ne 0 ]] \
  || fail "stock-macOS watchdog reported a timed-out command as successful"
(( watchdog_elapsed < 5 )) \
  || fail "stock-macOS watchdog allowed a five-second command to run unbounded"
watchdog_output="$(PATH=/usr/bin:/bin /bin/bash -c \
  '. "$1"; run_bounded_command 2 /usr/bin/printf bounded' _ "$BOUNDED_RUNNER_FIXTURE")" \
  || fail "stock-macOS watchdog rejected a successful bounded command"
[[ "$watchdog_output" == "bounded" ]] \
  || fail "stock-macOS watchdog changed command output: [$watchdog_output]"
assert_fixed_count "run_bounded_command \"\$timeout_seconds\" /usr/bin/osascript \"\$@\"" 1
[[ "$(regex_count_in "$UI_SMOKE_SCRIPT" '^[[:space:]]*osascript "\$@"')" == "0" ]] \
  || fail "ui-smoke still contains an unbounded direct osascript fallback"
pass "Accessibility commands remain bounded without Homebrew gtimeout"

# Automation authority belongs to the process driving System Events, not the
# staged application. Both smoke lanes must prove that authority before they
# create, retire or launch an identity. Exercise the shared decision with fake
# runners so this contract never prompts TCC or touches the operator's desktop.
preflight_success_output="$(/bin/bash -c '
  source "$1"
  isolated_app_run_bounded_command() {
    local timeout_seconds="$1"
    shift
    [[ "$timeout_seconds" == "10" && "$1" == "/usr/bin/osascript" \
      && "$2" == "$ISOLATED_APP_SYSTEM_EVENTS_PREFLIGHT_SCRIPT" ]] || return 9
    printf "SYSTEM_EVENTS_AUTOMATION=PASS\n"
  }
  isolated_app_assert_system_events_automation
' _ "$ISOLATED_APP_LIBRARY")" \
  || fail "shared System Events preflight rejected an authorized fake runner"
[[ "$preflight_success_output" == "SYSTEM_EVENTS_AUTOMATION=PASS" ]] \
  || fail "shared System Events preflight changed its success witness"
set +e
/bin/bash -c '
  source "$1"
  isolated_app_run_bounded_command() {
    printf "execution error: Not authorized to send Apple events to System Events. (-1743)\n" >&2
    return 1
  }
  isolated_app_assert_system_events_automation
' _ "$ISOLATED_APP_LIBRARY" >/dev/null 2>&1
preflight_denied_status=$?
set -e
[[ "$preflight_denied_status" == "3" ]] \
  || fail "a denied System Events preflight did not return environment status 3"

set +e
/bin/bash -c '
  source "$1"
  isolated_app_run_bounded_command() {
    printf "unexpected-success-marker\n"
  }
  isolated_app_assert_system_events_automation
' _ "$ISOLATED_APP_LIBRARY" >/dev/null 2>&1
preflight_bad_marker_status=$?
set -e
[[ "$preflight_bad_marker_status" == "1" ]] \
  || fail "a malformed System Events witness was not classified as a harness failure"

set +e
/bin/bash -c '
  source "$1"
  isolated_app_run_bounded_command() {
    return 124
  }
  isolated_app_assert_system_events_automation
' _ "$ISOLATED_APP_LIBRARY" >/dev/null 2>&1
preflight_timeout_status=$?
set -e
[[ "$preflight_timeout_status" == "3" ]] \
  || fail "a timed-out System Events preflight did not return environment status 3"

assert_fixed_count 'isolated_app_assert_system_events_automation \' 1
ui_preflight_line="$(/usr/bin/grep -n -F -- \
  'isolated_app_assert_system_events_automation \' \
  "$UI_SMOKE_SCRIPT" | /usr/bin/cut -d: -f1)"
ui_capsule_line="$(/usr/bin/grep -n -F -- 'SMOKE_ROOT="$(mktemp -d' \
  "$UI_SMOKE_SCRIPT" | /usr/bin/cut -d: -f1)"
ui_probe_compile_line="$(/usr/bin/grep -n -F -- \
  'NATIVE_TAB_AX_PROBE="$(native_tab_ax_probe_path)' \
  "$UI_SMOKE_SCRIPT" | /usr/bin/cut -d: -f1)"
(( ui_preflight_line < ui_probe_compile_line && ui_preflight_line < ui_capsule_line )) \
  || fail "automated smoke checks System Events only after helper/capsule work"

[[ "$(fixed_count_in "$MANUAL_SMOKE_SCRIPT" \
  'isolated_app_assert_system_events_automation \')" == "1" ]] \
  || fail "manual smoke lost its single shared System Events preflight"
manual_preflight_line="$(/usr/bin/grep -n -F -- \
  'isolated_app_assert_system_events_automation \' \
  "$MANUAL_SMOKE_SCRIPT" | /usr/bin/cut -d: -f1)"
manual_cleanup_line="$(/usr/bin/grep -n -F -- \
  '  cleanup_previous_manifested_identity' \
  "$MANUAL_SMOKE_SCRIPT" | /usr/bin/cut -d: -f1)"
manual_manifest_line="$(/usr/bin/grep -n -F -- \
  '  isolated_app_reserve_manifest \' \
  "$MANUAL_SMOKE_SCRIPT" | /usr/bin/cut -d: -f1)"
manual_open_line="$(/usr/bin/grep -n -F -- \
  '  isolated_app_open_new ' \
  "$MANUAL_SMOKE_SCRIPT" | /usr/bin/cut -d: -f1)"
(( manual_preflight_line < manual_cleanup_line \
  && manual_preflight_line < manual_manifest_line \
  && manual_preflight_line < manual_open_line )) \
  || fail "manual smoke mutates an experiment before proving System Events authority"
pass "both smoke lanes fail before identity mutation when System Events is unavailable"

# The contract test itself must preserve the original failure, but a successful
# assertion run must still fail if its cleanup fails.
[[ "$(combined_exit_status 7 9)" == "7" ]] \
  || fail "cleanup status replaced the contract test's original failure"
[[ "$(combined_exit_status 0 9)" == "9" ]] \
  || fail "cleanup failure was hidden after a successful contract run"
pass "contract cleanup preserves original failures and propagates cleanup failures"

# The toolbar census contains several independently bounded waits whose legal
# cumulative duration exceeds the old 90-second wrapper. Pin both the named
# watchdog and its only call site so a future refactor cannot silently put that
# wrapper back in front of the product assertions.
toolbar_timeout="$({
  /usr/bin/awk -F= '
    /^TOOLBAR_AX_OUTER_TIMEOUT_SECONDS=[0-9]+$/ {
      declarations += 1
      value = $2
    }
    END {
      if (declarations != 1) exit 1
      print value
    }
  ' "$UI_SMOKE_SCRIPT"
})" || fail "toolbar AX watchdog must have one literal numeric declaration"
declared_wait_ceiling="$({
  /usr/bin/awk -F= '
    /^TOOLBAR_AX_DECLARED_WAIT_CEILING_SECONDS=[0-9]+$/ {
      declarations += 1
      value = $2
    }
    END {
      if (declarations != 1) exit 1
      print value
    }
  ' "$UI_SMOKE_SCRIPT"
})" || fail "toolbar AX wait ceiling must have one literal numeric declaration"
[[ "$toolbar_timeout" =~ ^[0-9]+$ ]] \
  || fail "toolbar AX watchdog is not numeric: [$toolbar_timeout]"
[[ "$declared_wait_ceiling" =~ ^[0-9]+$ ]] \
  || fail "toolbar AX declared wait ceiling is not numeric: [$declared_wait_ceiling]"
[[ "$declared_wait_ceiling" == "101" ]] \
  || fail "toolbar AX declared wait ceiling drifted without a new budget audit: [$declared_wait_ceiling]"
(( toolbar_timeout >= 180 )) \
  || fail "toolbar AX watchdog must not fall below the empirically validated 180s budget (got ${toolbar_timeout}s)"
(( toolbar_timeout > declared_wait_ceiling )) \
  || fail "toolbar AX watchdog must exceed its ${declared_wait_ceiling}s declared wait ceiling"
assert_fixed_count \
  'if (( TOOLBAR_AX_OUTER_TIMEOUT_SECONDS <= TOOLBAR_AX_DECLARED_WAIT_CEILING_SECONDS )); then' 1
assert_fixed_count \
  "run_ax_osascript \"\$TOOLBAR_AX_OUTER_TIMEOUT_SECONDS\" \"\$ax_census_script\"" 1
assert_fixed_count "run_ax_osascript 90 \"\$ax_census_script\"" 0
pass "toolbar AX census uses a named ${toolbar_timeout}-second outer watchdog"

assert_fixed_count "cat >\"\$ax_census_script\" <<'APPLESCRIPT'" 1
/usr/bin/awk '
  /^cat >"\$ax_census_script" <<'\''APPLESCRIPT'\''$/ {
    inside = 1
    next
  }
  inside && /^APPLESCRIPT$/ {
    closed = 1
    exit
  }
  inside { print }
  END {
    if (!inside || !closed) exit 1
  }
' "$UI_SMOKE_SCRIPT" >"$AX_SCRIPT_FIXTURE" \
  || fail "could not extract the toolbar census AppleScript heredoc"

/usr/bin/osacompile -o "$COMPILED_AX_SCRIPT" "$AX_SCRIPT_FIXTURE" \
  >/dev/null 2>&1 \
  || fail "toolbar census AppleScript does not compile"
pass "toolbar census AppleScript compiles"

# Settings is a separate AppKit lifecycle surface, not part of the toolbar
# heredoc. Extract its one shared staged source and compile it independently so
# a quoting or handler drift cannot silently remove the phased regression guard
# before the operator-side smoke starts.
/usr/bin/awk '
  /^  cat >"\$SETTINGS_LIFECYCLE_SCRIPT" <<'\''APPLESCRIPT'\''$/ {
    inside = 1
    next
  }
  inside && /^APPLESCRIPT$/ {
    closed = 1
    exit
  }
  inside { print }
  END {
    if (!inside || !closed) exit 1
  }
' "$UI_SMOKE_SCRIPT" >"$SETTINGS_SCRIPT_FIXTURE" \
  || fail "could not extract the Settings lifecycle AppleScript heredoc"

/usr/bin/osacompile -o "$COMPILED_SETTINGS_SCRIPT" "$SETTINGS_SCRIPT_FIXTURE" \
  >/dev/null 2>&1 \
  || fail "Settings lifecycle AppleScript does not compile"
assert_settings_fixed_count() {
  local needle="$1" expected="$2" actual
  actual="$(fixed_count_in "$SETTINGS_SCRIPT_FIXTURE" "$needle")"
  [[ "$actual" == "$expected" ]] \
    || fail "expected $expected Settings-source occurrence(s) of [$needle], found $actual"
}
assert_fixed_count 'run_settings_window_lifecycle_probe' 2
assert_fixed_count \
  'SETTINGS_WINDOW_RESULT=PASS (exact AX/CG states 1-2-2-1-2-1-0-1-0; same visible surface on repeated Cmd+,; clean close/reopen)' 1
assert_fixed_count "SETTINGS_WINDOW_CG visible=\$first_settings_number repeated=\$repeated_settings_number reopened=\$reopened_settings_number zeroDocument=\$zero_document_settings_number" 1
assert_fixed_count \
  'SETTINGS_ONBOARDING_RESULT=PASS (blocked Cmd+, preserved native sheet and exact CG surface set; Configure detached the sheet before one AI Settings surface; no overlap observed during bounded AX polling)' 1
assert_settings_fixed_count 'set topWindows to every window' 5
assert_settings_fixed_count 'if hasSettings and (nativeSheetCount > 0 or hasOnboarding) then' 1
assert_settings_fixed_count '"SETTINGS_ONBOARDING_COMMAND_BLOCK_AX=PASS"' 1
assert_settings_fixed_count 'my holdBlockedOnboardingState(targetPID, 1)' 1
assert_settings_fixed_count 'my assertBlockedOnboardingState(targetPID)' 1
assert_settings_fixed_count 'Cmd+, escaped the native-modal Settings gate at sample' 1
assert_settings_fixed_count '"pensieve.errorbanner.status"' 1
assert_settings_fixed_count '"Close the current dialog before opening Settings."' 1
assert_settings_fixed_count 'blocked-Settings witness already existed before Cmd+,' 1
assert_settings_fixed_count 'if observedLabel is not expectedLabel then' 1
assert_settings_fixed_count 'repeat with sampleNumber from 1 to (durationSeconds * 20)' 1
assert_settings_fixed_count 'delay 0.05' 3
assert_settings_fixed_count 'attributeText(windowRef, "AXIdentifier")' 2
assert_settings_fixed_count '"pensieve.settings.window"' 1
assert_settings_fixed_count '"pensieve.saving.settings"' 1
assert_settings_fixed_count '"pensieve.provider.settings"' 1
assert_settings_fixed_count '"pensieve.provider.onboarding"' 1
assert_settings_fixed_count '"pensieve.provider.onboarding.configure"' 1
assert_settings_fixed_count 'if observedBundleID is not expectedBundleID then' 1
assert_fixed_count 'settings_cg_number_for_ax_bounds' 2
assert_fixed_count 'settled_window_server_state' 2
assert_fixed_count 'SMOKE_EXPECTED_CG_TOTAL' 2
assert_fixed_count 'SMOKE_EXPECTED_CG_ONSCREEN' 2
assert_fixed_count 'run_settings_stage repeat-general' 1
assert_fixed_count 'run_settings_stage close-launcher' 1
assert_fixed_count 'run_settings_stage open-general-zero' 1
assert_fixed_count 'run_settings_stage onboarding-block-command-settings' 1
assert_fixed_count 'run_settings_onboarding_transition_probe' 2
assert_fixed_count 'start_settings_onboarding_cg_guard' 2
assert_fixed_count 'wait_for_settings_onboarding_cg_ready' 2
assert_fixed_count 'finish_settings_onboarding_cg_guard' 2
assert_fixed_count 'stop_settings_onboarding_cg_guard' 3
assert_fixed_count 'SETTINGS_ONBOARDING_COMMAND_BLOCK_CG=PASS' 1
assert_fixed_count 'SETTINGS_ONBOARDING_COMMAND_BLOCK_RESULT=PASS' 1
assert_fixed_count 'prepare_first_smoke_scenario() {' 1
assert_fixed_count 'prepare_first_smoke_scenario' 2
assert_fixed_count 'prepare_next_smoke_scenario "Settings lifecycle scenario"' 1
assert_fixed_count 'prepare_next_smoke_scenario "Settings onboarding transition scenario"' 1
for environment_key in \
  LLM_ASSISTIVE_ENDPOINT LLM_FORMATTING_ENDPOINT LLM_ENDPOINT \
  LLM_ASSISTIVE_MODEL LLM_FORMATTING_MODEL LLM_MODEL
do
  assert_fixed_count "--env \"${environment_key}=\"" 1
done

# Compile the one-process CoreGraphics watcher independently from the shell
# wrapper, then pin the handshake and the evidence boundary it is supposed to
# enforce. This is a source contract; the actual exact-PID census runs only in
# the coordinated UI smoke.
/usr/bin/awk '
  /swift - >"\$SETTINGS_CG_GUARD_OUTPUT" 2>&1 <<'\''EOF'\'' &$/ {
    inside = 1
    next
  }
  inside && /^EOF$/ {
    closed = 1
    exit
  }
  inside { print }
  END { if (!inside || !closed) exit 1 }
' "$UI_SMOKE_SCRIPT" >"$SETTINGS_CG_GUARD_FIXTURE" \
  || fail "could not extract the Settings onboarding CG guard"
/usr/bin/xcrun swiftc -typecheck "$SETTINGS_CG_GUARD_FIXTURE" \
  || fail "Settings onboarding CG guard does not type-check"
assert_fixed_count "SMOKE_CG_READY=\"\$SETTINGS_CG_GUARD_READY\"" 1
assert_fixed_count "SMOKE_CG_DONE=\"\$SETTINGS_CG_GUARD_DONE\"" 1
assert_fixed_count 'SETTINGS_CG_GUARD_PID=$!' 1
assert_fixed_count "SETTINGS_CG_GUARD_ROOT=\"\$guard_root\"" 1
assert_fixed_count ": >\"\$SETTINGS_CG_GUARD_DONE\"" 2
assert_fixed_count "reap_exact_child_bounded \\" 2
assert_fixed_count 'return 124' 1
[[ "$(fixed_count "wait \"\$SETTINGS_CG_GUARD_PID\"")" == "0" ]] \
  || fail "Settings CG guard still contains a direct, potentially unbounded wait"
assert_fixed_count 'stop_settings_onboarding_cg_guard' 3
assert_fixed_count "/bin/rmdir -- \"\$SETTINGS_CG_GUARD_ROOT\"" 2
assert_fixed_count "/bin/rm -f -- \\" 1
assert_fixed_count "/bin/rm -f -- \"\$SETTINGS_CG_GUARD_READY\"" 1
assert_fixed_count "/bin/rm -f -- \"\$SETTINGS_CG_GUARD_DONE\"" 1
assert_fixed_count "/bin/rm -f -- \"\$SETTINGS_CG_GUARD_OUTPUT\"" 1
[[ "$(fixed_count_in "$SETTINGS_CG_GUARD_FIXTURE" 'stableReads >= 3')" == "1" ]] \
  || fail "Settings CG guard no longer requires three stable baseline reads"
[[ "$(fixed_count_in "$SETTINGS_CG_GUARD_FIXTURE" '!observed.isEmpty && observed.allSatisfy(\.onscreen)')" == "1" ]] \
  || fail "Settings CG baseline is no longer nonempty and entirely onscreen"
[[ "$(fixed_count_in "$SETTINGS_CG_GUARD_FIXTURE" ".sorted { \$0.number < \$1.number }")" == "1" ]] \
  || fail "Settings CG tuple set is no longer sorted by CGWindowNumber"
for tuple_field in 'number: Int' 'onscreen: Bool' 'x: Double' 'y: Double' 'width: Double' 'height: Double'; do
  [[ "$(fixed_count_in "$SETTINGS_CG_GUARD_FIXTURE" "$tuple_field")" == "1" ]] \
    || fail "Settings CG tuple lost field [$tuple_field]"
done
[[ "$(fixed_count_in "$SETTINGS_CG_GUARD_FIXTURE" 'Thread.sleep(forTimeInterval: 0.025)')" == "2" ]] \
  || fail "Settings CG guard no longer samples baseline and monitored interval at ~25ms"
[[ "$(fixed_count_in "$SETTINGS_CG_GUARD_FIXTURE" 'let final = census()')" == "1" ]] \
  || fail "Settings CG guard no longer takes a final post-done census"
[[ "$(fixed_count_in "$SETTINGS_CG_GUARD_FIXTURE" 'failMismatch(')" == "3" ]] \
  || fail "Settings CG guard mismatch paths drifted"
pass "Settings onboarding CG watcher compiles and pins derived-baseline concurrent evidence"

# Exercise the exact-child reaper and both callers under the system Bash. This
# is deliberately behavioral: source counts alone cannot prove that a stubborn
# child is escalated, that status 124 survives cleanup, or that an unrelated
# neighboring PID is left alone.
for function_name in \
  reap_exact_child_bounded \
  finish_settings_onboarding_cg_guard \
  stop_settings_onboarding_cg_guard
do
  /usr/bin/awk -v function_name="$function_name" '
    $0 == function_name "() {" { inside = 1 }
    inside { print }
    inside && /^}$/ { closed = 1; exit }
    END { if (!inside || !closed) exit 1 }
  ' "$UI_SMOKE_SCRIPT" >>"$SETTINGS_CG_REAPER_FIXTURE" \
    || fail "could not extract [$function_name] for the Settings CG reaper contract"
done
/bin/bash -n "$SETTINGS_CG_REAPER_FIXTURE" \
  || fail "Settings CG reaper functions do not parse under the system Bash"
# shellcheck source=/dev/null
source "$SETTINGS_CG_REAPER_FIXTURE"

# These globals are consumed dynamically by the sourced caller functions.
# shellcheck disable=SC2034
SETTINGS_CG_GUARD_NATURAL_EXIT_POLLS=2 \
  SETTINGS_CG_GUARD_TERM_EXIT_POLLS=20 \
  SETTINGS_CG_GUARD_KILL_EXIT_POLLS=20 \
  SETTINGS_CG_GUARD_REAP_POLL_SECONDS=0.025

prepare_cg_reaper_fixture() {
  SETTINGS_CG_GUARD_ROOT="$FIXTURE_ROOT/cg-reaper-$1"
  /bin/mkdir "$SETTINGS_CG_GUARD_ROOT"
  # The extracted finish/stop functions consume these dynamic globals.
  # shellcheck disable=SC2034
  SETTINGS_CG_GUARD_READY="$SETTINGS_CG_GUARD_ROOT/ready" \
    SETTINGS_CG_GUARD_DONE="$SETTINGS_CG_GUARD_ROOT/done" \
    SETTINGS_CG_GUARD_OUTPUT="$SETTINGS_CG_GUARD_ROOT/output.log"
  : >"$SETTINGS_CG_GUARD_READY"
  : >"$SETTINGS_CG_GUARD_OUTPUT"
}

prepare_cg_reaper_fixture natural
/bin/bash -c 'exit 7' &
SETTINGS_CG_GUARD_PID=$!
CG_REAPER_TEST_PIDS="$CG_REAPER_TEST_PIDS $SETTINGS_CG_GUARD_PID"
set +e
finish_settings_onboarding_cg_guard >/dev/null
natural_status=$?
set -e
if ! kill -0 "$SETTINGS_CG_GUARD_PID" 2>/dev/null; then
  CG_REAPER_TEST_PIDS=""
fi
[[ "$natural_status" -eq 7 ]] \
  || fail "Settings CG finish path changed natural child status 7 to $natural_status"
[[ ! -e "$FIXTURE_ROOT/cg-reaper-natural" ]] \
  || fail "Settings CG finish path left its exact guard root after natural exit"

term_ready="$FIXTURE_ROOT/cg-term-ready"
term_seen="$FIXTURE_ROOT/cg-term-seen"
prepare_cg_reaper_fixture term
/usr/bin/perl -e '
  use strict;
  use warnings;
  my ($ready, $seen) = @ARGV;
  $SIG{TERM} = sub {
    open my $seen_fh, ">", $seen or die $!;
    print {$seen_fh} "TERM\n";
    close $seen_fh;
    exit 42;
  };
  open my $ready_fh, ">", $ready or die $!;
  print {$ready_fh} "ready\n";
  close $ready_fh;
  sleep 30;
' "$term_ready" "$term_seen" &
SETTINGS_CG_GUARD_PID=$!
CG_REAPER_TEST_PIDS="$CG_REAPER_TEST_PIDS $SETTINGS_CG_GUARD_PID"
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [[ -f "$term_ready" ]] && break
  /bin/sleep 0.025
done
[[ -f "$term_ready" ]] || fail "TERM-aware CG reaper fixture did not become ready"
set +e
finish_settings_onboarding_cg_guard >/dev/null
term_status=$?
set -e
if ! kill -0 "$SETTINGS_CG_GUARD_PID" 2>/dev/null; then
  CG_REAPER_TEST_PIDS=""
fi
[[ "$term_status" -eq 124 ]] \
  || fail "Settings CG finish timeout returned $term_status instead of 124"
[[ -f "$term_seen" ]] \
  || fail "Settings CG finish timeout did not send TERM to its exact child"
[[ ! -e "$FIXTURE_ROOT/cg-reaper-term" ]] \
  || fail "Settings CG finish timeout left its exact guard root"

stubborn_ready="$FIXTURE_ROOT/cg-stubborn-ready"
bystander_ready="$FIXTURE_ROOT/cg-bystander-ready"
prepare_cg_reaper_fixture stubborn
/usr/bin/perl -e '
  use strict;
  use warnings;
  my $ready = shift;
  $SIG{TERM} = "IGNORE";
  open my $ready_fh, ">", $ready or die $!;
  print {$ready_fh} "ready\n";
  close $ready_fh;
  sleep 30;
' "$stubborn_ready" &
SETTINGS_CG_GUARD_PID=$!
stubborn_pid="$SETTINGS_CG_GUARD_PID"
CG_REAPER_TEST_PIDS="$CG_REAPER_TEST_PIDS $stubborn_pid"
/usr/bin/perl -e '
  use strict;
  use warnings;
  my $ready = shift;
  open my $ready_fh, ">", $ready or die $!;
  print {$ready_fh} "ready\n";
  close $ready_fh;
  sleep 30;
' "$bystander_ready" &
bystander_pid=$!
CG_REAPER_TEST_PIDS="$CG_REAPER_TEST_PIDS $bystander_pid"
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [[ -f "$stubborn_ready" && -f "$bystander_ready" ]] && break
  /bin/sleep 0.025
done
[[ -f "$stubborn_ready" && -f "$bystander_ready" ]] \
  || fail "stubborn/bystander CG reaper fixtures did not become ready"
set +e
stop_settings_onboarding_cg_guard >/dev/null 2>&1
stubborn_status=$?
set -e
[[ "$stubborn_status" -eq 124 ]] \
  || fail "Settings CG stop timeout returned $stubborn_status instead of 124"
kill -0 "$stubborn_pid" 2>/dev/null \
  && fail "Settings CG stop timeout left its stubborn exact child alive"
CG_REAPER_TEST_PIDS="$bystander_pid"
kill -0 "$bystander_pid" 2>/dev/null \
  || fail "Settings CG stop timeout signaled an unrelated neighboring PID"
[[ ! -e "$FIXTURE_ROOT/cg-reaper-stubborn" ]] \
  || fail "Settings CG stop timeout left its exact guard root"
kill -TERM "$bystander_pid" 2>/dev/null || true
wait "$bystander_pid" 2>/dev/null || true
CG_REAPER_TEST_PIDS=""
pass "Settings CG guard reaps one exact child with bounded natural, TERM and KILL phases"

pass "Settings lifecycle/onboarding source compiles and pins exact AX plus WindowServer states"

# These breadcrumbs make an outer watchdog failure attributable to one exact
# Accessibility stage instead of leaving a generic timeout after editable-New.
assert_marker_pair EXACT_WINDOW_COUNT 'set postMenuWindowCount to my exactWindowCount(targetPID)'
assert_marker_pair FINDER_ACTIVATE 'tell application "Finder" to activate'
assert_marker_pair EXACT_ACTIVATE 'my activateExactProcess(targetPID)'
assert_marker_pair RAISE 'my raiseExactProcessWindow(targetPID)'
assert_marker_pair CENSUS 'set regainCensus to my settledToolbarCensus(targetPID, baseExpectedIdentifiers, {}, 40)'
assert_marker_pair GEOMETRY 'my assertWindowGeometry(targetPID, coldPosition, coldSize, "key-window regain/redraw")'
pass "focus-regain Accessibility stages keep paired BEGIN/END breadcrumbs"
