#!/usr/bin/env bash
set -euo pipefail

# The harness never drives the bundle the operator actually uses. It stages a
# renamed, re-signed copy under $SMOKE_ROOT and drives that instead. Every
# INDEPENDENT SCENARIO gets a new bundle identifier, executable name, bundle
# path, support root, Keychain service and manifest. A delayed writer from one
# scenario therefore has no namespace that the next scenario can read.
# Cleanup retires each exact identity; no smoke path may target
# io.vetcoders.pensieve or the operator's production data.
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -P "$SCRIPT_DIR/.." && pwd -P)"
NATIVE_TAB_AX_PROBE_SOURCE="$SCRIPT_DIR/lib/native-tab-ax-probe.swift"
# shellcheck source=scripts/lib/isolated-app.sh
source "$SCRIPT_DIR/lib/isolated-app.sh"

SOURCE_APP_PATH="dist/Pensieve.app"
APP_PATH=""
APP_ID=""
RUN_TOKEN=""
APP_NAME=""
SMOKE_KEYCHAIN_SERVICE=""
SMOKE_SIGNING_MODE=""
COLD_ONLY=0
MENU_RESTORED_ONLY=0
EXTRA_EXPECTED_IDENTIFIERS=()
CAFFEINATE_PID=""
SMOKE_ROOT=""
SMOKE_CAPSULE_ROOT=""
SMOKE_SUPPORT=""
IDENTITY_MANIFEST=""
OWNED_PID=""
EXECUTABLE_PATH=""
SETTINGS_LIFECYCLE_SCRIPT=""
SETTINGS_CG_GUARD_PID=""
SETTINGS_CG_GUARD_ROOT=""
SETTINGS_CG_GUARD_READY=""
SETTINGS_CG_GUARD_DONE=""
SETTINGS_CG_GUARD_OUTPUT=""
SETTINGS_CG_GUARD_NATURAL_EXIT_POLLS=200
SETTINGS_CG_GUARD_TERM_EXIT_POLLS=80
SETTINGS_CG_GUARD_KILL_EXIT_POLLS=80
SETTINGS_CG_GUARD_REAP_POLL_SECONDS=0.025
NATIVE_TAB_AX_PROBE=""

# This watchdog encloses the complete toolbar scenario: process/window waits,
# three mode transitions, native-menu publication, editable-New, and the final
# focus-regain census. Its job is to stop a truly wedged osascript, not to race
# the scenario's bounded per-step assertions. Their declared worst-case delays
# already exceed 100 seconds before Accessibility traversal cost, so keep this
# outer budget comfortably above that cumulative ceiling.
TOOLBAR_AX_DECLARED_WAIT_CEILING_SECONDS=101
TOOLBAR_AX_OUTER_TIMEOUT_SECONDS=180
if (( TOOLBAR_AX_OUTER_TIMEOUT_SECONDS <= TOOLBAR_AX_DECLARED_WAIT_CEILING_SECONDS )); then
  printf '[ui-smoke] toolbar AX outer watchdog (%ss) must exceed its declared wait ceiling (%ss)\n' \
    "$TOOLBAR_AX_OUTER_TIMEOUT_SECONDS" \
    "$TOOLBAR_AX_DECLARED_WAIT_CEILING_SECONDS" >&2
  exit 2
fi

# Saved-state isolation probe state. The probe deliberately asks AppKit to keep
# windows while telling Pensieve NOT to restore its working set. A relaunch must
# still produce one empty launcher: if a document returns, Saved Application
# State became a second restore owner. Every override is written only to the
# smoke identity and restored after the run. QAKW = NSQuitAlwaysKeepsWindows.
RESTORATION_DEFAULT_ARMED=0
QAKW_WAS_SET=0
PRIOR_QAKW=""
PENSIEVE_RESTORE_DEFAULT_ARMED=0
PENSIEVE_RESTORE_WAS_SET=0
PRIOR_PENSIEVE_RESTORE=""

die() {
  printf '\033[33m[fail]\033[0m %s\n' "$*" >&2
  exit 1
}

log() {
  printf '\033[36m[ui]\033[0m %s\n' "$*"
}

ok() {
  printf '\033[32m[ ok ]\033[0m %s\n' "$*"
}

canonical_defaults_bool() {
  case "$1" in
    1 | true | TRUE | yes | YES) printf 'true\n' ;;
    0 | false | FALSE | no | NO) printf 'false\n' ;;
    *) return 1 ;;
  esac
}

# The whole defaults domain belongs to this run-specific identity. The shared
# isolation helper deletes it and performs a full read-back; command success by
# itself is not evidence that cfprefsd actually retired every key.
reset_smoke_defaults_domain() {
  isolated_app_reset_defaults_domain "$APP_ID" \
    || die "could not retire every preference in smoke domain $APP_ID"
}

# The restore-ON scenario itself has multiple phases under one identity. Before
# seeding its single-document restore, retire any file bookmarks produced by an
# earlier phase of THAT scenario. Cross-scenario isolation is stronger: those
# boundaries mint a different complete capsule instead of editing keys in
# place.
reset_smoke_working_set() {
  local key domain_dump
  for key in \
    Pensieve.workspace.fileBookmarks \
    Pensieve.workspace.rootBookmarks \
    Pensieve.openFolder.bookmark
  do
    defaults delete "$APP_ID" "$key" >/dev/null 2>&1 || true
  done
  domain_dump="$SMOKE_ROOT/working-set-reset.plist"
  defaults export "$APP_ID" "$domain_dump" >/dev/null 2>&1 \
    || die "could not read back smoke defaults after working-set reset"
  plutil -lint "$domain_dump" >/dev/null 2>&1 \
    || die "smoke defaults read-back is not a valid property list"
  for key in \
    Pensieve.workspace.fileBookmarks \
    Pensieve.workspace.rootBookmarks \
    Pensieve.openFolder.bookmark
  do
    if /usr/libexec/PlistBuddy -c "Print :$key" "$domain_dump" >/dev/null 2>&1; then
      die "could not reset smoke-only bookmark key $key before the restore-ON probe"
    fi
  done
}

# Shell out to a tiny Swift snippet that queries CoreGraphics' window server
# directly, bypassing the Accessibility tree entirely. Used only to classify a
# census failure: an empty AX census can mean the app truly has no window (a
# real product FAIL) or that its window exists but is offscreen because the
# active Space cannot host it (e.g. a fullscreen Screen Sharing session) --
# an environment condition, not a product bug.
dump_window_server_state() {
  [[ -n "${OWNED_PID:-}" ]] || return 1
  SMOKE_OWNER_PID="$OWNED_PID" swift - <<'EOF' 2>/dev/null || true
import CoreGraphics
import Foundation
// Passed through the environment rather than interpolated: the heredoc stays
// literal and the census is tied to the exact process verified by the harness.
let ownerPID = Int(ProcessInfo.processInfo.environment["SMOKE_OWNER_PID"] ?? "") ?? -1
let wl = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
var total = 0, onscreen = 0
for w in wl where (w["kCGWindowOwnerPID"] as? Int) == ownerPID
  && (w["kCGWindowLayer"] as? Int) == 0 {
  total += 1
  if (w["kCGWindowIsOnscreen"] as? Bool) == true { onscreen += 1 }
  let bounds = w["kCGWindowBounds"] as? [String: Any] ?? [:]
  let x = (bounds["X"] as? NSNumber)?.intValue ?? Int.min
  let y = (bounds["Y"] as? NSNumber)?.intValue ?? Int.min
  let width = (bounds["Width"] as? NSNumber)?.intValue ?? Int.min
  let height = (bounds["Height"] as? NSNumber)?.intValue ?? Int.min
  print("CGWINDOW num=\(w["kCGWindowNumber"] ?? "?") onscreen=\(w["kCGWindowIsOnscreen"] ?? false) x=\(x) y=\(y) width=\(width) height=\(height) name=\(w["kCGWindowName"] ?? "-")")
}
print("CGWINDOW_SUMMARY total=\(total) onscreen=\(onscreen)")
EOF
}

# Settings failures have historically survived one UI layer: AX could look
# clean while WindowServer still owned a real layer-0 shell. Poll CoreGraphics
# inside one Swift invocation until the complete exact-PID census holds steady,
# rather than sampling one frame or repeatedly recompiling the probe.
settled_window_server_state() {
  local expected_total="$1" expected_onscreen="$2"
  [[ -n "${OWNED_PID:-}" ]] || return 1
  SMOKE_OWNER_PID="$OWNED_PID" \
    SMOKE_EXPECTED_CG_TOTAL="$expected_total" \
    SMOKE_EXPECTED_CG_ONSCREEN="$expected_onscreen" \
    swift - <<'EOF'
import CoreGraphics
import Foundation

struct Entry: Equatable {
  let number: Int
  let onscreen: Bool
  let x: Int
  let y: Int
  let width: Int
  let height: Int
  let name: String
}

let environment = ProcessInfo.processInfo.environment
let ownerPID = Int(environment["SMOKE_OWNER_PID"] ?? "") ?? -1
let expectedTotal = Int(environment["SMOKE_EXPECTED_CG_TOTAL"] ?? "") ?? -1
let expectedOnscreen = Int(environment["SMOKE_EXPECTED_CG_ONSCREEN"] ?? "") ?? -1

func census() -> [Entry] {
  let windows = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID)
    as? [[String: Any]] ?? []
  return windows.compactMap { window -> Entry? in
    guard (window["kCGWindowOwnerPID"] as? Int) == ownerPID,
      (window["kCGWindowLayer"] as? Int) == 0
    else { return nil }
    let bounds = window["kCGWindowBounds"] as? [String: Any] ?? [:]
    return Entry(
      number: (window["kCGWindowNumber"] as? NSNumber)?.intValue ?? -1,
      onscreen: (window["kCGWindowIsOnscreen"] as? Bool) == true,
      x: (bounds["X"] as? NSNumber)?.intValue ?? Int.min,
      y: (bounds["Y"] as? NSNumber)?.intValue ?? Int.min,
      width: (bounds["Width"] as? NSNumber)?.intValue ?? Int.min,
      height: (bounds["Height"] as? NSNumber)?.intValue ?? Int.min,
      name: window["kCGWindowName"] as? String ?? "-")
  }.sorted { $0.number < $1.number }
}

var previous: [Entry] = []
var stableReads = 0
var latest: [Entry] = []
for _ in 0..<60 {
  latest = census()
  let onscreen = latest.filter(\.onscreen).count
  if latest.count == expectedTotal && onscreen == expectedOnscreen {
    stableReads = latest == previous ? stableReads + 1 : 1
    if stableReads >= 3 { break }
  } else {
    stableReads = 0
  }
  previous = latest
  Thread.sleep(forTimeInterval: 0.1)
}

for window in latest {
  print(
    "CGWINDOW num=\(window.number) onscreen=\(window.onscreen) "
      + "x=\(window.x) y=\(window.y) width=\(window.width) height=\(window.height) "
      + "name=\(window.name)")
}
let onscreen = latest.filter(\.onscreen).count
print("CGWINDOW_SUMMARY total=\(latest.count) onscreen=\(onscreen)")
if stableReads < 3 { exit(4) }
EOF
}

# The blocked Cmd+, onboarding probe needs stronger evidence than two bracketed
# screenshots. One Swift process derives the exact layer-0 baseline for the
# authenticated smoke PID, signals readiness, and then samples the complete
# (number, visibility, bounds) tuple set while Accessibility drives the real
# shortcut. Any transient surface observed by that ~25 ms census is a failure.
start_settings_onboarding_cg_guard() {
  local guard_root probe_pid
  [[ -n "${SMOKE_CAPSULE_ROOT:-}" && -d "$SMOKE_CAPSULE_ROOT" ]] || return 2
  [[ -z "${SETTINGS_CG_GUARD_PID:-}" ]] || return 2
  probe_pid="$(authenticated_owned_pid)" || return $?
  guard_root="$SMOKE_CAPSULE_ROOT/settings-onboarding-command-cg"
  /bin/mkdir "$guard_root" || return $?
  SETTINGS_CG_GUARD_ROOT="$guard_root"
  SETTINGS_CG_GUARD_READY="$guard_root/ready"
  SETTINGS_CG_GUARD_DONE="$guard_root/done"
  SETTINGS_CG_GUARD_OUTPUT="$guard_root/output.log"

  SMOKE_OWNER_PID="$probe_pid" \
    SMOKE_CG_READY="$SETTINGS_CG_GUARD_READY" \
    SMOKE_CG_DONE="$SETTINGS_CG_GUARD_DONE" \
    swift - >"$SETTINGS_CG_GUARD_OUTPUT" 2>&1 <<'EOF' &
import CoreGraphics
import Foundation

struct Entry: Equatable, CustomStringConvertible {
  let number: Int
  let onscreen: Bool
  let x: Double
  let y: Double
  let width: Double
  let height: Double

  var description: String {
    "number=\(number) onscreen=\(onscreen) x=\(x) y=\(y) width=\(width) height=\(height)"
  }
}

let environment = ProcessInfo.processInfo.environment
guard let ownerPID = Int(environment["SMOKE_OWNER_PID"] ?? ""), ownerPID > 0,
  let readyPath = environment["SMOKE_CG_READY"], !readyPath.isEmpty,
  let donePath = environment["SMOKE_CG_DONE"], !donePath.isEmpty
else {
  fputs("invalid Settings CG guard environment\n", stderr)
  exit(2)
}

func census() -> [Entry] {
  let windows = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID)
    as? [[String: Any]] ?? []
  return windows.compactMap { window -> Entry? in
    guard (window["kCGWindowOwnerPID"] as? NSNumber)?.intValue == ownerPID,
      (window["kCGWindowLayer"] as? NSNumber)?.intValue == 0
    else { return nil }
    let bounds = window["kCGWindowBounds"] as? [String: Any] ?? [:]
    return Entry(
      number: (window["kCGWindowNumber"] as? NSNumber)?.intValue ?? -1,
      onscreen: (window["kCGWindowIsOnscreen"] as? Bool) == true,
      x: (bounds["X"] as? NSNumber)?.doubleValue ?? -.infinity,
      y: (bounds["Y"] as? NSNumber)?.doubleValue ?? -.infinity,
      width: (bounds["Width"] as? NSNumber)?.doubleValue ?? -.infinity,
      height: (bounds["Height"] as? NSNumber)?.doubleValue ?? -.infinity)
  }.sorted { $0.number < $1.number }
}

func describe(_ entries: [Entry]) -> String {
  entries.map(\.description).joined(separator: " | ")
}

func failMismatch(_ phase: String, baseline: [Entry], observed: [Entry]) -> Never {
  fputs("Settings CG census changed during \(phase)\n", stderr)
  fputs("baseline: \(describe(baseline))\n", stderr)
  fputs("observed: \(describe(observed))\n", stderr)
  exit(5)
}

var previous: [Entry]?
var stableReads = 0
var baseline: [Entry]?
for _ in 0..<400 {
  let observed = census()
  if !observed.isEmpty && observed.allSatisfy(\.onscreen) {
    stableReads = observed == previous ? stableReads + 1 : 1
    if stableReads >= 3 {
      baseline = observed
      break
    }
  } else {
    stableReads = 0
  }
  previous = observed
  Thread.sleep(forTimeInterval: 0.025)
}

guard let baseline else {
  fputs("Settings CG baseline did not reach three identical, nonempty, entirely-onscreen reads\n", stderr)
  exit(4)
}

do {
  try Data("ready\n".utf8).write(to: URL(fileURLWithPath: readyPath), options: .atomic)
} catch {
  fputs("could not publish Settings CG ready signal: \(error)\n", stderr)
  exit(3)
}
print("SETTINGS_ONBOARDING_COMMAND_BLOCK_CG_BASELINE \(describe(baseline))")

let deadline = Date().addingTimeInterval(60)
while !FileManager.default.fileExists(atPath: donePath) {
  let observed = census()
  if observed != baseline {
    failMismatch("concurrent sampling", baseline: baseline, observed: observed)
  }
  if Date() >= deadline {
    fputs("Settings CG guard timed out waiting for the done signal\n", stderr)
    exit(6)
  }
  Thread.sleep(forTimeInterval: 0.025)
}

let final = census()
if final != baseline {
  failMismatch("post-done final census", baseline: baseline, observed: final)
}
print("SETTINGS_ONBOARDING_COMMAND_BLOCK_CG=PASS")
EOF
  SETTINGS_CG_GUARD_PID=$!
}

wait_for_settings_onboarding_cg_ready() {
  local sample_number=0
  [[ -n "${SETTINGS_CG_GUARD_PID:-}" ]] || return 2
  while (( sample_number < 400 )); do
    [[ -f "$SETTINGS_CG_GUARD_READY" ]] && return 0
    kill -0 "$SETTINGS_CG_GUARD_PID" 2>/dev/null || return 1
    sleep 0.025
    sample_number=$((sample_number + 1))
  done
  return 1
}

