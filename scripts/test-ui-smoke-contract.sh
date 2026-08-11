#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "$0")" && pwd -P)"
UI_SMOKE_SCRIPT="$SCRIPT_DIR/ui-smoke.sh"
FIXTURE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/pensieve-ui-smoke-contract.XXXXXX")"
AX_SCRIPT_FIXTURE="$FIXTURE_ROOT/toolbar-census.applescript"
COMPILED_AX_SCRIPT="$FIXTURE_ROOT/toolbar-census.scpt"

cleanup() {
  local original_status="$?"
  trap - EXIT INT TERM
  if [[ -d "$FIXTURE_ROOT" ]]; then
    /bin/rm -R -- "$FIXTURE_ROOT"
  fi
  exit "$original_status"
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

# These breadcrumbs make an outer watchdog failure attributable to one exact
# Accessibility stage instead of leaving a generic timeout after editable-New.
assert_marker_pair EXACT_WINDOW_COUNT 'set postMenuWindowCount to my exactWindowCount(targetPID)'
assert_marker_pair FINDER_ACTIVATE 'tell application "Finder" to activate'
assert_marker_pair EXACT_ACTIVATE 'my activateExactProcess(targetPID)'
assert_marker_pair RAISE 'my raiseExactProcessWindow(targetPID)'
assert_marker_pair CENSUS 'set regainCensus to my settledToolbarCensus(targetPID, baseExpectedIdentifiers, {}, 40)'
assert_marker_pair GEOMETRY 'my assertWindowGeometry(targetPID, coldPosition, coldSize, "key-window regain/redraw")'
pass "focus-regain Accessibility stages keep paired BEGIN/END breadcrumbs"