# Reap one exact background child without relying on Bash 4's `wait -n` or an
# unbounded blocking wait. The child first gets a bounded natural-exit window,
# then TERM and KILL grace windows. A process that crossed the natural deadline
# always returns 124, even if TERM let it run a signal handler and choose its
# own exit code. `wait` is used only after kill -0 proves the PID is gone, so it
# merely collects Bash's cached status and cannot block.
reap_exact_child_bounded() {
  local pid="${1:-}"
  local natural_exit_polls="${2:-}"
  local term_exit_polls="${3:-}"
  local kill_exit_polls="${4:-}"
  local poll_seconds="${5:-}"
  local sample_number=0 child_status=0

  [[ "$pid" =~ ^[1-9][0-9]*$ && "$pid" != "$$" ]] || return 2
  [[ "$natural_exit_polls" =~ ^[0-9]+$ ]] || return 2
  [[ "$term_exit_polls" =~ ^[0-9]+$ ]] || return 2
  [[ "$kill_exit_polls" =~ ^[0-9]+$ ]] || return 2
  [[ "$poll_seconds" =~ ^0\.[0-9]+$ ]] || return 2

  while (( sample_number < natural_exit_polls )); do
    if ! kill -0 "$pid" 2>/dev/null; then
      if wait "$pid"; then child_status=0; else child_status=$?; fi
      return "$child_status"
    fi
    /bin/sleep "$poll_seconds"
    sample_number=$((sample_number + 1))
  done
  if ! kill -0 "$pid" 2>/dev/null; then
    if wait "$pid"; then child_status=0; else child_status=$?; fi
    return "$child_status"
  fi

  kill -TERM "$pid" 2>/dev/null || true
  sample_number=0
  while (( sample_number < term_exit_polls )); do
    kill -0 "$pid" 2>/dev/null || break
    /bin/sleep "$poll_seconds"
    sample_number=$((sample_number + 1))
  done

  if kill -0 "$pid" 2>/dev/null; then
    kill -KILL "$pid" 2>/dev/null || true
    sample_number=0
    while (( sample_number < kill_exit_polls )); do
      kill -0 "$pid" 2>/dev/null || break
      /bin/sleep "$poll_seconds"
      sample_number=$((sample_number + 1))
    done
  fi

  # Collect a terminated child, but never turn its signal-derived status into
  # success: crossing the natural-exit deadline is a timeout by definition.
  if ! kill -0 "$pid" 2>/dev/null; then
    if wait "$pid"; then child_status=0; else child_status=$?; fi
  fi
  return 124
}

finish_settings_onboarding_cg_guard() {
  local guard_status=0 wait_status=0 cleanup_status=0
  [[ -n "${SETTINGS_CG_GUARD_PID:-}" ]] || return 2
  if : >"$SETTINGS_CG_GUARD_DONE"; then
    :
  else
    guard_status=$?
    # Without the done signal the watcher would wait for its full 60-second
    # deadline. Stop the exact child now; the caller already has a hard
    # failure to report and cleanup must not strand a Swift process.
    kill "$SETTINGS_CG_GUARD_PID" 2>/dev/null || true
  fi
  if reap_exact_child_bounded \
    "$SETTINGS_CG_GUARD_PID" \
    "$SETTINGS_CG_GUARD_NATURAL_EXIT_POLLS" \
    "$SETTINGS_CG_GUARD_TERM_EXIT_POLLS" \
    "$SETTINGS_CG_GUARD_KILL_EXIT_POLLS" \
    "$SETTINGS_CG_GUARD_REAP_POLL_SECONDS"; then
    :
  else
    wait_status=$?
    [[ "$guard_status" -ne 0 ]] || guard_status="$wait_status"
  fi
  [[ -f "$SETTINGS_CG_GUARD_OUTPUT" ]] && /bin/cat "$SETTINGS_CG_GUARD_OUTPUT"
  /bin/rm -f -- \
    "$SETTINGS_CG_GUARD_READY" \
    "$SETTINGS_CG_GUARD_DONE" \
    "$SETTINGS_CG_GUARD_OUTPUT" \
    || cleanup_status=$?
  /bin/rmdir -- "$SETTINGS_CG_GUARD_ROOT" 2>/dev/null || cleanup_status=$?
  [[ "$guard_status" -ne 0 || "$cleanup_status" -eq 0 ]] || guard_status="$cleanup_status"
  SETTINGS_CG_GUARD_PID=""
  SETTINGS_CG_GUARD_ROOT=""
  SETTINGS_CG_GUARD_READY=""
  SETTINGS_CG_GUARD_DONE=""
  SETTINGS_CG_GUARD_OUTPUT=""
  return "$guard_status"
}

stop_settings_onboarding_cg_guard() {
  local guard_status=0 cleanup_status=0
  [[ -n "${SETTINGS_CG_GUARD_PID:-}" ]] || return 0
  [[ -n "${SETTINGS_CG_GUARD_DONE:-}" ]] && : >"$SETTINGS_CG_GUARD_DONE" 2>/dev/null || true
  if reap_exact_child_bounded \
    "$SETTINGS_CG_GUARD_PID" \
    "$SETTINGS_CG_GUARD_NATURAL_EXIT_POLLS" \
    "$SETTINGS_CG_GUARD_TERM_EXIT_POLLS" \
    "$SETTINGS_CG_GUARD_KILL_EXIT_POLLS" \
    "$SETTINGS_CG_GUARD_REAP_POLL_SECONDS"; then
    :
  else
    guard_status=$?
  fi
  [[ -f "${SETTINGS_CG_GUARD_OUTPUT:-}" ]] \
    && /bin/cat "$SETTINGS_CG_GUARD_OUTPUT" >&2 \
    || true
  if [[ -n "${SETTINGS_CG_GUARD_READY:-}" ]]; then
    /bin/rm -f -- "$SETTINGS_CG_GUARD_READY" 2>/dev/null || cleanup_status=$?
  fi
  if [[ -n "${SETTINGS_CG_GUARD_DONE:-}" ]]; then
    /bin/rm -f -- "$SETTINGS_CG_GUARD_DONE" 2>/dev/null || cleanup_status=$?
  fi
  if [[ -n "${SETTINGS_CG_GUARD_OUTPUT:-}" ]]; then
    /bin/rm -f -- "$SETTINGS_CG_GUARD_OUTPUT" 2>/dev/null || cleanup_status=$?
  fi
  if [[ -n "${SETTINGS_CG_GUARD_ROOT:-}" ]]; then
    /bin/rmdir -- "$SETTINGS_CG_GUARD_ROOT" 2>/dev/null || cleanup_status=$?
  fi
  [[ "$guard_status" -ne 0 || "$cleanup_status" -eq 0 ]] || guard_status="$cleanup_status"
  SETTINGS_CG_GUARD_PID=""
  SETTINGS_CG_GUARD_ROOT=""
  SETTINGS_CG_GUARD_READY=""
  SETTINGS_CG_GUARD_DONE=""
  SETTINGS_CG_GUARD_OUTPUT=""
  return "$guard_status"
}

# Re-resolve the complete runtime identity immediately before any destructive
# process control. The NSRunningApplication control helper must independently
# validate the remembered PID, bundle id, bundle path and executable path.
resolve_owned_pid_for_control() {
  local resolved_pid status
  if resolved_pid="$(verify_running_smoke_identity 2>/dev/null)"; then
    if [[ -n "${OWNED_PID:-}" && "$resolved_pid" != "$OWNED_PID" ]]; then
      printf '\033[33m[fail]\033[0m exact smoke identity changed pid (%s -> %s); refusing process control\n' \
        "$OWNED_PID" "$resolved_pid" >&2
      return 2
    fi
    OWNED_PID="$resolved_pid"
    printf '%s\n' "$resolved_pid"
    return 0
  else
    status=$?
  fi
  if isolated_app_assert_not_running "$APP_ID" >/dev/null 2>&1; then
    OWNED_PID=""
    return 3
  fi
  printf '\033[33m[fail]\033[0m smoke bundle id is running, but its exact bundle/executable cannot be authenticated (status=%s)\n' \
    "$status" >&2
  return 2
}

terminate_app() {
  # A caller preparing a restoration relaunch can grant a longer graceful
  # timeout. Graceful wait and force escalation are one exact-identity
  # NSRunningApplication transaction; there is deliberately no POSIX fallback.
  local graceful_attempts="${1:-0}"
  local graceful_timeout=2
  local pid status
  [[ "$graceful_attempts" -gt 0 ]] && graceful_timeout=5

  if pid="$(resolve_owned_pid_for_control)"; then
    OWNED_PID="$pid"
  else
    status=$?
    if [[ "$status" -eq 3 ]]; then OWNED_PID=""; return 0; fi
    return 1
  fi

  if isolated_app_control_identity \
    terminate "$APP_ID" "$APP_PATH" "$APP_PATH/Contents/MacOS/$APP_NAME" \
    "$pid" "$graceful_timeout"; then
    OWNED_PID=""
    return 0
  else
    status=$?
  fi
  case "$status" in
    3) OWNED_PID=""; return 0 ;;
    4)
      printf '\033[33m[fail]\033[0m exact smoke identity changed during termination\n' >&2
      return 1
      ;;
    5)
      printf '\033[33m[fail]\033[0m %s\n' \
        "$APP_NAME survived exact NSRunningApplication termination; a live survivor would corrupt the next run's census" >&2
      ;;
    *) return 1 ;;
  esac
  return 1
}

# Run every Accessibility AppleScript behind an outer watchdog. Homebrew's GNU
# timeout is optional; stock macOS still ships /usr/bin/perl, whose alarm
# survives exec and terminates a wedged osascript with SIGALRM. There is no
# unbounded fallback: if neither watchdog is available, the smoke is
# environment-inconclusive rather than silently able to hang forever.
run_bounded_command() {
  local timeout_seconds="$1"
  shift
  if command -v gtimeout >/dev/null 2>&1; then
    gtimeout --signal=TERM "$timeout_seconds" "$@"
    return $?
  fi
  if [[ -x /usr/bin/perl ]]; then
    /usr/bin/perl -e '
      use strict;
      use warnings;
      my $seconds = shift @ARGV;
      die "invalid timeout\n" unless defined($seconds) && $seconds =~ /\A[1-9][0-9]*\z/;
      alarm($seconds);
      exec @ARGV;
      die "could not exec bounded command: $!\n";
    ' "$timeout_seconds" "$@"
    return $?
  fi
  printf '\033[33m[ui]\033[0m no bounded command watchdog is available (need gtimeout or /usr/bin/perl)\n' >&2
  return 3
}

run_ax_osascript() {
  local timeout_seconds="$1"
  shift
  run_bounded_command "$timeout_seconds" /usr/bin/osascript "$@"
}

# Compile the tracked public-API AX/WindowServer probe into the same
# repository-local runtime-tools cache as the exact-identity process helper.
# The cache key binds both source bytes and the active Swift SDK/toolchain; an
# interrupted build can publish only its PID-scoped partial, never the final
# executable. Compile before launching the smoke app so build work cannot
# perturb the native-tab state that the helper later observes.
native_tab_ax_probe_path() {
  local source="$NATIVE_TAB_AX_PROBE_SOURCE"
  local cache_root="$REPO_ROOT/Pensieve/.build/pensieve-runtime-tools"
  local toolchain_fingerprint cache_key helper partial

  [[ -f "$source" ]] || {
    printf '\033[33m[fail]\033[0m tracked native-tab AX probe is missing: %s\n' "$source" >&2
    return 1
  }
  toolchain_fingerprint="$(
    /usr/bin/shasum -a 256 "$source"
    /usr/bin/xcrun --sdk macosx swiftc --version
    /usr/bin/xcrun --sdk macosx --show-sdk-path
  )" || return 1
  cache_key="$(printf '%s' "$toolchain_fingerprint" | /usr/bin/shasum -a 256 \
    | /usr/bin/awk '{ print $1 }')" || return 1
  [[ "$cache_key" =~ ^[0-9a-f]{64}$ ]] || return 1

  helper="$cache_root/native-tab-ax-probe-$cache_key"
  if [[ ! -x "$helper" ]]; then
    /bin/mkdir -p "$cache_root" || return 1
    partial="$helper.partial.$$"
    if ! /usr/bin/xcrun --sdk macosx swiftc \
      -warnings-as-errors -O \
      "$source" \
      -framework ApplicationServices \
      -framework CoreGraphics \
      -o "$partial"; then
      /bin/rm -f -- "$partial"
      printf '\033[33m[fail]\033[0m could not compile native-tab AX probe\n' >&2
      return 1
    fi
    /bin/chmod 700 "$partial" || {
      /bin/rm -f -- "$partial"
      return 1
    }
    /bin/mv -f "$partial" "$helper" || {
      /bin/rm -f -- "$partial"
      return 1
    }
  fi
  printf '%s\n' "$helper"
}

# Force macOS/AppKit state restoration to fire on the next launch regardless of
# the operator's global "Close windows when quitting an app" setting. Snapshot
# whatever the app domain held first so disarm can restore it exactly.
arm_restoration_default() {
  if PRIOR_QAKW="$(defaults read "$APP_ID" NSQuitAlwaysKeepsWindows 2>/dev/null)"; then
    QAKW_WAS_SET=1
  else
    QAKW_WAS_SET=0
    PRIOR_QAKW=""
  fi
  defaults write "$APP_ID" NSQuitAlwaysKeepsWindows -bool true
  RESTORATION_DEFAULT_ARMED=1
}

# Revert NSQuitAlwaysKeepsWindows to its pre-run state: delete it when the run
# introduced it, otherwise rewrite the captured prior value.
disarm_restoration_default() {
  [[ "$RESTORATION_DEFAULT_ARMED" -eq 1 ]] || return 0
  if [[ "$QAKW_WAS_SET" -eq 1 ]]; then
    local prior_bool
    prior_bool="$(canonical_defaults_bool "$PRIOR_QAKW")" \
      || die "saved-state probe captured a non-boolean NSQuitAlwaysKeepsWindows value: $PRIOR_QAKW"
    defaults write "$APP_ID" NSQuitAlwaysKeepsWindows -bool "$prior_bool" >/dev/null 2>&1 \
      || return 1
  else
    defaults delete "$APP_ID" NSQuitAlwaysKeepsWindows 2>/dev/null || true
  fi
  RESTORATION_DEFAULT_ARMED=0
}

# Point the smoke domain's own startup-restore setting at a known value. The
# prior value is snapshotted exactly once, on the first arm of the run, so a
# probe that flips the setting the other way still disarms back to what the
# domain held before the run started.
arm_pensieve_restore() {
  local wanted="$1"
  if [[ "$PENSIEVE_RESTORE_DEFAULT_ARMED" -eq 1 ]]; then
    defaults write "$APP_ID" Pensieve.restoreSessionOnLaunch -bool "$wanted"
    return 0
  fi
  if PRIOR_PENSIEVE_RESTORE="$(defaults read "$APP_ID" Pensieve.restoreSessionOnLaunch 2>/dev/null)"; then
    PENSIEVE_RESTORE_WAS_SET=1
  else
    PENSIEVE_RESTORE_WAS_SET=0
    PRIOR_PENSIEVE_RESTORE=""
  fi
  defaults write "$APP_ID" Pensieve.restoreSessionOnLaunch -bool "$wanted"
  PENSIEVE_RESTORE_DEFAULT_ARMED=1
}

arm_pensieve_restore_off() {
  arm_pensieve_restore false
}

arm_pensieve_restore_on() {
  arm_pensieve_restore true
}

disarm_pensieve_restore_default() {
  [[ "$PENSIEVE_RESTORE_DEFAULT_ARMED" -eq 1 ]] || return 0
  if [[ "$PENSIEVE_RESTORE_WAS_SET" -eq 1 ]]; then
    local prior_bool
    prior_bool="$(canonical_defaults_bool "$PRIOR_PENSIEVE_RESTORE")" \
      || die "saved-state probe captured a non-boolean restore value: $PRIOR_PENSIEVE_RESTORE"
    defaults write "$APP_ID" Pensieve.restoreSessionOnLaunch -bool "$prior_bool" \
      >/dev/null 2>&1 || return 1
  else
    defaults delete "$APP_ID" Pensieve.restoreSessionOnLaunch 2>/dev/null || true
  fi
  PENSIEVE_RESTORE_DEFAULT_ARMED=0
}

# Single launch funnel. The staged Info.plist already carries the override in
# LSEnvironment; repeating it here means a launch stays isolated even if
# LaunchServices ever declines to honor LSEnvironment for a staged bundle.
open_smoke_app() {
  local verified_pid open_status=0 query_status
  if open \
    --env "PENSIEVE_SUPPORT_DIR=$SMOKE_SUPPORT" \
    --env "PENSIEVE_KEYCHAIN_SERVICE=$SMOKE_KEYCHAIN_SERVICE" \
    --env "LLM_ASSISTIVE_ENDPOINT=" \
    --env "LLM_FORMATTING_ENDPOINT=" \
    --env "LLM_ENDPOINT=" \
    --env "LLM_ASSISTIVE_MODEL=" \
    --env "LLM_FORMATTING_MODEL=" \
    --env "LLM_MODEL=" \
    "$@"; then
    open_status=0
  else
    open_status=$?
  fi

  # LaunchServices may report -600 after it has already created the process.
  # The exact runtime identity, not `open`'s return alone, decides whether a
  # retry is safe. A retry is permitted only after proving no process exists.
  if verified_pid="$(isolated_app_wait_for_running_identity \
    "$APP_ID" "$APP_PATH" "$APP_PATH/Contents/MacOS/$APP_NAME" 120 2>/dev/null)"; then
    OWNED_PID="$verified_pid"
    return 0
  fi
  if isolated_app_assert_not_running "$APP_ID" >/dev/null 2>&1; then
    [[ "$open_status" -ne 0 ]] && return "$open_status"
    return 1
  else
    query_status=$?
  fi
  die "the smoke bundle id is live but its exact staged bundle/executable cannot be proven (status=$query_status); refusing a second launch"
}

# Build the isolated bundle the whole run drives through the shared staging
# primitive used by manual smoke as well. One implementation owns executable,
# bundle/defaults, support, Keychain, signing and cleanup invariants.
stage_smoke_app() {
  local source="$1" staged="$2" support="$3"
  isolated_app_stage_bundle \
    "$source" "$staged" "$APP_NAME" "$APP_ID" "$APP_NAME" "$APP_NAME" \
    "$support" "$SMOKE_KEYCHAIN_SERVICE" "$REPO_ROOT" \
    "${PENSIEVE_UI_SMOKE_ALLOW_STALE_SOURCE:-0}" \
    "${PENSIEVE_UI_SMOKE_ALLOW_DIRTY_SOURCE:-0}" \
    || die "could not stage isolated smoke bundle from $source"
  SMOKE_SIGNING_MODE="${ISOLATED_APP_SIGNING_MODE:-verified local signature}"
}

verify_running_smoke_identity() {
  isolated_app_verify_running_identity \
    "$APP_ID" "$APP_PATH" "$APP_PATH/Contents/MacOS/$APP_NAME"
}

authenticated_owned_pid() {
  local verified_pid
  verified_pid="$(verify_running_smoke_identity)" \
    || die "the running smoke identity no longer matches its bundle and executable"
  [[ -n "${OWNED_PID:-}" ]] \
    || die "the smoke process has no authenticated owner PID"
  [[ "$verified_pid" == "$OWNED_PID" ]] \
    || die "the smoke PID changed unexpectedly ($OWNED_PID -> $verified_pid)"
  printf '%s\n' "$verified_pid"
}

# A smoke is not allowed to create its first witness until the app itself has
# proved the empty profile we claim to be testing. The new bundle identifier
# makes inherited state impossible by construction; this runtime assertion
# catches future stores that are accidentally added outside that capsule.
run_fresh_launcher_baseline_probe() {
  log "fresh-profile baseline (one empty launcher, no workspace/files/recovery/recents)"
  terminate_app
  open_smoke_app -n "$APP_PATH" || {
    sleep 0.5
    open_smoke_app -n "$APP_PATH"
  }

  local verified_pid
  verified_pid="$(verify_running_smoke_identity)" \
    || die "fresh-profile baseline launched the wrong bundle or executable"
  log "fresh-profile runtime identity pid=$verified_pid id=$APP_ID"

  # A healthy baseline completes in roughly three seconds. Keep the outer
  # budget above the 20 × 2-second bounded AX lookup worst case so a briefly
  # slow WindowServer cannot turn an isolated restage into a false timeout.
  run_ax_osascript 90 - "$verified_pid" "$APP_ID" <<'APPLESCRIPT'
property expectedBundleID : ""
on run argv
  set targetPID to (item 1 of argv) as integer
  set my expectedBundleID to item 2 of argv as text
  my waitForProcess(targetPID, 15)
  my waitForWindow(targetPID, 15)
  my makeExactProcessFrontmost(targetPID, 5)
  delay 0.5

  -- One early frame is insufficient: a store hydrated after launch could put
  -- stale workspace or recovery rows back after the first census. Require the
  -- exact empty launcher to remain stable for three continuous seconds.
  repeat with sampleNumber from 1 to 20
    set censusResult to my exactLauncherCensus(targetPID, 2)
    set windowCount to item 1 of censusResult
    set identifiers to item 2 of censusResult

    if windowCount is not 1 then
      error "fresh profile must keep exactly one launcher, got " & windowCount & " at sample " & sampleNumber
    end if
    if identifiers does not contain "pensieve.sidebar.emptyState" then
      error "fresh profile lost the empty sidebar at sample " & sampleNumber & "; identifiers={" & my joined(identifiers, ",") & "}"
    end if
    repeat with forbiddenIdentifier in {"pensieve.sidebar.list.openFiles", "pensieve.sidebar.list.workspace", "pensieve.recoveredDrafts", "pensieve.recoveredDrafts.row", "pensieve.emptyState.recents"}
      if identifiers contains (forbiddenIdentifier as text) then
        error "fresh profile exposed stale UI [" & (forbiddenIdentifier as text) & "] at sample " & sampleNumber
      end if
    end repeat
    delay 0.15
  end repeat

  log "FRESH_PROFILE_RESULT=PASS (stable 3s; one empty launcher; zero workspace/open files/recovery/recents)"
  return "fresh profile"
end run

on makeExactProcessFrontmost(targetPID, timeoutSeconds)
  repeat with i from 1 to (timeoutSeconds * 20)
    set appProcess to my processForPID(targetPID, expectedBundleID)
    if appProcess is not missing value then
      try
        tell application "System Events" to tell appProcess to set frontmost to true
        return true
      end try
    end if
    delay 0.05
  end repeat
  error "Timed out resolving the exact process for frontmost pid=" & targetPID
end makeExactProcessFrontmost

on exactLauncherCensus(targetPID, timeoutSeconds)
  repeat with i from 1 to (timeoutSeconds * 20)
    set appProcess to my processForPID(targetPID, expectedBundleID)
    if appProcess is not missing value then
      try
        tell application "System Events"
          tell appProcess
            set windowCount to count of windows
            set identifiers to {}
            if windowCount is 1 then
              set windowElements to entire contents of window 1
              repeat with elementRef in windowElements
                try
                  set identifierValue to value of attribute "AXIdentifier" of elementRef
                  if identifierValue is not missing value and identifierValue is not "" then
                    set end of identifiers to identifierValue as text
                  end if
                end try
              end repeat
            end if
          end tell
        end tell
        return {windowCount, identifiers}
      end try
    end if
    delay 0.05
  end repeat
  error "Timed out taking the exact launcher census for pid=" & targetPID
end exactLauncherCensus

on processForPID(targetPID, expectedBundleID)
  tell application "System Events"
    repeat with processRef in application processes
      set observedPID to missing value
      try
        set observedPID to unix id of processRef
      end try
      if observedPID is targetPID then
        try
          set observedBundleID to bundle identifier of processRef
        on error errorMessage
          error "could not read bundle identifier for pid=" & targetPID & ": " & errorMessage
        end try
        if observedBundleID is not expectedBundleID then
          error "pid=" & targetPID & " belongs to unexpected bundle=" & observedBundleID
        end if
        return processRef
      end if
    end repeat
  end tell
  return missing value
end processForPID

on waitForProcess(targetPID, timeoutSeconds)
  repeat with i from 1 to (timeoutSeconds * 10)
    if my processForPID(targetPID, expectedBundleID) is not missing value then return true
    delay 0.1
  end repeat
  error "Timed out waiting for pid=" & targetPID
end waitForProcess

on waitForWindow(targetPID, timeoutSeconds)
  repeat with i from 1 to (timeoutSeconds * 10)
    set appProcess to my processForPID(targetPID, expectedBundleID)
    if appProcess is not missing value then
      try
        tell application "System Events"
          tell appProcess
          if (count of windows) > 0 then return true
          end tell
        end tell
      end try
    end if
    delay 0.1
  end repeat
  error "Timed out waiting for a window"
end waitForWindow

on joined(itemsList, delimiter)
  set previousDelimiters to AppleScript's text item delimiters
  set AppleScript's text item delimiters to delimiter
  set joinedText to itemsList as text
  set AppleScript's text item delimiters to previousDelimiters
  return joinedText
end joined
APPLESCRIPT

  terminate_app 60 \
    || die "fresh-profile baseline process survived its termination barrier"
}

# One compiled source drives every Settings phase. Bash deliberately returns
# between phases so CoreGraphics can sample the same stable native surfaces AX
# just proved, including the zero-document state and the onboarding sheet.
stage_settings_lifecycle_script() {
  SETTINGS_LIFECYCLE_SCRIPT="$SMOKE_ROOT/settings-window-lifecycle.applescript"
  cat >"$SETTINGS_LIFECYCLE_SCRIPT" <<'APPLESCRIPT'
property expectedBundleID : ""
property settingsWindowIdentifier : "pensieve.settings.window"
property generalPaneIdentifier : "pensieve.saving.settings"
property aiPaneIdentifier : "pensieve.provider.settings"
property onboardingIdentifier : "pensieve.provider.onboarding"
property configureIdentifier : "pensieve.provider.onboarding.configure"
property errorBannerIdentifier : "pensieve.errorbanner.status"
property expectedBlockedMessage : "Close the current dialog before opening Settings."

on run argv
  set targetPID to (item 1 of argv) as integer
  set my expectedBundleID to item 2 of argv as text
  set stageName to item 3 of argv as text
  set stageResult to "SETTINGS_STAGE_PASS=" & stageName
  my waitForProcess(targetPID, 15)

  if stageName is "open-general" then
    my waitForState(targetPID, 1, false, "none", false, 15)
    my invokeSettingsShortcut(targetPID)
    set settingsWindow to my waitForState(targetPID, 2, true, "general", false, 15)
    set stageResult to my settingsBounds(settingsWindow)
  else if stageName is "repeat-general" then
    set settingsWindow to my waitForState(targetPID, 2, true, "general", false, 15)
    my invokeSettingsShortcut(targetPID)
    set settingsWindow to my waitForState(targetPID, 2, true, "general", false, 15)
    set stageResult to my settingsBounds(settingsWindow)
  else if stageName is "close-settings-with-launcher" then
    set settingsWindow to my waitForState(targetPID, 2, true, "general", false, 15)
    my closeWindow(settingsWindow)
    my waitForState(targetPID, 1, false, "none", false, 15)
  else if stageName is "reopen-general" then
    my waitForState(targetPID, 1, false, "none", false, 15)
    my invokeSettingsShortcut(targetPID)
    set settingsWindow to my waitForState(targetPID, 2, true, "general", false, 15)
    set stageResult to my settingsBounds(settingsWindow)
  else if stageName is "close-launcher" then
    set launcherWindow to my onlyNonSettingsWindow(targetPID)
    my closeWindow(launcherWindow)
    my waitForState(targetPID, 0, false, "none", false, 15)
  else if stageName is "open-general-zero" then
    my waitForState(targetPID, 0, false, "none", false, 15)
    my invokeSettingsShortcut(targetPID)
    set settingsWindow to my waitForState(targetPID, 1, true, "general", false, 15)
    set stageResult to my settingsBounds(settingsWindow)
  else if stageName is "close-settings-zero" then
    set settingsWindow to my waitForState(targetPID, 1, true, "general", false, 15)
    my closeWindow(settingsWindow)
    my waitForState(targetPID, 0, false, "none", false, 15)
  else if stageName is "onboarding-before" then
    set launcherWindow to my waitForOnboarding(targetPID, 15)
    set stageResult to "SETTINGS_ONBOARDING_BEFORE=PASS"
  else if stageName is "onboarding-block-command-settings" then
    set launcherWindow to my waitForOnboarding(targetPID, 15)
    if my elementWithIdentifier(launcherWindow, errorBannerIdentifier) is not missing value then
      error "blocked-Settings witness already existed before Cmd+,"
    end if
    my invokeSettingsShortcut(targetPID)
    my holdBlockedOnboardingState(targetPID, 1)
    set stageResult to "SETTINGS_ONBOARDING_COMMAND_BLOCK_AX=PASS"
  else if stageName is "onboarding-configure" then
    set launcherWindow to my waitForOnboarding(targetPID, 15)
    set configureButton to my elementWithIdentifier(launcherWindow, configureIdentifier)
    if configureButton is missing value then error "onboarding Configure control is missing"
    tell application "System Events" to perform action "AXPress" of configureButton
    set settingsWindow to my waitForOnboardingTransition(targetPID, 15)
    set stageResult to my settingsBounds(settingsWindow)
  else if stageName is "onboarding-close-settings" then
    set settingsWindow to my waitForState(targetPID, 2, true, "ai", false, 15)
    my closeWindow(settingsWindow)
    my waitForState(targetPID, 1, false, "none", false, 15)
  else
    error "unknown Settings smoke stage: " & stageName
  end if
  return stageResult
end run

on invokeSettingsShortcut(targetPID)
  set appProcess to my processForPID(targetPID, expectedBundleID)
  if appProcess is missing value then error "exact smoke pid disappeared before Cmd+,"
  tell application "System Events" to tell appProcess
    set frontmost to true
    keystroke "," using command down
  end tell
end invokeSettingsShortcut

on waitForState(targetPID, expectedCount, expectsSettings, paneName, expectsOnboarding, timeoutSeconds)
  set lastProblem to "no census"
  repeat with i from 1 to (timeoutSeconds * 20)
    try
      set stateResult to my assertState(targetPID, expectedCount, expectsSettings, paneName, expectsOnboarding)
      return stateResult
    on error errorMessage
      set lastProblem to errorMessage
    end try
    delay 0.05
  end repeat
  error "Timed out waiting for exact AX state; last=" & lastProblem
end waitForState

on assertState(targetPID, expectedCount, expectsSettings, paneName, expectsOnboarding)
  set appProcess to my processForPID(targetPID, expectedBundleID)
  if appProcess is missing value then error "exact smoke pid disappeared during AX census"
  tell application "System Events" to tell appProcess
    set topWindows to every window
  end tell
  if (count of topWindows) is not expectedCount then
    error "top-level AXWindows=" & (count of topWindows) & ", expected=" & expectedCount
  end if

  set settingsWindows to {}
  repeat with windowRef in topWindows
    set subroleValue to my attributeText(windowRef, "AXSubrole")
    if subroleValue is not "AXStandardWindow" then
      error "top-level surface is not AXStandardWindow: " & subroleValue
    end if
    if my attributeText(windowRef, "AXIdentifier") is settingsWindowIdentifier then
      set end of settingsWindows to contents of windowRef
    end if
  end repeat

  if expectsSettings then
    if (count of settingsWindows) is not 1 then
      error "expected exactly one identified Settings window, got " & (count of settingsWindows)
    end if
    set settingsWindow to item 1 of settingsWindows
    set identifiers to my identifiersIn(settingsWindow)
    if paneName is "general" then
      if identifiers does not contain generalPaneIdentifier then error "General pane identifier is absent"
      if identifiers contains aiPaneIdentifier then error "AI pane overlaps General"
    else if paneName is "ai" then
      if identifiers does not contain aiPaneIdentifier then error "AI pane identifier is absent"
      if identifiers contains generalPaneIdentifier then error "General pane overlaps AI"
    end if
    if expectsOnboarding is false and identifiers contains onboardingIdentifier then
      error "onboarding content exists inside Settings"
    end if
    return settingsWindow
  end if

  if (count of settingsWindows) is not 0 then error "unexpected Settings window exists"
  return missing value
end assertState

on waitForOnboarding(targetPID, timeoutSeconds)
  set lastProblem to "no census"
  repeat with i from 1 to (timeoutSeconds * 20)
    try
      return my assertOnboardingWithoutSettings(targetPID)
    on error errorMessage
      set lastProblem to errorMessage
    end try
    delay 0.05
  end repeat
  error "Timed out waiting for native onboarding sheet; last=" & lastProblem
end waitForOnboarding

on holdBlockedOnboardingState(targetPID, durationSeconds)
  repeat with sampleNumber from 1 to (durationSeconds * 20)
    try
      my assertBlockedOnboardingState(targetPID)
    on error errorMessage
      error "Cmd+, escaped the native-modal Settings gate at sample " & sampleNumber & ": " & errorMessage
    end try
    delay 0.05
  end repeat
  return true
end holdBlockedOnboardingState

on assertBlockedOnboardingState(targetPID)
  set launcherWindow to my assertOnboardingWithoutSettings(targetPID)
  set errorBanner to my elementWithIdentifier(launcherWindow, errorBannerIdentifier)
  if errorBanner is missing value then error "blocked Settings command did not publish its status banner"
  set expectedLabel to "Message: " & expectedBlockedMessage
  set observedLabel to my attributeText(errorBanner, "AXLabel")
  if observedLabel is not expectedLabel then
    error "blocked Settings status label=[" & observedLabel & "], expected=[" & expectedLabel & "]"
  end if
  return launcherWindow
end assertBlockedOnboardingState

on assertOnboardingWithoutSettings(targetPID)
  set appProcess to my processForPID(targetPID, expectedBundleID)
  if appProcess is missing value then error "exact smoke pid disappeared during onboarding census"
  tell application "System Events" to tell appProcess
    set topWindows to every window
    if (count of topWindows) is not 1 then error "onboarding top-level AXWindows=" & (count of topWindows)
    set launcherWindow to item 1 of topWindows
    if (count of sheets of launcherWindow) is not 1 then error "launcher native sheet count is not one"
    set onboardingSheet to sheet 1 of launcherWindow
  end tell
  set sheetIdentifiers to my identifiersIn(onboardingSheet)
  if sheetIdentifiers does not contain onboardingIdentifier then error "onboarding identifier is absent from native sheet"
  if sheetIdentifiers does not contain configureIdentifier then error "Configure identifier is absent from native sheet"
  if my allWindowIdentifiers(targetPID) contains settingsWindowIdentifier then error "Settings exists while onboarding owns a native sheet"
  return launcherWindow
end assertOnboardingWithoutSettings

on waitForOnboardingTransition(targetPID, timeoutSeconds)
  set lastProblem to "transition did not start"
  repeat with i from 1 to (timeoutSeconds * 40)
    set appProcess to my processForPID(targetPID, expectedBundleID)
    if appProcess is missing value then error "exact smoke pid disappeared during onboarding transition"
    tell application "System Events" to tell appProcess
      set topWindows to every window
      set nativeSheetCount to 0
      repeat with windowRef in topWindows
        set nativeSheetCount to nativeSheetCount + (count of sheets of windowRef)
      end repeat
    end tell
    set identifiers to my allWindowIdentifiers(targetPID)
    set hasOnboarding to identifiers contains onboardingIdentifier
    set hasSettings to identifiers contains settingsWindowIdentifier

    -- Any overlap observed by this loop is a regression. Each pass includes a
    -- minimum 25 ms delay plus Accessibility traversal; this is deliberately
    -- stronger than a final-state-only check, but neither fixed-rate sampling
    -- nor a claim that Accessibility exposes every compositor frame.
    if hasSettings and (nativeSheetCount > 0 or hasOnboarding) then
      error "Settings overlapped the native onboarding sheet"
    end if
    if hasSettings and nativeSheetCount is 0 and hasOnboarding is false then
      try
        return my assertState(targetPID, 2, true, "ai", false)
      on error errorMessage
        set lastProblem to errorMessage
      end try
    else
      set lastProblem to "settings=" & hasSettings & ", sheets=" & nativeSheetCount & ", onboarding=" & hasOnboarding
    end if
    delay 0.025
  end repeat
  error "Timed out waiting for detached onboarding -> Settings transition; last=" & lastProblem
end waitForOnboardingTransition

on onlyNonSettingsWindow(targetPID)
  set appProcess to my processForPID(targetPID, expectedBundleID)
  tell application "System Events" to tell appProcess to set topWindows to every window
  set candidates to {}
  repeat with windowRef in topWindows
    if my attributeText(windowRef, "AXIdentifier") is not settingsWindowIdentifier then
      set end of candidates to contents of windowRef
    end if
  end repeat
  if (count of candidates) is not 1 then error "expected one non-Settings launcher"
  return item 1 of candidates
end onlyNonSettingsWindow

on closeWindow(windowRef)
  tell application "System Events" to tell windowRef
    set closeButton to first button whose value of attribute "AXSubrole" is "AXCloseButton"
    perform action "AXPress" of closeButton
  end tell
end closeWindow

on allWindowIdentifiers(targetPID)
  set appProcess to my processForPID(targetPID, expectedBundleID)
  tell application "System Events" to tell appProcess to set topWindows to every window
  set result to {}
  repeat with windowRef in topWindows
    set result to result & my identifiersIn(windowRef)
  end repeat
  return result
end allWindowIdentifiers

on identifiersIn(containerRef)
  set identifiers to {}
  set ownIdentifier to my attributeText(containerRef, "AXIdentifier")
  if ownIdentifier is not "" then set end of identifiers to ownIdentifier
  tell application "System Events" to set descendants to entire contents of containerRef
  repeat with elementRef in descendants
    set identifierValue to my attributeText(elementRef, "AXIdentifier")
    if identifierValue is not "" then set end of identifiers to identifierValue
  end repeat
  return identifiers
end identifiersIn

on elementWithIdentifier(containerRef, wantedIdentifier)
  tell application "System Events" to set descendants to entire contents of containerRef
  repeat with elementRef in descendants
    if my attributeText(elementRef, "AXIdentifier") is wantedIdentifier then return contents of elementRef
  end repeat
  return missing value
end elementWithIdentifier

on attributeText(elementRef, attributeName)
  try
    tell application "System Events" to set attributeValue to value of attribute attributeName of elementRef
    if attributeValue is missing value then return ""
    return attributeValue as text
  end try
  return ""
end attributeText

on settingsBounds(settingsWindow)
  tell application "System Events" to tell settingsWindow
    set {windowX, windowY} to position
    set {windowWidth, windowHeight} to size
  end tell
  return "SETTINGS_AX_BOUNDS x=" & windowX & " y=" & windowY & " width=" & windowWidth & " height=" & windowHeight
end settingsBounds

on processForPID(targetPID, expectedBundleID)
  tell application "System Events"
    repeat with processRef in application processes
      set observedPID to missing value
      try
        set observedPID to unix id of processRef
      end try
      if observedPID is targetPID then
        try
          set observedBundleID to bundle identifier of processRef
        on error errorMessage
          error "could not read bundle identifier for pid=" & targetPID & ": " & errorMessage
        end try
        if observedBundleID is not expectedBundleID then
          error "pid=" & targetPID & " belongs to unexpected bundle=" & observedBundleID
        end if
        return processRef
      end if
    end repeat
  end tell
  return missing value
end processForPID

on waitForProcess(targetPID, timeoutSeconds)
  repeat with i from 1 to (timeoutSeconds * 10)
    if my processForPID(targetPID, expectedBundleID) is not missing value then return true
    delay 0.1
  end repeat
  error "Timed out waiting for pid=" & targetPID
end waitForProcess
APPLESCRIPT
}

run_settings_stage() {
  local stage_name="$1" probe_pid
  probe_pid="$(authenticated_owned_pid)"
  run_ax_osascript 45 "$SETTINGS_LIFECYCLE_SCRIPT" "$probe_pid" "$APP_ID" "$stage_name"
}

settings_cg_number_for_ax_bounds() {
  local ax_state="$1" cg_state="$2" x y width height
  x="$(printf '%s\n' "$ax_state" | /usr/bin/sed -n 's/^SETTINGS_AX_BOUNDS x=\([-0-9][0-9]*\) y=.*/\1/p')"
  y="$(printf '%s\n' "$ax_state" | /usr/bin/sed -n 's/^SETTINGS_AX_BOUNDS x=[-0-9][0-9]* y=\([-0-9][0-9]*\) width=.*/\1/p')"
  width="$(printf '%s\n' "$ax_state" | /usr/bin/sed -n 's/^SETTINGS_AX_BOUNDS .* width=\([0-9][0-9]*\) height=.*/\1/p')"
  height="$(printf '%s\n' "$ax_state" | /usr/bin/sed -n 's/^SETTINGS_AX_BOUNDS .* height=\([0-9][0-9]*\)$/\1/p')"
  [[ -n "$x" && -n "$y" && -n "$width" && -n "$height" ]] || return 1
  printf '%s\n' "$cg_state" | /usr/bin/awk \
    -v wanted_x="$x" -v wanted_y="$y" -v wanted_width="$width" -v wanted_height="$height" '
      /^CGWINDOW / {
        delete fields
        for (index = 1; index <= NF; index += 1) {
          split($index, pair, "=")
          fields[pair[1]] = pair[2]
        }
        # Accessibility reports logical points while CoreGraphics can round
        # a window edge by one point. Accept only the smallest platform
        # rounding tolerance, and still require one unique layer-0 match.
        dx = fields["x"] - wanted_x; if (dx < 0) dx = -dx
        dy = fields["y"] - wanted_y; if (dy < 0) dy = -dy
        dw = fields["width"] - wanted_width; if (dw < 0) dw = -dw
        dh = fields["height"] - wanted_height; if (dh < 0) dh = -dh
        if (dx <= 1 && dy <= 1 && dw <= 1 && dh <= 1) {
          matches += 1
          number = fields["num"]
        }
      }
      END {
        if (matches != 1) exit 1
        print number
      }
    '
}

assert_settings_window_server_state() {
  local expected_total="$1" expected_onscreen="$2" ax_state="${3:-}"
  local cg_state settings_number
  cg_state="$(settled_window_server_state "$expected_total" "$expected_onscreen")" \
    || die "Settings WindowServer census did not settle at total=$expected_total onscreen=$expected_onscreen"
  if [[ -n "$ax_state" ]]; then
    settings_number="$(settings_cg_number_for_ax_bounds "$ax_state" "$cg_state")" \
      || die "could not correlate exactly one Settings CGWindowNumber with its AX bounds"
    printf '%s\n' "$settings_number"
    return 0
  fi
  printf '%s\n' "$cg_state"
}

# Settings used to be owned by SwiftUI's `Settings` scene. Exercise the real
# shortcut with and without a document window and prove every intermediate AX
# and WindowServer state, not merely the final absence.
run_settings_window_lifecycle_probe() {
  local ax_state first_settings_number repeated_settings_number
  local reopened_settings_number zero_document_settings_number
  log "Settings window lifecycle probe (exact AX and WindowServer census)"
  terminate_app
  arm_pensieve_restore_off
  open_smoke_app -n "$APP_PATH" || {
    sleep 0.5
    open_smoke_app -n "$APP_PATH"
  }

  assert_settings_window_server_state 1 1 >/dev/null
  ax_state="$(run_settings_stage open-general)"
  printf '%s\n' "$ax_state"
  first_settings_number="$(assert_settings_window_server_state 2 2 "$ax_state" | /usr/bin/tail -n 1)"

  ax_state="$(run_settings_stage repeat-general)"
  printf '%s\n' "$ax_state"
  repeated_settings_number="$(assert_settings_window_server_state 2 2 "$ax_state" | /usr/bin/tail -n 1)"
  [[ "$repeated_settings_number" == "$first_settings_number" ]] \
    || die "repeated Cmd+, replaced native Settings surface ($first_settings_number -> $repeated_settings_number)"

  run_settings_stage close-settings-with-launcher
  assert_settings_window_server_state 1 1 >/dev/null
  ax_state="$(run_settings_stage reopen-general)"
  printf '%s\n' "$ax_state"
  reopened_settings_number="$(assert_settings_window_server_state 2 2 "$ax_state" | /usr/bin/tail -n 1)"
  run_settings_stage close-settings-with-launcher
  assert_settings_window_server_state 1 1 >/dev/null
  run_settings_stage close-launcher
  assert_settings_window_server_state 0 0 >/dev/null

  ax_state="$(run_settings_stage open-general-zero)"
  printf '%s\n' "$ax_state"
  zero_document_settings_number="$(assert_settings_window_server_state 1 1 "$ax_state" | /usr/bin/tail -n 1)"
  run_settings_stage close-settings-zero
  assert_settings_window_server_state 0 0 >/dev/null
  # CGWindowNumber is a WindowServer presentation identifier, not an AppKit
  # object-identity token: closing and reopening one retained NSWindow may
  # legitimately allocate a new number. Compare it only while the surface is
  # continuously visible (the repeated Cmd+, assertion above), and record the
  # reopen numbers as bounded presentation evidence rather than equating them
  # with controller identity. Source-level tests prove retained NSWindow
  # identity; this runtime lane proves one surface and no post-close shell.
  log "SETTINGS_WINDOW_CG visible=$first_settings_number repeated=$repeated_settings_number reopened=$reopened_settings_number zeroDocument=$zero_document_settings_number"
  log "SETTINGS_WINDOW_RESULT=PASS (exact AX/CG states 1-2-2-1-2-1-0-1-0; same visible surface on repeated Cmd+,; clean close/reopen)"

  terminate_app 60 \
    || die "Settings lifecycle probe process survived its termination barrier"
}

run_settings_onboarding_transition_probe() {
  local ax_state ax_status=0 cg_status=0 guard_ready=0
  log "Settings onboarding transition probe (fresh capsule; native sheet detach gate)"
  terminate_app
  arm_pensieve_restore_off
  defaults write "$APP_ID" Pensieve.aiAutocompleteEnabled -bool true
  [[ "$(defaults read "$APP_ID" Pensieve.aiAutocompleteEnabled 2>/dev/null)" == "1" ]] \
    || die "could not arm AI onboarding in the fresh smoke domain"
  open_smoke_app -n "$APP_PATH" || {
    sleep 0.5
    open_smoke_app -n "$APP_PATH"
  }

  ax_state="$(run_settings_stage onboarding-before)"
  [[ "$ax_state" == "SETTINGS_ONBOARDING_BEFORE=PASS" ]] \
    || die "native onboarding precondition returned unexpected evidence: $ax_state"

  start_settings_onboarding_cg_guard \
    || die "could not start the exact-PID Settings onboarding CG guard"
  if wait_for_settings_onboarding_cg_ready; then
    guard_ready=1
  else
    local ready_status=$? reaper_status=0
    if stop_settings_onboarding_cg_guard; then
      :
    else
      reaper_status=$?
    fi
    die "Settings onboarding CG guard did not establish a stable runtime-derived baseline (status=$ready_status; reaper_status=$reaper_status)"
  fi

  if ax_state="$(run_settings_stage onboarding-block-command-settings)"; then
    [[ "$ax_state" == "SETTINGS_ONBOARDING_COMMAND_BLOCK_AX=PASS" ]] || ax_status=1
  else
    ax_status=$?
  fi
  if [[ "$guard_ready" -eq 1 ]]; then
    if finish_settings_onboarding_cg_guard; then
      cg_status=0
    else
      cg_status=$?
    fi
  fi
  if [[ "$ax_status" -ne 0 ]]; then
    [[ "$cg_status" -eq 0 ]] \
      || printf '\033[33m[ui]\033[0m secondary Settings CG guard failure status=%s\n' "$cg_status" >&2
    die "Cmd+, native-modal AX block failed (status=$ax_status; evidence=[$ax_state])"
  fi
  [[ "$cg_status" -eq 0 ]] \
    || die "Cmd+, changed the exact-PID layer-0 WindowServer surface set during concurrent sampling (status=$cg_status)"
  log "SETTINGS_ONBOARDING_COMMAND_BLOCK_RESULT=PASS (Cmd+, handled; exact status banner; stable 1s AX sheet; unchanged exact-PID CG tuple set sampled concurrently at ~25ms)"

  ax_state="$(run_settings_stage onboarding-configure)"
  printf '%s\n' "$ax_state"
  assert_settings_window_server_state 2 2 "$ax_state" >/dev/null
  run_settings_stage onboarding-close-settings
  assert_settings_window_server_state 1 1 >/dev/null
  log "SETTINGS_ONBOARDING_RESULT=PASS (blocked Cmd+, preserved native sheet and exact CG surface set; Configure detached the sheet before one AI Settings surface; no overlap observed during bounded AX polling)"

  terminate_app 60 \
    || die "Settings onboarding probe process survived its termination barrier"
}

clear_smoke_capsule_variables() {
  APP_ID=""
  RUN_TOKEN=""
  APP_NAME=""
  APP_PATH=""
  SMOKE_SUPPORT=""
  SMOKE_KEYCHAIN_SERVICE=""
  SMOKE_CAPSULE_ROOT=""
  IDENTITY_MANIFEST=""
  OWNED_PID=""
  EXECUTABLE_PATH=""
  SMOKE_SIGNING_MODE=""
  RESTORATION_DEFAULT_ARMED=0
  QAKW_WAS_SET=0
  PRIOR_QAKW=""
  PENSIEVE_RESTORE_DEFAULT_ARMED=0
  PENSIEVE_RESTORE_WAS_SET=0
  PRIOR_PENSIEVE_RESTORE=""
}

mint_smoke_capsule() {
  local minted_id capsule_root
  isolated_app_assert_canonical_directory "$SMOKE_ROOT" "UI-smoke invocation root" \
    || die "UI-smoke invocation root is not canonical"
  minted_id="$(isolated_app_generate_bundle_id smoke)" \
    || die "could not mint a new smoke scenario identity"

  # Assign the complete identity together. No caller may rotate APP_ID without
  # also rotating every derived process, bundle, support, Keychain and manifest
  # coordinate.
  APP_ID="$minted_id"
  RUN_TOKEN="${APP_ID##*.}"
  APP_NAME="Psmk${RUN_TOKEN:1}"
  SMOKE_KEYCHAIN_SERVICE="${APP_ID}.completion-provider"
  capsule_root="$SMOKE_ROOT/capsule-$RUN_TOKEN"
  /bin/mkdir "$capsule_root" || die "could not create smoke scenario capsule"
  SMOKE_CAPSULE_ROOT="$(cd -P "$capsule_root" && pwd -P)"
  IDENTITY_MANIFEST="$SMOKE_CAPSULE_ROOT/identity.plist"
  SMOKE_SUPPORT="$SMOKE_CAPSULE_ROOT/support"
  APP_PATH="$SMOKE_CAPSULE_ROOT/$APP_NAME.app"
  EXECUTABLE_PATH="$APP_PATH/Contents/MacOS/$APP_NAME"
  OWNED_PID=""
  SMOKE_SIGNING_MODE=""
  RESTORATION_DEFAULT_ARMED=0
  QAKW_WAS_SET=0
  PRIOR_QAKW=""
  PENSIEVE_RESTORE_DEFAULT_ARMED=0
  PENSIEVE_RESTORE_WAS_SET=0
  PRIOR_PENSIEVE_RESTORE=""

  isolated_app_reserve_manifest \
    "$IDENTITY_MANIFEST" "$SMOKE_CAPSULE_ROOT" "$SOURCE_APP_PATH" \
    "$APP_PATH" "$APP_NAME" "$APP_ID" "$APP_NAME" "$SMOKE_SUPPORT" \
    "$SMOKE_KEYCHAIN_SERVICE" "$SOURCE_COMMIT" \
    || die "could not reserve smoke scenario cleanup authority"
  /bin/mkdir "$SMOKE_SUPPORT" \
    || die "could not create canonical smoke scenario support directory"
  stage_smoke_app "$SOURCE_APP_PATH" "$APP_PATH" "$SMOKE_SUPPORT"
  isolated_app_finalize_manifest "$IDENTITY_MANIFEST" "$SMOKE_CAPSULE_ROOT" \
    || die "could not finalize smoke scenario identity manifest"
  isolated_app_verify_bundle_from_manifest \
    "$IDENTITY_MANIFEST" "$SMOKE_CAPSULE_ROOT" \
    || die "staged smoke scenario no longer matches its manifest"
  isolated_app_assert_profile_fresh \
    "$APP_ID" "$SMOKE_SUPPORT" "$SMOKE_KEYCHAIN_SERVICE" \
    || die "new smoke scenario identity was not empty: $APP_ID"
  log "minted scenario capsule id=$APP_ID root=$SMOKE_CAPSULE_ROOT"
}

retire_current_smoke_capsule() {
  local reason="${1:-scenario boundary}"
  [[ -n "${APP_ID:-}" ]] || return 0
  terminate_app 60 \
    || die "could not stop the exact smoke process at $reason; retained $SMOKE_CAPSULE_ROOT"
  disarm_restoration_default \
    || die "could not disarm smoke restoration state at $reason; retained $SMOKE_CAPSULE_ROOT"
  disarm_pensieve_restore_default \
    || die "could not disarm Pensieve restore state at $reason; retained $SMOKE_CAPSULE_ROOT"
  isolated_app_cleanup_manifest "$IDENTITY_MANIFEST" "$SMOKE_CAPSULE_ROOT" \
    || die "could not retire smoke capsule at $reason; retained $SMOKE_CAPSULE_ROOT and $IDENTITY_MANIFEST"
  clear_smoke_capsule_variables
}

rotate_smoke_capsule() {
  local reason="${1:-scenario boundary}"
  retire_current_smoke_capsule "$reason"
  mint_smoke_capsule
}

prepare_next_smoke_scenario() {
  local previous_scenario="${1:-previous scenario}"
  # The boundary baseline gets its own throwaway identity. The product
  # scenario that follows receives another UUID, so even writes triggered by
  # the baseline cannot be inputs to that scenario.
  rotate_smoke_capsule "retiring $previous_scenario"
  run_fresh_launcher_baseline_probe
  rotate_smoke_capsule "retiring the $previous_scenario boundary baseline"
}

prepare_first_smoke_scenario() {
  # The invocation begins with a freshly minted capsule. Use it only for the
  # boundary baseline, then retire it exactly like prepare_next_smoke_scenario
  # does. The first product scenario must never reuse a profile that the
  # baseline process has already opened or allowed background services to
  # write.
  run_fresh_launcher_baseline_probe
  rotate_smoke_capsule "retiring the initial fresh-profile boundary baseline"
}

# Decision 7A (Monika + Maciej, 2026-08-10): Pensieve is the sole
# owner of document-session restore. This probe creates the adversarial split:
# AppKit is explicitly told to preserve windows, while Pensieve's own restore
# setting is OFF. After a document-bearing quit/relaunch, exactly one empty
# launcher may exist and the seeded document title must be absent.
#
# The legacy --menu-restored-only flag is retained as a compatible entry point,
# but now runs this stronger saved-state isolation assertion.
run_saved_state_isolation_probe() {
  log "Saved Application State isolation probe (Pensieve restore OFF)"
  arm_restoration_default
  arm_pensieve_restore_off
  terminate_app

  local document_title="${SMOKE_DOCUMENT##*/}" probe_pid
  document_title="${document_title%.md}"

  log "saved-state probe: launch #1 with document [$document_title]"
  open_smoke_app -a "$APP_PATH" "$SMOKE_DOCUMENT" || {
    sleep 0.5
    open_smoke_app -a "$APP_PATH" "$SMOKE_DOCUMENT"
  }

  probe_pid="$(authenticated_owned_pid)"
  run_ax_osascript 45 - "$probe_pid" "$APP_ID" "$document_title" <<'APPLESCRIPT'
property expectedBundleID : ""
on run argv
  set targetPID to (item 1 of argv) as integer
  set my expectedBundleID to item 2 of argv as text
  set documentTitle to item 3 of argv
  my waitForProcess(targetPID, 15)
  my waitForWindow(targetPID, 15)

    set appProcess to my processForPID(targetPID, expectedBundleID)
  if appProcess is missing value then error "exact smoke pid disappeared before saved-state precondition: " & targetPID
  tell application "System Events"
    tell appProcess
      set frontmost to true
      delay 0.5
      set allTitles to title of every window
    end tell
  end tell

  repeat with candidateTitle in allTitles
    if (candidateTitle as text) contains documentTitle then
      log "SAVED_STATE_PRECONDITION=PASS title=[" & (candidateTitle as text) & "]"
      return "document window established"
    end if
  end repeat
  error "saved-state probe precondition failed: no document window titled [" & documentTitle & "] in {" & my joined(allTitles, ",") & "}"
end run

on processForPID(targetPID, expectedBundleID)
  tell application "System Events"
    repeat with processRef in application processes
      set observedPID to missing value
      try
        set observedPID to unix id of processRef
      end try
      if observedPID is targetPID then
        try
          set observedBundleID to bundle identifier of processRef
        on error errorMessage
          error "could not read bundle identifier for pid=" & targetPID & ": " & errorMessage
        end try
        if observedBundleID is not expectedBundleID then
          error "pid=" & targetPID & " belongs to unexpected bundle=" & observedBundleID
        end if
        return processRef
      end if
    end repeat
  end tell
  return missing value
end processForPID

on waitForProcess(targetPID, timeoutSeconds)
  repeat with i from 1 to (timeoutSeconds * 10)
    if my processForPID(targetPID, expectedBundleID) is not missing value then return true
    delay 0.1
  end repeat
  error "Timed out waiting for pid=" & targetPID
end waitForProcess

on waitForWindow(targetPID, timeoutSeconds)
  repeat with i from 1 to (timeoutSeconds * 10)
    set appProcess to my processForPID(targetPID, expectedBundleID)
    if appProcess is not missing value then
      try
        tell application "System Events" to tell appProcess
          if (count of windows) > 0 then return true
        end tell
      end try
    end if
    delay 0.1
  end repeat
  error "Timed out waiting for a window"
end waitForWindow

on joined(itemsList, delimiter)
  set previousDelimiters to AppleScript's text item delimiters
  set AppleScript's text item delimiters to delimiter
  set joinedText to itemsList as text
  set AppleScript's text item delimiters to previousDelimiters
  return joinedText
end joined
APPLESCRIPT

  log "saved-state probe: graceful quit with AppKit restoration armed"
  terminate_app 60 \
    || die "saved-state probe: the seeded process survived the pre-relaunch termination barrier"

  log "saved-state probe: relaunch with Pensieve restore still OFF"
  open_smoke_app -a "$APP_PATH" || {
    sleep 0.5
    open_smoke_app -a "$APP_PATH"
  }
  probe_pid="$(authenticated_owned_pid)"
  run_ax_osascript 60 - "$probe_pid" "$APP_ID" "$document_title" <<'APPLESCRIPT'
property expectedBundleID : ""
on run argv
  set targetPID to (item 1 of argv) as integer
  set my expectedBundleID to item 2 of argv as text
  set forbiddenDocumentTitle to item 3 of argv
  my waitForProcess(targetPID, 15)
  my waitForWindow(targetPID, 15)

    set appProcess to my processForPID(targetPID, expectedBundleID)
  if appProcess is missing value then error "exact smoke pid disappeared before saved-state census: " & targetPID
  tell application "System Events"
    tell appProcess
      set frontmost to true
      delay 0.8
      set windowCount to count of windows
      set allTitles to title of every window
      set menuNames to name of every menu bar item of menu bar 1
    end tell
  end tell

  repeat with candidateTitle in allTitles
    if (candidateTitle as text) contains forbiddenDocumentTitle then
      error "Saved Application State resurrected document [" & (candidateTitle as text) & "] while Pensieve restore was OFF; windows={" & my joined(allTitles, ",") & "}"
    end if
  end repeat

  if windowCount is not 1 then
    error "restore OFF must yield exactly one launcher, got " & windowCount & " windows={" & my joined(allTitles, ",") & "}"
  end if

  set missingMenus to {}
  repeat with menuName in {"Mode", "Format", "Agents"}
    if menuNames does not contain (contents of menuName) then
      set end of missingMenus to (contents of menuName)
    end if
  end repeat
  if missingMenus is not {} then
    error "launcher menu bar missing custom menus {" & my joined(missingMenus, ",") & "}"
  end if

  log "SAVED_STATE_WINDOWS=" & my joined(allTitles, ",")
  log "SAVED_STATE_MENUBAR=" & my joined(menuNames, ",")
  log "SAVED_STATE_RESULT=PASS (one empty launcher; no AppKit-restored document)"
  return "Pensieve is the sole document-session restore owner"
end run

on processForPID(targetPID, expectedBundleID)
  tell application "System Events"
    repeat with processRef in application processes
      set observedPID to missing value
      try
        set observedPID to unix id of processRef
      end try
      if observedPID is targetPID then
        try
          set observedBundleID to bundle identifier of processRef
        on error errorMessage
          error "could not read bundle identifier for pid=" & targetPID & ": " & errorMessage
        end try
        if observedBundleID is not expectedBundleID then
          error "pid=" & targetPID & " belongs to unexpected bundle=" & observedBundleID
        end if
        return processRef
      end if
    end repeat
  end tell
  return missing value
end processForPID

on waitForProcess(targetPID, timeoutSeconds)
  repeat with i from 1 to (timeoutSeconds * 10)
    if my processForPID(targetPID, expectedBundleID) is not missing value then return true
    delay 0.1
  end repeat
  error "Timed out waiting for pid=" & targetPID
end waitForProcess

on waitForWindow(targetPID, timeoutSeconds)
  repeat with i from 1 to (timeoutSeconds * 10)
    set appProcess to my processForPID(targetPID, expectedBundleID)
    if appProcess is not missing value then
      try
        tell application "System Events" to tell appProcess
          if (count of windows) > 0 then return true
        end tell
      end try
    end if
    delay 0.1
  end repeat
  error "Timed out waiting for a window"
end waitForWindow

on joined(itemsList, delimiter)
  set previousDelimiters to AppleScript's text item delimiters
  set AppleScript's text item delimiters to delimiter
  set joinedText to itemsList as text
  set AppleScript's text item delimiters to previousDelimiters
  return joinedText
end joined
APPLESCRIPT
}

# Closing the final window intentionally leaves Pensieve alive with no windows.
# A later Finder/Open With event is nevertheless an explicit request for a
# document surface: it must create exactly one host immediately, rather than
# queueing the URL invisibly until an unrelated Dock reopen.
run_zero_window_external_open_probe() {
  log "zero-window external-open probe"
  terminate_app
  arm_pensieve_restore_off
  local probe_pid

  open_smoke_app -a "$APP_PATH" || {
    sleep 0.5
    open_smoke_app -a "$APP_PATH"
  }

  probe_pid="$(authenticated_owned_pid)"
  run_ax_osascript 45 - "$probe_pid" "$APP_ID" <<'APPLESCRIPT'
property expectedBundleID : ""
on run argv
  set targetPID to (item 1 of argv) as integer
  set my expectedBundleID to item 2 of argv as text
  my waitForProcess(targetPID, 15)
  my waitForWindow(targetPID, 15)

    set appProcess to my processForPID(targetPID, expectedBundleID)
  if appProcess is missing value then error "exact smoke pid disappeared before zero-window close: " & targetPID
  tell application "System Events" to tell appProcess
    set closeButton to first button of window 1 whose value of attribute "AXSubrole" is "AXCloseButton"
    perform action "AXPress" of closeButton
    repeat with i from 1 to 100
      if (count of windows) is 0 then exit repeat
      delay 0.1
    end repeat
    if (count of windows) is not 0 then
      error "closing the final launcher did not reach the zero-window state"
    end if
  end tell
end run

on processForPID(targetPID, expectedBundleID)
  tell application "System Events"
    repeat with processRef in application processes
      set observedPID to missing value
      try
        set observedPID to unix id of processRef
      end try
      if observedPID is targetPID then
        try
          set observedBundleID to bundle identifier of processRef
        on error errorMessage
          error "could not read bundle identifier for pid=" & targetPID & ": " & errorMessage
        end try
        if observedBundleID is not expectedBundleID then
          error "pid=" & targetPID & " belongs to unexpected bundle=" & observedBundleID
        end if
        return processRef
      end if
    end repeat
  end tell
  return missing value
end processForPID

on waitForProcess(targetPID, timeoutSeconds)
  repeat with i from 1 to (timeoutSeconds * 10)
    if my processForPID(targetPID, expectedBundleID) is not missing value then return true
    delay 0.1
  end repeat
  error "Timed out waiting for pid=" & targetPID
end waitForProcess

on waitForWindow(targetPID, timeoutSeconds)
  repeat with i from 1 to (timeoutSeconds * 10)
    set appProcess to my processForPID(targetPID, expectedBundleID)
    if appProcess is not missing value then
      try
        tell application "System Events" to tell appProcess
          if (count of windows) > 0 then return true
        end tell
      end try
    end if
    delay 0.1
  end repeat
  error "Timed out waiting for a window"
end waitForWindow
APPLESCRIPT

  verify_running_smoke_identity >/dev/null 2>&1 \
    || die "closing the final window terminated $APP_NAME instead of leaving a zero-window process"

  # `open` can return -600 while LaunchServices is reconnecting to a just-
  # windowless process even when the event is delivered. The AX assertion below
  # is the source of truth; do not retry and risk sending the same URL twice.
  open_smoke_app -a "$APP_PATH" "$SMOKE_EXTERNAL_DOCUMENT" >/dev/null 2>&1 || true

  local external_title="${SMOKE_EXTERNAL_DOCUMENT##*/}"
  external_title="${external_title%.md}"
  probe_pid="$(authenticated_owned_pid)"
  run_ax_osascript 45 - "$probe_pid" "$APP_ID" "$external_title" <<'APPLESCRIPT'
property expectedBundleID : ""
on run argv
  set targetPID to (item 1 of argv) as integer
  set my expectedBundleID to item 2 of argv as text
  set documentTitle to item 3 of argv
  my waitForProcess(targetPID, 15)
  my waitForWindow(targetPID, 15)

    set appProcess to my processForPID(targetPID, expectedBundleID)
  if appProcess is missing value then error "exact smoke pid disappeared before external-open census: " & targetPID
  tell application "System Events" to tell appProcess
    set windowCount to count of windows
    set allTitles to title of every window
  end tell
  if windowCount is not 1 then
    error "external open from zero windows created " & windowCount & " windows={" & my joined(allTitles, ",") & "}"
  end if
  if (item 1 of allTitles as text) does not contain documentTitle then
    error "external open created a window but did not show [" & documentTitle & "]; windows={" & my joined(allTitles, ",") & "}"
  end if
  log "ZERO_WINDOW_EXTERNAL_OPEN=PASS title=[" & (item 1 of allTitles as text) & "]"
end run

on processForPID(targetPID, expectedBundleID)
  tell application "System Events"
    repeat with processRef in application processes
      set observedPID to missing value
      try
        set observedPID to unix id of processRef
      end try
      if observedPID is targetPID then
        try
          set observedBundleID to bundle identifier of processRef
        on error errorMessage
          error "could not read bundle identifier for pid=" & targetPID & ": " & errorMessage
        end try
        if observedBundleID is not expectedBundleID then
          error "pid=" & targetPID & " belongs to unexpected bundle=" & observedBundleID
        end if
        return processRef
      end if
    end repeat
  end tell
  return missing value
end processForPID

on waitForProcess(targetPID, timeoutSeconds)
  repeat with i from 1 to (timeoutSeconds * 10)
    if my processForPID(targetPID, expectedBundleID) is not missing value then return true
    delay 0.1
  end repeat
  error "Timed out waiting for pid=" & targetPID
end waitForProcess

on waitForWindow(targetPID, timeoutSeconds)
  repeat with i from 1 to (timeoutSeconds * 10)
    set appProcess to my processForPID(targetPID, expectedBundleID)
    if appProcess is not missing value then
      try
        tell application "System Events" to tell appProcess
          if (count of windows) > 0 then return true
        end tell
      end try
    end if
    delay 0.1
  end repeat
  error "Timed out waiting for a window"
end waitForWindow

on joined(itemsList, delimiter)
  set previousDelimiters to AppleScript's text item delimiters
  set AppleScript's text item delimiters to delimiter
  set joinedText to itemsList as text
  set AppleScript's text item delimiters to previousDelimiters
  return joinedText
end joined
APPLESCRIPT
}

# The same zero-window external open, with Pensieve's OWN startup restore ON.
#
# `run_zero_window_external_open_probe` runs with restore OFF, so the launch it
# exercises never reopens a working set — and the branch that decides what a
# launch owes the operator reads BOTH the intent and that setting
# (`AppController`: `intent != .coldLaunch || launchSettings.restoreSession-
# OnLaunch`). With restore ON the same external open arrives at a process that
# has already populated itself once, which is the combination no probe covered:
# a restore that consumed the launch could leave the Finder's document with no
# window at all, or bring the restored session back on top of it.
#
# Two launches, which is the floor for a restore scenario: one to seed a
# restorable working set, one to restore it. The external open itself is an
# event to the ALREADY RUNNING process, not a third launch.
run_restore_on_external_open_probe() {
  log "restore-ON external-open probe"
  terminate_app
  reset_smoke_working_set
  arm_pensieve_restore_on

  local document_title="${SMOKE_RESTORE_DOCUMENT##*/}" probe_pid
  document_title="${document_title%.md}"
  local external_title="${SMOKE_EXTERNAL_DOCUMENT##*/}"
  external_title="${external_title%.md}"

  log "restore-ON probe: launch #1 seeds a restorable session with [$document_title]"
  open_smoke_app -a "$APP_PATH" "$SMOKE_RESTORE_DOCUMENT" || {
    sleep 0.5
    open_smoke_app -a "$APP_PATH" "$SMOKE_RESTORE_DOCUMENT"
  }
  probe_pid="$(authenticated_owned_pid)"
  run_ax_osascript 45 - "$probe_pid" "$APP_ID" "$document_title" <<'APPLESCRIPT'
property expectedBundleID : ""
on run argv
  set targetPID to (item 1 of argv) as integer
  set my expectedBundleID to item 2 of argv as text
  set documentTitle to item 3 of argv
  my waitForProcess(targetPID, 15)
  my waitForWindow(targetPID, 15)

    set appProcess to my processForPID(targetPID, expectedBundleID)
  if appProcess is missing value then error "exact smoke pid disappeared before restore seed census: " & targetPID
  tell application "System Events"
    tell appProcess
      set frontmost to true
      delay 0.5
      set allTitles to title of every window
    end tell
  end tell

  repeat with candidateTitle in allTitles
    if (candidateTitle as text) contains documentTitle then
      log "RESTORE_ON_SEED=PASS title=[" & (candidateTitle as text) & "]"
      return "seeded"
    end if
  end repeat
  error "restore-ON probe: nothing to restore — no window titled [" & documentTitle & "] in {" & my joined(allTitles, ",") & "}"
end run

on processForPID(targetPID, expectedBundleID)
  tell application "System Events"
    repeat with processRef in application processes
      set observedPID to missing value
      try
        set observedPID to unix id of processRef
      end try
      if observedPID is targetPID then
        try
          set observedBundleID to bundle identifier of processRef
        on error errorMessage
          error "could not read bundle identifier for pid=" & targetPID & ": " & errorMessage
        end try
        if observedBundleID is not expectedBundleID then
          error "pid=" & targetPID & " belongs to unexpected bundle=" & observedBundleID
        end if
        return processRef
      end if
    end repeat
  end tell
  return missing value
end processForPID

on waitForProcess(targetPID, timeoutSeconds)
  repeat with i from 1 to (timeoutSeconds * 10)
    if my processForPID(targetPID, expectedBundleID) is not missing value then return true
    delay 0.1
  end repeat
  error "Timed out waiting for pid=" & targetPID
end waitForProcess

on waitForWindow(targetPID, timeoutSeconds)
  repeat with i from 1 to (timeoutSeconds * 10)
    set appProcess to my processForPID(targetPID, expectedBundleID)
    if appProcess is not missing value then
      try
        tell application "System Events" to tell appProcess
          if (count of windows) > 0 then return true
        end tell
      end try
    end if
    delay 0.1
  end repeat
  error "Timed out waiting for a window"
end waitForWindow

on joined(itemsList, delimiter)
  set previousDelimiters to AppleScript's text item delimiters
  set AppleScript's text item delimiters to delimiter
  set joinedText to itemsList as text
  set AppleScript's text item delimiters to previousDelimiters
  return joinedText
end joined
APPLESCRIPT

  log "restore-ON probe: graceful quit, then relaunch with restore ON"
  terminate_app 60 \
    || die "restore-ON probe: the seeded process survived the pre-relaunch termination barrier"

  open_smoke_app -a "$APP_PATH" || {
    sleep 0.5
    open_smoke_app -a "$APP_PATH"
  }
  # The relaunch has to prove the restore actually fired before the zero-window
  # state means anything: a session that never came back would leave the rest of
  # this probe testing the restore-OFF path under a restore-ON default.
  probe_pid="$(authenticated_owned_pid)"
  run_ax_osascript 60 - "$probe_pid" "$APP_ID" "$document_title" <<'APPLESCRIPT'
property expectedBundleID : ""
on run argv
  set targetPID to (item 1 of argv) as integer
  set my expectedBundleID to item 2 of argv as text
  set documentTitle to item 3 of argv
  my waitForProcess(targetPID, 15)
  my waitForWindow(targetPID, 15)

    set appProcess to my processForPID(targetPID, expectedBundleID)
  if appProcess is missing value then error "exact smoke pid disappeared before restore relaunch census: " & targetPID
  tell application "System Events"
    tell appProcess
      set frontmost to true
      delay 0.8
      set allTitles to title of every window
    end tell
  end tell

  set restoredIt to false
  repeat with candidateTitle in allTitles
    if (candidateTitle as text) contains documentTitle then set restoredIt to true
  end repeat
  if not restoredIt then
    error "restore ON did not reopen [" & documentTitle & "]; windows={" & my joined(allTitles, ",") & "}"
  end if
  log "RESTORE_ON_RELAUNCH=PASS windows={" & my joined(allTitles, ",") & "}"

  -- Down to zero windows, one close at a time. The restored documents are
  -- untouched since they were written by this script, so no save sheet can
  -- interrupt the walk.
    set appProcess to my processForPID(targetPID, expectedBundleID)
  if appProcess is missing value then error "exact smoke pid disappeared before restored-window close: " & targetPID
  tell application "System Events" to tell appProcess
    repeat with i from 1 to 40
      if (count of windows) is 0 then exit repeat
      set closeButton to first button of window 1 whose value of attribute "AXSubrole" is "AXCloseButton"
      perform action "AXPress" of closeButton
      delay 0.25
    end repeat
    if (count of windows) is not 0 then
      error "closing every restored window did not reach the zero-window state; left {" & my joined((title of every window), ",") & "}"
    end if
  end tell
end run

on processForPID(targetPID, expectedBundleID)
  tell application "System Events"
    repeat with processRef in application processes
      set observedPID to missing value
      try
        set observedPID to unix id of processRef
      end try
      if observedPID is targetPID then
        try
          set observedBundleID to bundle identifier of processRef
        on error errorMessage
          error "could not read bundle identifier for pid=" & targetPID & ": " & errorMessage
        end try
        if observedBundleID is not expectedBundleID then
          error "pid=" & targetPID & " belongs to unexpected bundle=" & observedBundleID
        end if
        return processRef
      end if
    end repeat
  end tell
  return missing value
end processForPID

on waitForProcess(targetPID, timeoutSeconds)
  repeat with i from 1 to (timeoutSeconds * 10)
    if my processForPID(targetPID, expectedBundleID) is not missing value then return true
    delay 0.1
  end repeat
  error "Timed out waiting for pid=" & targetPID
end waitForProcess

on waitForWindow(targetPID, timeoutSeconds)
  repeat with i from 1 to (timeoutSeconds * 10)
    set appProcess to my processForPID(targetPID, expectedBundleID)
    if appProcess is not missing value then
      try
        tell application "System Events" to tell appProcess
          if (count of windows) > 0 then return true
        end tell
      end try
    end if
    delay 0.1
  end repeat
  error "Timed out waiting for a window"
end waitForWindow

on joined(itemsList, delimiter)
  set previousDelimiters to AppleScript's text item delimiters
  set AppleScript's text item delimiters to delimiter
  set joinedText to itemsList as text
  set AppleScript's text item delimiters to previousDelimiters
  return joinedText
end joined
APPLESCRIPT

  verify_running_smoke_identity >/dev/null 2>&1 \
    || die "restore-ON probe: closing the restored windows terminated $APP_NAME instead of leaving a zero-window process"

  # Same caveat as the restore-OFF probe: `open` can report -600 while
  # LaunchServices reconnects to a windowless process that still receives the
  # event. The AX assertion below is the source of truth; never retry the send.
  open_smoke_app -a "$APP_PATH" "$SMOKE_EXTERNAL_DOCUMENT" >/dev/null 2>&1 || true

  probe_pid="$(authenticated_owned_pid)"
  run_ax_osascript 45 - "$probe_pid" "$APP_ID" "$external_title" "$document_title" <<'APPLESCRIPT'
property expectedBundleID : ""
on run argv
  set targetPID to (item 1 of argv) as integer
  set my expectedBundleID to item 2 of argv as text
  set documentTitle to item 3 of argv
  set restoredTitle to item 4 of argv
  my waitForProcess(targetPID, 15)
  my waitForWindow(targetPID, 15)

    set appProcess to my processForPID(targetPID, expectedBundleID)
  if appProcess is missing value then error "exact smoke pid disappeared before restore-on external-open census: " & targetPID
  tell application "System Events" to tell appProcess
    set windowCount to count of windows
    set allTitles to title of every window
  end tell
  if windowCount is not 1 then
    error "external open from zero windows with restore ON created " & windowCount & " windows={" & my joined(allTitles, ",") & "}"
  end if
  if (item 1 of allTitles as text) contains restoredTitle then
    error "the restored session came back on top of the external open: window shows [" & (item 1 of allTitles as text) & "] instead of [" & documentTitle & "]"
  end if
  if (item 1 of allTitles as text) does not contain documentTitle then
    error "external open with restore ON created a window but did not show [" & documentTitle & "]; windows={" & my joined(allTitles, ",") & "}"
  end if
  log "RESTORE_ON_EXTERNAL_OPEN=PASS title=[" & (item 1 of allTitles as text) & "]"
end run

on processForPID(targetPID, expectedBundleID)
  tell application "System Events"
    repeat with processRef in application processes
      set observedPID to missing value
      try
        set observedPID to unix id of processRef
      end try
      if observedPID is targetPID then
        try
          set observedBundleID to bundle identifier of processRef
        on error errorMessage
          error "could not read bundle identifier for pid=" & targetPID & ": " & errorMessage
        end try
        if observedBundleID is not expectedBundleID then
          error "pid=" & targetPID & " belongs to unexpected bundle=" & observedBundleID
        end if
        return processRef
      end if
    end repeat
  end tell
  return missing value
end processForPID

on waitForProcess(targetPID, timeoutSeconds)
  repeat with i from 1 to (timeoutSeconds * 10)
    if my processForPID(targetPID, expectedBundleID) is not missing value then return true
    delay 0.1
  end repeat
  error "Timed out waiting for pid=" & targetPID
end waitForProcess

on waitForWindow(targetPID, timeoutSeconds)
  repeat with i from 1 to (timeoutSeconds * 10)
    set appProcess to my processForPID(targetPID, expectedBundleID)
    if appProcess is not missing value then
      try
        tell application "System Events" to tell appProcess
          if (count of windows) > 0 then return true
        end tell
      end try
    end if
    delay 0.1
  end repeat
  error "Timed out waiting for a window"
end waitForWindow

on joined(itemsList, delimiter)
  set previousDelimiters to AppleScript's text item delimiters
  set AppleScript's text item delimiters to delimiter
  set joinedText to itemsList as text
  set AppleScript's text item delimiters to previousDelimiters
  return joinedText
end joined
APPLESCRIPT
}
if [[ $# -gt 0 && "$1" != --* ]]; then
  SOURCE_APP_PATH="$1"
  shift
fi

# Exit codes: 0 = pass; 1 = real FAIL (product/harness); 3 = environment
# inconclusive -- required TCC/desktop/watchdog evidence is unavailable rather
# than a genuine product census FAIL. Never treat 3 as a PASS; repair the named
# host precondition and rerun.
while [[ $# -gt 0 ]]; do
  case "$1" in
    --toolbar-cold-only)
      COLD_ONLY=1
      shift
      ;;
    --menu-restored-only)
      MENU_RESTORED_ONLY=1
      shift
      ;;
    --expect-toolbar-identifier)
      [[ $# -ge 2 ]] || die "--expect-toolbar-identifier requires a value"
      EXTRA_EXPECTED_IDENTIFIERS+=("$2")
      shift 2
      ;;
    *)
      die "Unknown argument: $1"
      ;;
  esac
done

[[ -d "$SOURCE_APP_PATH" ]] || die "App bundle not found: $SOURCE_APP_PATH (run make release-local or make release first)"

# Install cleanup before starting any process or creating any run-owned path.
# A failure while canonicalizing SOURCE_APP_PATH or allocating SMOKE_ROOT must
# not strand a caffeinate process that keeps the operator's display awake.
cleanup() {
  local cleanup_status=0
  local step_status=0
  local process_stopped=0
  local identity_cleaned=0
  # Stop the concurrent WindowServer watcher before terminating the app. App
  # termination necessarily changes the census and must not be misreported as
  # a product regression or leave a Swift process behind after an AX failure.
  if stop_settings_onboarding_cg_guard; then
    :
  else
    step_status=$?
    cleanup_status="$step_status"
  fi
  if [[ -n "${CAFFEINATE_PID:-}" ]]; then
    kill "$CAFFEINATE_PID" 2>/dev/null || true
  fi
  # Every exit path -- success, assertion failure, or an error raised inside
  # osascript -- must leave zero live smoke processes, otherwise the survivor
  # becomes the orphan that corrupts the next run's census.
  if [[ -z "${APP_ID:-}" ]]; then
    process_stopped=1
  elif terminate_app; then
    process_stopped=1
  else
    step_status=$?
    cleanup_status="$step_status"
    printf '\033[33m[ui]\033[0m exact smoke process could not be retired; preserving owner root for controlled retry: %s\n' \
      "${SMOKE_ROOT:-<not-created>}" >&2
  fi
  # Revert any smoke-domain defaults the saved-state probe armed. They were
  # never written to the operator's domain, but leaving it set would make the
  # next run's restoration state depend on the previous one.
  if [[ "$process_stopped" -eq 1 && -n "${APP_ID:-}" ]]; then
    disarm_restoration_default
    step_status=$?
    if [[ "$cleanup_status" -eq 0 && "$step_status" -ne 0 ]]; then
      cleanup_status="$step_status"
    fi
    disarm_pensieve_restore_default
    step_status=$?
    if [[ "$cleanup_status" -eq 0 && "$step_status" -ne 0 ]]; then
      cleanup_status="$step_status"
    fi
  fi
  # Retire the complete run identity while the staged bundle still exists:
  # defaults, Keychain, Open Recent, Saved State, caches/WebKit/HTTPStorages,
  # LaunchServices, isolated support and the bundle itself. The helper refuses
  # the production bundle id and every unscoped path.
  if [[ "$process_stopped" -eq 1 \
    && -n "${APP_ID:-}" && -n "${APP_PATH:-}" && -n "${SMOKE_SUPPORT:-}" ]]; then
    # Call the manifest cleanup even if SIGINT/SIGTERM interrupted the atomic
    # reservation before identity.plist was published. In that state the
    # helper is allowed to remove only its exact manifest temporary and an
    # otherwise-empty capsule; every other residue still fails closed.
    if [[ -n "${IDENTITY_MANIFEST:-}" ]] \
      && isolated_app_cleanup_manifest "$IDENTITY_MANIFEST" "$SMOKE_CAPSULE_ROOT"; then
      identity_cleaned=1
    else
      step_status=$?
      if [[ "$cleanup_status" -eq 0 ]]; then cleanup_status="$step_status"; fi
      printf '\033[33m[ui]\033[0m identity cleanup failed; preserving exact bundle + manifest for retry: %s %s\n' \
        "$APP_PATH" "${IDENTITY_MANIFEST:-<manifest-not-created>}" >&2
    fi
  elif [[ "$process_stopped" -eq 1 && -z "${APP_ID:-}" ]]; then
    identity_cleaned=1
  fi
  # The staged bundle, its Application Support tree and the witness document
  # all live under SMOKE_ROOT; the run owns that directory outright.
  if [[ "$identity_cleaned" -eq 1 \
    && -n "${SMOKE_ROOT:-}" && "$SMOKE_ROOT" == */pensieve-toolbar-smoke.* ]]; then
    /bin/rm -R "$SMOKE_ROOT"
    step_status=$?
    if [[ "$cleanup_status" -eq 0 && "$step_status" -ne 0 ]]; then
      cleanup_status="$step_status"
    fi
  elif [[ -n "${SMOKE_ROOT:-}" && -e "$SMOKE_ROOT" ]]; then
    printf '\033[33m[ui]\033[0m preserved smoke evidence root: %s\n' "$SMOKE_ROOT" >&2
  fi
  return "$cleanup_status"
}

# Bash 3.2 can replace a failing main-script status with the final successful
# command from an EXIT trap. Preserve the original status explicitly: a smoke
# that aborts before launching the app must never be reported as green merely
# because cleanup succeeded. An explicit signal trap also prevents a SIGINT or
# SIGTERM delivered to this script alone (rather than its process group) from
# falling through as a successful run.
on_exit() {
  local original_status="$?"
  local cleanup_status=0
  trap - EXIT INT TERM
  set +e
  cleanup
  cleanup_status=$?
  if [[ "$original_status" -ne 0 ]]; then
    exit "$original_status"
  fi
  exit "$cleanup_status"
}
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# A fresh profile is not truthful evidence if it drives a historical binary or
# a bundle built before uncommitted product-source changes. Keep those two
# exceptional cases independently opt-in so one override cannot weaken both
# provenance assertions.
SOURCE_APP_PATH="$(cd -P "$(dirname "$SOURCE_APP_PATH")" && pwd -P)/$(basename "$SOURCE_APP_PATH")"
SOURCE_COMMIT="$(isolated_app_assert_source_provenance \
  "$REPO_ROOT" "$SOURCE_APP_PATH" \
  "${PENSIEVE_UI_SMOKE_ALLOW_STALE_SOURCE:-0}" \
  "${PENSIEVE_UI_SMOKE_ALLOW_DIRTY_SOURCE:-0}")" \
  || die "source provenance check failed (rebuild from the current clean product sources)"

# TCC authority belongs to the terminal/process running this script. Prove the
# exact System Events route before compiling helpers, waking the display,
# minting a capsule, cleaning profile state, or launching Pensieve. A denied
# host is environment-inconclusive (3), with no smoke identity to clean up.
SYSTEM_EVENTS_PREFLIGHT_STATUS=0
isolated_app_assert_system_events_automation \
  || SYSTEM_EVENTS_PREFLIGHT_STATUS=$?
if [[ "$SYSTEM_EVENTS_PREFLIGHT_STATUS" -ne 0 ]]; then
  exit "$SYSTEM_EVENTS_PREFLIGHT_STATUS"
fi

if [[ $COLD_ONLY -eq 0 && $MENU_RESTORED_ONLY -eq 0 ]]; then
  NATIVE_TAB_AX_PROBE="$(native_tab_ax_probe_path)" \
    || die "native-tab AX probe could not be prepared"
fi

# Real AX clicks require the display to be awake; a sleeping display
# (displaysleep) makes popover clicks land randomly, so wake it now and
# hold it awake for the duration of the smoke to keep this deterministic
# on an unattended machine.
caffeinate -u -t 2 || true
caffeinate -dsu &
CAFFEINATE_PID=$!

SMOKE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/pensieve-toolbar-smoke.XXXXXX")"
SMOKE_ROOT="$(cd -P "$SMOKE_ROOT" && pwd -P)"
SMOKE_DOCUMENT="$SMOKE_ROOT/toolbar-cold.md"
SMOKE_EXTERNAL_DOCUMENT="$SMOKE_ROOT/external-after-zero-windows.md"
SMOKE_RESTORE_DOCUMENT="$SMOKE_ROOT/restore-on-seed.md"
mint_smoke_capsule

# The freshly minted baseline identity is already empty. Retire it once more
# before launch so even a queued daemon write from staging cannot become part
# of the baseline evidence.
terminate_app
reset_smoke_defaults_domain

EXPECTED_TOOLBAR_IDENTIFIERS=(
  pensieve.toolbar.share
  pensieve.toolbar.dispatchToAgent
  pensieve.toolbar.undo
  pensieve.toolbar.redo
  pensieve.toolbar.richMarkdownToggle
  pensieve.toolbar.format.bold
  pensieve.toolbar.format.strike
  pensieve.toolbar.format.italic
  pensieve.toolbar.format.quote
  pensieve.toolbar.format.code
  pensieve.toolbar.format.link
  pensieve.toolbar.format.bulletedList
  pensieve.toolbar.format.numberedList
  pensieve.toolbar.modePicker
  pensieve.toolbar.reload
  pensieve.toolbar.autoReload
  pensieve.toolbar.scrollSync
  pensieve.toolbar.dictationToggle
  pensieve.toolbar.autocompleteToggle
  pensieve.toolbar.aiRewrite
)
BASE_EXPECTED_IDENTIFIER_COUNT="${#EXPECTED_TOOLBAR_IDENTIFIERS[@]}"
# On macOS' Bash 3.2, expanding an explicitly declared but empty array under
# `set -u` is still an unbound-variable error. Guard the expansion itself.
if [[ "${#EXTRA_EXPECTED_IDENTIFIERS[@]}" -gt 0 ]]; then
  EXPECTED_TOOLBAR_IDENTIFIERS+=("${EXTRA_EXPECTED_IDENTIFIERS[@]}")
fi

BUNDLE_COMMIT="$(/usr/libexec/PlistBuddy -c 'Print :PensieveBuildCommit' "$APP_PATH/Contents/Info.plist")"
BUNDLE_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")"
BUNDLE_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_PATH/Contents/Info.plist")"
log "source bundle=$SOURCE_APP_PATH commit=$BUNDLE_COMMIT version=$BUNDLE_VERSION build=$BUNDLE_BUILD"
log "staged bundle=$APP_PATH executable=$EXECUTABLE_PATH id=$APP_ID signature=$SMOKE_SIGNING_MODE"
log "isolated support dir=$SMOKE_SUPPORT keychain=$SMOKE_KEYCHAIN_SERVICE"
log "identity manifest=$IDENTITY_MANIFEST"

prepare_first_smoke_scenario
stage_settings_lifecycle_script
run_settings_window_lifecycle_probe
ok "Settings window lifecycle probe passed"
prepare_next_smoke_scenario "Settings lifecycle scenario"
run_settings_onboarding_transition_probe
ok "Settings onboarding transition probe passed"
prepare_next_smoke_scenario "Settings onboarding transition scenario"

# Witnesses are created only after the clean UI baseline has passed and its
# capsule has been completely retired. Files that belong to a product scenario
# can therefore never influence the claim that the profile began empty.
printf '# Toolbar cold-frame witness\n\nEditable staged document.\n' >"$SMOKE_DOCUMENT"
printf '# External open after zero windows\n' >"$SMOKE_EXTERNAL_DOCUMENT"
printf '# Restore-ON seed\n' >"$SMOKE_RESTORE_DOCUMENT"

if [[ $MENU_RESTORED_ONLY -eq 1 ]]; then
  run_saved_state_isolation_probe
  ok "Saved Application State isolation probe passed"
  exit 0
fi

log "launching editable cold witness without post-launch activation"
# Pre-launch: guarantee no prior/orphaned instance survives, so `open -n` yields
# exactly one process named Pensieve and the bare-name census cannot lock onto a
# stale windowless survivor.
terminate_app
open_smoke_app -n -a "$APP_PATH" "$SMOKE_DOCUMENT" || {
  # LaunchServices can briefly retain the just-terminated bundle instance
  # and return -600 even after the process is gone. One bounded retry clears it.
  sleep 0.5
  open_smoke_app -n -a "$APP_PATH" "$SMOKE_DOCUMENT"
}

log "probing Accessibility surface"
ax_census_status=0
# The AppleScript body is written to a temp file BEFORE the osascript call
# rather than piped in via a heredoc inside this command substitution: bash
# 3.2 (the macOS system bash) cannot parse a heredoc containing an apostrophe
# (see "AppleScript's text item delimiters" below) when it sits inside
# $(...) -- it dies with "unexpected EOF while looking for matching `''" long
# before this script ever runs. Writing to a file first keeps the
# substitution itself heredoc-free.
# Inside SMOKE_ROOT, which the EXIT trap owns outright. Landing it in $TMPDIR
# instead meant every early exit -- an assertion failure, an error raised inside
# osascript, a Ctrl-C -- stranded the file, because cleanup() knows only about
# SMOKE_ROOT.
ax_census_script="$(mktemp "$SMOKE_ROOT/pensieve-ax-census.XXXXXX")"
cat >"$ax_census_script" <<'APPLESCRIPT'
property expectedBundleID : ""

on processForPID(targetPID, expectedBundleID)
  tell application "System Events"
    repeat with processRef in application processes
      set observedPID to missing value
      try
        set observedPID to unix id of processRef
      end try
      if observedPID is targetPID then
        try
          set observedBundleID to bundle identifier of processRef
        on error errorMessage
          error "could not read bundle identifier for pid=" & targetPID & ": " & errorMessage
        end try
        if observedBundleID is not expectedBundleID then
          error "pid=" & targetPID & " belongs to unexpected bundle=" & observedBundleID
        end if
        return processRef
      end if
    end repeat
  end tell
  return missing value
end processForPID

on waitForProcess(targetPID, timeoutSeconds)
  repeat with i from 1 to (timeoutSeconds * 10)
    if my processForPID(targetPID, expectedBundleID) is not missing value then return true
    delay 0.1
  end repeat
  error "Timed out waiting for pid=" & targetPID
end waitForProcess

on waitForWindow(targetPID, timeoutSeconds)
  repeat with i from 1 to (timeoutSeconds * 10)
    set appProcess to my processForPID(targetPID, expectedBundleID)
    if appProcess is not missing value then
      try
        tell application "System Events" to tell appProcess
          if (count of windows) > 0 then return true
        end tell
      end try
    end if
    delay 0.1
  end repeat
  error "Timed out waiting for a visible window"
end waitForWindow

on toolbarCensus(targetPID)
  -- Census the WINDOW UNDER TEST — always `window 1`, the frontmost/key window
  -- that receives the menu-driven mode changes and whose geometry the geometry
  -- assertions pin. The rest of this script already operates on `window 1`
  -- (geometry reads, the status-bar appearance chip lookup), so the census must
  -- follow the same window or it is measuring a different surface than the one
  -- being driven.
  --
  -- The earlier heuristic sampled every window and kept "the one with the most
  -- identifiers". macOS state restoration can reopen a sibling document window
  -- from a prior session; that sibling never receives the smoke's menu-driven
  -- mode change (the menu targets the key window only), so it stays in an
  -- editing mode. Once the toolbar is wide enough that its editing items no
  -- longer collapse into the overflow chevron, the sibling exposes undo/redo/
  -- format in the AX tree and — carrying more identifiers than the slimmed-down
  -- preview window under test — won the max-count census, so the preview-only
  -- assertion flagged editing items the tested window had correctly dropped.
  set census to {}
  try
    set appProcess to my processForPID(targetPID, expectedBundleID)
    if appProcess is missing value then return census
    tell application "System Events"
      tell appProcess
        set toolbarElements to entire contents of toolbar 1 of window 1
        repeat with elementRef in toolbarElements
          try
            set identifierValue to value of attribute "AXIdentifier" of elementRef
            if identifierValue is not missing value and identifierValue is not "" then
              set end of census to identifierValue as text
            end if
          end try
        end repeat
      end tell
    end tell
  end try
  return census
end toolbarCensus

on missingIdentifiers(census, expectedIdentifiers)
  set missingItems to {}
  repeat with expectedIdentifier in expectedIdentifiers
    if census does not contain (expectedIdentifier as text) then
      set end of missingItems to expectedIdentifier as text
    end if
  end repeat
  return missingItems
end missingIdentifiers

on identifiersExcluding(allIdentifiers, excludedIdentifiers)
  set includedIdentifiers to {}
  repeat with candidateIdentifier in allIdentifiers
    if excludedIdentifiers does not contain (candidateIdentifier as text) then
      set end of includedIdentifiers to candidateIdentifier as text
    end if
  end repeat
  return includedIdentifiers
end identifiersExcluding

on presentExcludedIdentifiers(census, excludedIdentifiers)
  set presentItems to {}
  repeat with excludedIdentifier in excludedIdentifiers
    if census contains (excludedIdentifier as text) then
      set end of presentItems to excludedIdentifier as text
    end if
  end repeat
  return presentItems
end presentExcludedIdentifiers

on assertWindowGeometry(targetPID, expectedPosition, expectedSize, stateName)
    set appProcess to my processForPID(targetPID, expectedBundleID)
  if appProcess is missing value then error "exact smoke pid disappeared before geometry assertion: " & targetPID
  tell application "System Events" to tell appProcess
    set actualPosition to position of window 1
    set actualSize to size of window 1
  end tell
  if actualPosition is not equal to expectedPosition or actualSize is not equal to expectedSize then
    error stateName & " changed window geometry"
  end if
end assertWindowGeometry

on joined(itemsList, delimiter)
  set previousDelimiters to AppleScript's text item delimiters
  set AppleScript's text item delimiters to delimiter
  set joinedText to itemsList as text
  set AppleScript's text item delimiters to previousDelimiters
  return joinedText
end joined

-- Settlement requires expected identifiers present AND excluded identifiers
-- absent SIMULTANEOUSLY, holding across at least two consecutive reads. A
-- single matching read is not enough: an asynchronous mode transition can
-- hand back a stale census that happens to satisfy presence one tick before
-- the excluded (e.g. editing) controls actually tear down, which let a
-- later, separate absence check race a still-settling toolbar and either
-- false-pass on a stale-but-matching read or false-fail on a torn-down-but-
-- not-yet-observed one. Pass an empty excludedIdentifiers list when a state
-- has nothing to exclude.
on settledToolbarCensus(targetPID, expectedIdentifiers, excludedIdentifiers, timeoutTenths)
  set stableCount to 0
  set latestCensus to {}
  set latestMissing to {}
  set latestUnexpected to {}
  repeat with i from 1 to timeoutTenths
    set latestCensus to my toolbarCensus(targetPID)
    set latestMissing to my missingIdentifiers(latestCensus, expectedIdentifiers)
    set latestUnexpected to my presentExcludedIdentifiers(latestCensus, excludedIdentifiers)
    if (latestMissing is {}) and (latestUnexpected is {}) then
      set stableCount to stableCount + 1
      if stableCount >= 2 then return latestCensus
    else
      set stableCount to 0
    end if
    delay 0.1
  end repeat
  if (count of latestCensus) is 0 then
    -- Machine-readable classification for the bash-side WindowServer check.
    -- Keep it independent of the human error prose below.
    error "PENSIEVE_AX_EMPTY_CENSUS"
  end if
  if (count of latestUnexpected) > 0 then
    error "Toolbar census unexpectedly exposes: " & my joined(latestUnexpected, ", ") & ¬
      "; observed: " & my joined(latestCensus, ", ")
  end if
  error "Cold toolbar census missing identifiers: " & my joined(latestMissing, ", ") & ¬
    "; observed: " & my joined(latestCensus, ", ")
end settledToolbarCensus

on assertMenuItem(targetPID, menuName, itemName)
    set appProcess to my processForPID(targetPID, expectedBundleID)
  if appProcess is missing value then error "exact smoke pid disappeared before menu assertion: " & targetPID
  tell application "System Events"
    tell appProcess
      tell menu bar 1
        tell menu bar item menuName
          if not (exists menu item itemName of menu 1) then
            error "Missing menu item: " & menuName & " > " & itemName
          end if
        end tell
      end tell
    end tell
  end tell
end assertMenuItem

on exactProcessDiagnostics(targetPID)
  set appProcess to my processForPID(targetPID, expectedBundleID)
  if appProcess is missing value then return "process=missing"
  try
    tell application "System Events" to tell appProcess
      set observedBundle to bundle identifier as text
      set observedFrontmost to frontmost as text
      set observedWindowCount to (count of windows) as text
      set observedMenus to name of every menu bar item of menu bar 1
    end tell
    return "bundle=" & observedBundle & "; frontmost=" & observedFrontmost & ¬
      "; windows=" & observedWindowCount & "; menus=" & my joined(observedMenus, ",")
  on error errorMessage number errorNumber
    return "diagnostics-error=" & errorNumber & ":" & errorMessage
  end try
end exactProcessDiagnostics

on clickExactMenuItem(targetPID, menuName, itemName)
  set latestError to "process unavailable"
  repeat with attemptNumber from 1 to 10
    set appProcess to my processForPID(targetPID, expectedBundleID)
    if appProcess is not missing value then
      try
        tell application "System Events" to tell appProcess
          tell menu bar 1 to tell menu bar item menuName
            click
            delay 0.2
            if not (exists menu item itemName of menu 1) then
              error "missing menu item " & itemName
            end if
            click menu item itemName of menu 1
          end tell
        end tell
        return true
      on error errorMessage number errorNumber
        set latestError to errorNumber & ":" & errorMessage
      end try
    end if
    delay 0.2
  end repeat
  error "Could not choose " & menuName & " > " & itemName & ¬
    " for pid=" & targetPID & "; last=" & latestError & "; " & ¬
    my exactProcessDiagnostics(targetPID)
end clickExactMenuItem

on exactWindowGeometry(targetPID)
  set appProcess to my processForPID(targetPID, expectedBundleID)
  if appProcess is missing value then error "exact smoke pid disappeared before geometry read: " & targetPID
  tell application "System Events" to tell appProcess
    return {position of window 1, size of window 1}
  end tell
end exactWindowGeometry

on activateExactProcess(targetPID)
  set appProcess to my processForPID(targetPID, expectedBundleID)
  if appProcess is missing value then error "exact smoke pid disappeared before activation: " & targetPID
  tell application "System Events" to set frontmost of appProcess to true
end activateExactProcess

on raiseExactProcessWindow(targetPID)
  set appProcess to my processForPID(targetPID, expectedBundleID)
  if appProcess is missing value then error "exact smoke pid disappeared before raise: " & targetPID
  tell application "System Events" to tell appProcess
    perform action "AXRaise" of window 1
  end tell
end raiseExactProcessWindow

on exactWindowCount(targetPID)
  set appProcess to my processForPID(targetPID, expectedBundleID)
  if appProcess is missing value then error "exact smoke pid disappeared before window count: " & targetPID
  tell application "System Events" to tell appProcess
    return count of windows
  end tell
end exactWindowCount

on namedToolbarElementIn(elementsToSearch, targetName, targetIdentifier)
  repeat with elementRef in elementsToSearch
    set elementDescription to ""
    set elementTitle to ""
    set elementIdentifier to ""
    tell application "System Events"
      try
        set elementDescription to get description of elementRef
      end try
      try
        set elementTitle to get title of elementRef
      end try
      try
        set elementIdentifier to (value of attribute "AXIdentifier" of elementRef) as text
      end try
    end tell
    -- macOS 27 exposes native SwiftUI toolbar menu names through AXTitle while
    -- AXDescription remains the generic "menu button". Older bridges used
    -- AXDescription. Require the exact authored name in either standard
    -- accessible-name slot so a raw symbol name or an anonymous menu still
    -- fails this assertion.
    if elementIdentifier is targetIdentifier and ¬
      (elementDescription is targetName or elementTitle is targetName) then
      return contents of elementRef
    end if
  end repeat
  return missing value
end namedToolbarElementIn

on toolbarElementByAccessibleNameOnce(targetPID, targetName, targetIdentifier)
  set appProcess to my processForPID(targetPID, expectedBundleID)
  if appProcess is missing value then return missing value
  tell application "System Events"
    tell appProcess
      -- Keep this lookup bounded to the native toolbar. Walking the entire
      -- document window traverses the editor and WebKit preview trees and can
      -- exceed the outer AX timeout while a SwiftUI toolbar is rehosting. A
      -- transiently empty toolbar is handled by the caller's bounded retry.
      try
        return my namedToolbarElementIn(¬
          entire contents of toolbar 1 of window 1, targetName, targetIdentifier)
      end try
    end tell
  end tell
  return missing value
end toolbarElementByAccessibleNameOnce

on toolbarElementByAccessibleName(targetPID, targetName, targetIdentifier)
  -- AX attribute propagation can lag behind the identifier-based toolbar
  -- census: a control can exist (and already show up by identifier) before
  -- its localized accessible name is queryable. Retry with a bounded backoff
  -- instead of failing on the first miss.
  repeat with attemptNumber from 1 to 5
    set elementRef to my toolbarElementByAccessibleNameOnce(targetPID, targetName, targetIdentifier)
    if elementRef is not missing value then return elementRef
    if attemptNumber < 5 then delay 1
  end repeat
  error "Missing toolbar control with accessible name/identifier: " & ¬
    targetName & "/" & targetIdentifier
end toolbarElementByAccessibleName

on toolbarMenuItemsAfterSinglePress(targetPID, targetName, targetIdentifier, expectedMenuItems, allowDisabled, timeoutTenths)
  set controlRef to my toolbarElementByAccessibleName(targetPID, targetName, targetIdentifier)
  tell application "System Events"
    set observedRole to role of controlRef
    if observedRole is not "AXMenuButton" then
      error targetName & " must be a native menu button, got " & observedRole
    end if
    if not (enabled of controlRef) then
      if allowDisabled then return {{}, 0, false}
      error targetName & " is disabled"
    end if
    set observedActions to name of every action of controlRef
    if observedActions does not contain "AXPress" then
      error targetName & " does not expose AXPress; actions={" & my joined(observedActions, ",") & "}"
    end if

    -- Exactly ONE semantic press. Repeating the action would hide a real
    -- product defect where the first click is swallowed. Only the subsequent
    -- AX publication is allowed to settle below.
    perform action "AXPress" of controlRef
  end tell

  set latestMenuItems to {}
  repeat with sampleNumber from 1 to timeoutTenths
    delay 0.1
    -- Native SwiftUI menus may rehost their toolbar item while opening. Read
    -- the menu from a freshly resolved exact-PID control instead of retaining
    -- the positional System Events ref used for the press.
    set freshControl to my toolbarElementByAccessibleNameOnce(¬
      targetPID, targetName, targetIdentifier)
    if freshControl is not missing value then
      tell application "System Events"
        try
          if (count of menus of freshControl) > 0 then
            set latestMenuItems to name of every menu item of menu 1 of freshControl
            set hasAllExpectedItems to true
            repeat with expectedItem in expectedMenuItems
              if latestMenuItems does not contain (expectedItem as text) then
                set hasAllExpectedItems to false
                exit repeat
              end if
            end repeat
            if hasAllExpectedItems then
              return {latestMenuItems, sampleNumber * 100, true}
            end if
          end if
        end try
      end tell
    end if
  end repeat

  error targetName & " menu did not publish expected items={" & ¬
    my joined(expectedMenuItems, ",") & "} after one AXPress and " & ¬
    (timeoutTenths * 100) & "ms of fresh-ref polling; observed={" & ¬
    my joined(latestMenuItems, ",") & "}; " & my exactProcessDiagnostics(targetPID)
end toolbarMenuItemsAfterSinglePress

on windowElementByIdentifierOnce(targetPID, targetIdentifier)
  set appProcess to my processForPID(targetPID, expectedBundleID)
  if appProcess is missing value then return missing value
  tell application "System Events" to tell appProcess
    try
      set windowElements to entire contents of window 1
      repeat with elementRef in windowElements
        try
          set identifierValue to value of attribute "AXIdentifier" of elementRef
          if identifierValue is targetIdentifier then return contents of elementRef
        end try
      end repeat
    end try
  end tell
  return missing value
end windowElementByIdentifierOnce

on windowElementByIdentifier(targetPID, targetIdentifier, timeoutTenths)
  repeat with attemptNumber from 1 to timeoutTenths
    set elementRef to my windowElementByIdentifierOnce(targetPID, targetIdentifier)
    if elementRef is not missing value then return contents of elementRef
    delay 0.1
  end repeat
  error "Timed out waiting for window element: " & targetIdentifier
end windowElementByIdentifier

-- The window-body counterpart of `toolbarMenuItemsAfterSinglePress`, for the
-- status bar's appearance chip.
--
-- Two differences from the toolbar helper, both forced by where this control
-- lives. The lookup walks the WINDOW rather than `toolbar 1`, because the chip
-- is part of the document body and no toolbar traversal can reach it. And the
-- lookup is by IDENTIFIER only: the toolbar helper cross-checks an accessible
-- name because a toolbar item bridged out of a `ControlGroup` silently loses
-- its label, which is a failure mode a status-bar control declared inline does
-- not have.
on statusBarMenuItemsAfterSinglePress(targetPID, targetName, targetIdentifier, expectedMenuItems, timeoutTenths)
  set controlRef to my windowElementByIdentifier(targetPID, targetIdentifier, 50)
  tell application "System Events"
    -- SwiftUI's borderless `Menu` bridges to an AppKit pop-up button, which AX
    -- publishes as AXMenuButton or AXPopUpButton depending on the release.
    -- Both are one-press menu controls; anything else means the chip stopped
    -- being a menu and became decoration.
    set observedRole to role of controlRef
    if observedRole is not "AXMenuButton" and observedRole is not "AXPopUpButton" then
      error targetName & " must be a native menu control, got " & observedRole
    end if
    if not (enabled of controlRef) then error targetName & " is disabled"
    set observedActions to name of every action of controlRef
    if observedActions does not contain "AXPress" then
      error targetName & " does not expose AXPress; actions={" & ¬
        my joined(observedActions, ",") & "}"
    end if

    -- Exactly ONE semantic press, for the same reason the toolbar helper
    -- presses once: a repeat would hide a first click the product swallowed.
    perform action "AXPress" of controlRef
  end tell

  set latestMenuItems to {}
  repeat with sampleNumber from 1 to timeoutTenths
    delay 0.1
    set freshControl to my windowElementByIdentifierOnce(targetPID, targetIdentifier)
    if freshControl is not missing value then
      tell application "System Events"
        try
          if (count of menus of freshControl) > 0 then
            set latestMenuItems to name of every menu item of menu 1 of freshControl
            set hasAllExpectedItems to true
            repeat with expectedItem in expectedMenuItems
              if latestMenuItems does not contain (expectedItem as text) then
                set hasAllExpectedItems to false
                exit repeat
              end if
            end repeat
            if hasAllExpectedItems then return {latestMenuItems, sampleNumber * 100}
          end if
        end try
      end tell
    end if
  end repeat

  error targetName & " menu did not publish expected items={" & ¬
    my joined(expectedMenuItems, ",") & "} after one AXPress and " & ¬
    (timeoutTenths * 100) & "ms of fresh-ref polling; observed={" & ¬
    my joined(latestMenuItems, ",") & "}; " & my exactProcessDiagnostics(targetPID)
end statusBarMenuItemsAfterSinglePress

on run argv
set targetPID to item 1 of argv as integer
set my expectedBundleID to item 2 of argv as text
set coldOnly to item 3 of argv is "1"
set baseExpectedCount to item 4 of argv as integer
set expectedIdentifiers to items 5 thru -1 of argv
set baseExpectedIdentifiers to items 5 thru (4 + baseExpectedCount) of argv
my waitForProcess(targetPID, 12)
my waitForWindow(targetPID, 12)

-- The shell resolved and authenticated this PID from bundle id, bundle path
-- and executable path immediately before invoking this script. AppleScript
-- never derives process authority from a display name.
    set appProcess to my processForPID(targetPID, expectedBundleID)
if appProcess is missing value then error "exact smoke pid disappeared before AX census: " & targetPID

-- NO-STIMULUS BOUNDARY: from process discovery through this census, the
-- harness only reads AX state and waits. It does not activate/focus the app,
-- click, move the pointer, resize, raise a menu, or mutate window geometry.
set coldCensus to my settledToolbarCensus(targetPID, baseExpectedIdentifiers, {}, 80)
set missingItems to my missingIdentifiers(coldCensus, expectedIdentifiers)
if (count of missingItems) > 0 then
  error "Cold toolbar census missing identifiers: " & my joined(missingItems, ", ") & ¬
    "; observed: " & my joined(coldCensus, ", ")
end if
set coldGeometry to my exactWindowGeometry(targetPID)
set coldPosition to item 1 of coldGeometry
set coldSize to item 2 of coldGeometry
log "NO_STIMULUS_BOUNDARY=process/window wait + AX reads only"
log "WINDOW_GEOMETRY=" & (item 1 of coldPosition) & "," & (item 2 of coldPosition) & "," & (item 1 of coldSize) & "," & (item 2 of coldSize)
log "AX_CENSUS=" & my joined(coldCensus, ",")
if coldOnly then return "cold toolbar AX census passed"

-- SwiftUI command groups publish focused-scene values only after the newly
-- launched window becomes active. A second bundle with the same identifier
-- may have been frontmost before the smoke killed it, so make focus explicit.
-- Activate the resolved PID directly rather than "tell application ... to
-- activate", which resolves the app by name through LaunchServices and can
-- target a different installed bundle than the one under test.
my activateExactProcess(targetPID)
delay 0.5

assertMenuItem(targetPID, "File", "New File")
assertMenuItem(targetPID, "File", "Open File…")
assertMenuItem(targetPID, "File", "Open Recent")
assertMenuItem(targetPID, "File", "Open Folder…")
assertMenuItem(targetPID, "File", "Close")
assertMenuItem(targetPID, "Mode", "Source Mode")
assertMenuItem(targetPID, "Mode", "Split Mode")
assertMenuItem(targetPID, "Format", "Bold")
assertMenuItem(targetPID, "Format", "Link")
-- Dispatch entry points are menu rows that only open the confirmation sheet
-- (W3-A gateway); their presence in the menu bar is part of the P0 contract.
assertMenuItem(targetPID, "Agents", "Dispatch Document to Agent…")
assertMenuItem(targetPID, "Agents", "Dispatch Document with Workflow")

set editingIdentifiers to {¬
  "pensieve.toolbar.undo", "pensieve.toolbar.redo", ¬
  "pensieve.toolbar.richMarkdownToggle", "pensieve.toolbar.format.bold", ¬
  "pensieve.toolbar.format.strike", "pensieve.toolbar.format.italic", ¬
  "pensieve.toolbar.format.quote", "pensieve.toolbar.format.code", ¬
  "pensieve.toolbar.format.link", "pensieve.toolbar.format.bulletedList", ¬
  "pensieve.toolbar.format.numberedList"}
set previewExpectedIdentifiers to my identifiersExcluding(baseExpectedIdentifiers, editingIdentifiers)

-- Resolve the exact PID afresh for every menu action. System Events returns
-- application-process refs as positional `item N` specifiers; retaining one
-- across WebKit process churn can silently retarget the next menu click.
my clickExactMenuItem(targetPID, "Mode", "Split Mode")
delay 0.5
set splitCensus to my settledToolbarCensus(targetPID, baseExpectedIdentifiers, {}, 40)
my assertWindowGeometry(targetPID, coldPosition, coldSize, "split transition")
log "AX_CENSUS_SPLIT=" & my joined(splitCensus, ",")

my clickExactMenuItem(targetPID, "Mode", "Preview Mode")
delay 0.5
set previewCensus to my settledToolbarCensus(targetPID, previewExpectedIdentifiers, editingIdentifiers, 40)
my assertWindowGeometry(targetPID, coldPosition, coldSize, "preview transition")
log "AX_CENSUS_PREVIEW=" & my joined(previewCensus, ",")

my clickExactMenuItem(targetPID, "Mode", "Split Mode")
delay 0.5
set splitCensus to my settledToolbarCensus(targetPID, baseExpectedIdentifiers, {}, 40)
my assertWindowGeometry(targetPID, coldPosition, coldSize, "split restore")

-- BOTH APPEARANCE AXES, AT THEIR ONLY HOME. The titlebar's appearance diamond
-- was removed — the toolbar had no width left for it — so the status bar's chip
-- is the one place a mouse can reach markdown flavor or reading theme, and no
-- menu-bar command carries either axis. That makes this probe the only proof
-- the axes are reachable at all, which is why it survived the move instead of
-- being deleted with the control it used to open.
set appearanceOpenResult to my statusBarMenuItemsAfterSinglePress(¬
  targetPID, "Preview Appearance", "pensieve.statusbar.appearance", ¬
  {"Flavor", "Theme"}, 30)
set appearanceItems to item 1 of appearanceOpenResult
log "APPEARANCE_MENU_OPEN_MS=" & (item 2 of appearanceOpenResult)
tell application "System Events"
    if appearanceItems does not contain "Flavor" then
      error "Status bar appearance chip is missing the Flavor picker"
    end if
    if appearanceItems does not contain "Theme" then
      error "Status bar appearance chip is missing the Theme picker"
    end if
    key code 53
    delay 0.5

    -- Dismissing a native menu invalidates its AXUIElement; reacquiring the
    -- chip mirrors a later user click instead of testing a stale Accessibility
    -- handle.
    set appearanceReopenResult to my statusBarMenuItemsAfterSinglePress(¬
      targetPID, "Preview Appearance", "pensieve.statusbar.appearance", ¬
      {"Flavor", "Theme"}, 30)
    log "APPEARANCE_MENU_REOPEN_MS=" & (item 2 of appearanceReopenResult)
    key code 53

    -- Looking this control up BY NAME, not by identifier, is the assertion and
    -- not an implementation detail: a toolbar control declared directly in its
    -- group is bridged to an NSToolbarItem of its own and does NOT inherit its
    -- SwiftUI label's text the way a `ControlGroup` segment did. When this
    -- menu left the assistants `ControlGroup` it came back as AXDescription
    -- "menu button" with the raw SF Symbol name ("wand.and.stars") as its
    -- AXTitle -- which is what VoiceOver then announces. The identifier census
    -- cannot see that at all: AXIdentifier survives the move untouched, so a
    -- census-only check would have stayed green on a control no assistive tool
    -- can name. Keep this lookup name-based.
    set rewriteOpenResult to my toolbarMenuItemsAfterSinglePress(¬
      targetPID, "Rewrite with AI", "pensieve.toolbar.aiRewrite", ¬
      {"Improve Writing", "Fix Grammar"}, true, 30)
    if item 3 of rewriteOpenResult then
      set rewriteItems to item 1 of rewriteOpenResult
      log "REWRITE_MENU_OPEN_MS=" & (item 2 of rewriteOpenResult)
      if rewriteItems does not contain "Improve Writing" then
        error "Rewrite with AI menu is missing Improve Writing"
      end if
      if rewriteItems does not contain "Fix Grammar" then
        error "Rewrite with AI menu is missing Fix Grammar"
      end if
      key code 53
    end if

    my clickExactMenuItem(targetPID, "File", "New File")
    delay 0.5
    set untitledCensus to my settledToolbarCensus(targetPID, baseExpectedIdentifiers, {}, 40)
    my assertWindowGeometry(targetPID, coldPosition, coldSize, "file-backed to untitled transition")
    log "AX_CENSUS_UNTITLED=" & my joined(untitledCensus, ",")

    -- A toolbar census can prove the editing chrome exists while missing the
    -- product failures this probe is for: a native Untitled tab whose body is
    -- still the launcher, or an editor that exists but did not receive the
    -- first-responder handoff promised by New File/New Tab. Check product-owned
    -- focus BEFORE the smoke mutates anything; setting AXFocused here would
    -- manufacture the state under test and mask the regression.
    set editorElement to my windowElementByIdentifier(targetPID, "pensieve.editor", 50)
    if focused of editorElement is not true then
      error "New File did not move first-responder focus to the Untitled editor"
    end if
    set witnessText to "pensieve-new-tab-smoke-witness"
    keystroke witnessText
    set witnessLanded to false
    repeat with attemptNumber from 1 to 30
      try
        if (value of editorElement as text) contains witnessText then
          set witnessLanded to true
          exit repeat
        end if
      end try
      delay 0.1
    end repeat
    if not witnessLanded then
      error "Untitled editor exists but did not accept typed text"
    end if
    log "NEW_UNTITLED_EDITABLE=PASS"

    log "AX_REGAIN_EXACT_WINDOW_COUNT_BEGIN"
    set postMenuWindowCount to my exactWindowCount(targetPID)
    log "AX_REGAIN_EXACT_WINDOW_COUNT_END=" & postMenuWindowCount
    if postMenuWindowCount is 0 then error "pid=" & targetPID & " has no windows after menu probing"
end tell


log "AX_REGAIN_FINDER_ACTIVATE_BEGIN"
tell application "Finder" to activate
log "AX_REGAIN_FINDER_ACTIVATE_END"
delay 0.3
-- Reactivate the exact resolved PID (see targetPID above), not the app name,
-- so this regain step re-focuses the process under test unambiguously.
log "AX_REGAIN_EXACT_ACTIVATE_BEGIN"
my activateExactProcess(targetPID)
log "AX_REGAIN_EXACT_ACTIVATE_END"
log "AX_REGAIN_RAISE_BEGIN"
my raiseExactProcessWindow(targetPID)
log "AX_REGAIN_RAISE_END"
delay 0.5
log "AX_REGAIN_CENSUS_BEGIN"
set regainCensus to my settledToolbarCensus(targetPID, baseExpectedIdentifiers, {}, 40)
log "AX_REGAIN_CENSUS_END"
log "AX_REGAIN_GEOMETRY_BEGIN"
my assertWindowGeometry(targetPID, coldPosition, coldSize, "key-window regain/redraw")
log "AX_REGAIN_GEOMETRY_END"
log "AX_CENSUS_REGAIN_REDRAW=" & my joined(regainCensus, ",")
end run
APPLESCRIPT

AX_VERIFIED_PID="$(isolated_app_verify_running_identity \
  "$APP_ID" "$APP_PATH" "$EXECUTABLE_PATH")" \
  || die "runtime identity drifted before the toolbar AX census"
[[ "$AX_VERIFIED_PID" == "$OWNED_PID" ]] \
  || die "runtime pid changed before the toolbar AX census ($OWNED_PID -> $AX_VERIFIED_PID)"
# This one process covers every toolbar mode, two native-menu opens, optional
# Rewrite, editable-New, and focus regain. Each transition keeps its own tight
# settlement budget; the outer timeout exceeds their cumulative worst-case
# cost on a loaded WindowServer and must not become the first limit to fire.
ax_census_output=$(run_ax_osascript "$TOOLBAR_AX_OUTER_TIMEOUT_SECONDS" "$ax_census_script" "$OWNED_PID" "$APP_ID" "$COLD_ONLY" "$BASE_EXPECTED_IDENTIFIER_COUNT" \
  "${EXPECTED_TOOLBAR_IDENTIFIERS[@]}" 2>&1) || ax_census_status=$?
rm -f "$ax_census_script"
printf '%s\n' "$ax_census_output"

if [[ $ax_census_status -ne 0 ]]; then
  # A completely empty observed census can mean the app truly has no window
  # (a real product FAIL) or that its window exists but landed offscreen
  # because the active Space cannot host it (e.g. a fullscreen Screen Sharing
  # session) -- an environment condition, not a product bug. A partial census
  # (some identifiers observed, some missing) is never this case and always
  # stays a real FAIL.
  ax_census_env_pattern='PENSIEVE_AX_EMPTY_CENSUS'
  if [[ "$ax_census_output" =~ $ax_census_env_pattern ]]; then
    window_server_state="$(dump_window_server_state)"
    printf '%s\n' "$window_server_state"
    window_server_pattern='CGWINDOW_SUMMARY total=([1-9][0-9]*) onscreen=0'
    if [[ "$window_server_state" =~ $window_server_pattern ]]; then
      log "UI-SMOKE-ENV: $APP_NAME window exists but is offscreen (active Space unavailable -- e.g. fullscreen Screen Sharing). Environment inconclusive, NOT a product failure. Re-run when a normal desktop Space is active."
      exit 3
    fi
  fi
  exit "$ax_census_status"
fi

if [[ $COLD_ONLY -eq 0 ]]; then
  native_tab_probe_status=0
  NATIVE_TAB_VERIFIED_PID="$(isolated_app_verify_running_identity \
    "$APP_ID" "$APP_PATH" "$EXECUTABLE_PATH")" \
    || die "runtime identity drifted before the native-tab AX proof"
  [[ "$NATIVE_TAB_VERIFIED_PID" == "$OWNED_PID" ]] \
    || die "runtime pid changed before the native-tab AX proof ($OWNED_PID -> $NATIVE_TAB_VERIFIED_PID)"
  native_tab_probe_output="$(run_bounded_command 30 \
    "$NATIVE_TAB_AX_PROBE" \
    "$OWNED_PID" \
    "Toolbar cold-frame witness" \
    "pensieve-new-tab-smoke-witness" \
    8 2>&1)" || native_tab_probe_status=$?
  printf '%s\n' "$native_tab_probe_output"
  [[ $native_tab_probe_status -eq 0 ]] || exit "$native_tab_probe_status"
fi

ok "native UI smoke passed"

# --toolbar-cold-only returns after the cold census (the toolbar AppleScript
# exits early but bash falls through to here), so the saved-state probe runs
# only on a full pass. The toolbar phase leaves an activated instance running;
# the probe manages its own launch/quit/relaunch cycle, starting with
# terminate_app.
if [[ $COLD_ONLY -eq 0 ]]; then
  prepare_next_smoke_scenario "toolbar scenario"
  run_saved_state_isolation_probe
  ok "Saved Application State isolation probe passed"
  prepare_next_smoke_scenario "saved-state scenario"
  run_zero_window_external_open_probe
  ok "Zero-window external-open probe passed"
  prepare_next_smoke_scenario "zero-window external-open scenario"
  run_restore_on_external_open_probe
  ok "Restore-ON external-open probe passed"
fi
