#!/usr/bin/env bash
# BUGMAP P0 runtime smoke matrix (W4-A).
#
# Splits the matrix into two lanes:
#   STATIC  — deterministic bundle-truth rows that never touch the GUI session
#             (identity, strict codesign, entitlements, purpose strings, hash,
#             provenance stamp). Always run.
#   GUI     — rows that need a live, unlocked login session. Every GUI probe
#             owns a unique staged identity, so a production Pensieve process
#             may remain open and is never selected, quit or sampled.
#
# Usage:
#   scripts/bugmap-p0-smoke.sh --app <path/to/Pensieve.app> --evidence <dir>
#     [--critical-only]   run only the critical rows (post-install re-check)
#     [--allow-kill]      deprecated compatibility flag; ignored. This harness
#                         never terminates a production Pensieve process.
set -euo pipefail

APP_PATH=""
EVIDENCE_DIR=""
CRITICAL_ONLY=0
ALLOW_KILL=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app) APP_PATH="$2"; shift 2 ;;
    --evidence) EVIDENCE_DIR="$2"; shift 2 ;;
    --critical-only) CRITICAL_ONLY=1; shift ;;
    --allow-kill) ALLOW_KILL=1; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

[[ -n "$APP_PATH" ]] || { echo "--app <Pensieve.app> is required" >&2; exit 2; }
[[ -n "$EVIDENCE_DIR" ]] || { echo "--evidence <dir> is required" >&2; exit 2; }
mkdir -p "$EVIDENCE_DIR"

APP_PATH="$(cd -P "$(dirname "$APP_PATH")" 2>/dev/null && pwd -P)/$(basename "$APP_PATH")"
EVIDENCE_BASE="$(cd -P "$EVIDENCE_DIR" && pwd -P)"
RUN_UUID="$(/usr/bin/uuidgen | /usr/bin/tr '[:upper:]' '[:lower:]')"
[[ -n "$RUN_UUID" ]] || { echo "could not mint a BUGMAP report UUID" >&2; exit 1; }
EVIDENCE_DIR="$EVIDENCE_BASE/bugmap-$RUN_UUID"

APP_BINARY="$APP_PATH/Contents/MacOS/Pensieve"
REPO_ROOT="$(cd -P "$(dirname "$0")/.." && pwd -P)"
STAMP="$(date "+%Y-%m-%dT%H:%M:%S%z")"
# shellcheck source=scripts/lib/isolated-app.sh
# shellcheck disable=SC1091
source "$REPO_ROOT/scripts/lib/isolated-app.sh"

SOURCE_COMMIT="$(isolated_app_assert_source_provenance \
  "$REPO_ROOT" "$APP_PATH" \
  "${PENSIEVE_BUGMAP_ALLOW_STALE_SOURCE:-0}" \
  "${PENSIEVE_BUGMAP_ALLOW_DIRTY_SOURCE:-0}")" \
  || { printf 'BUGMAP source provenance check failed; rebuild from the current clean product sources\n' >&2; exit 1; }

# Do not create a run report before the immutable source has passed provenance.
# A rejected source therefore leaves no empty bugmap-UUID directory behind.
/bin/mkdir "$EVIDENCE_DIR"
EVIDENCE_DIR="$(cd -P "$EVIDENCE_DIR" && pwd -P)"

if [[ "$ALLOW_KILL" -eq 1 ]]; then
  printf '\033[33m[warn]\033[0m --allow-kill is deprecated and ignored; production Pensieve is never touched\n' >&2
fi

G4_OWNER_ROOT=""
G4_APP_ID=""
G4_APP_PATH=""
G4_SUPPORT=""
G4_SERVICE=""
G4_PID=""
G4_EXECUTABLE=""
G4_EXECUTABLE_PATH=""
G4_MANIFEST=""
G4_EVIDENCE_MANIFEST=""
G4_SAMPLE_PID=""
OPEN_FIXTURE=""
G4_STAGED=0
G4_CLEANUP_FAILED=0

write_g4_retry_evidence() {
  local reason="${1:-unknown cleanup failure}"
  local runtime="not queried"
  if [[ -n "$G4_APP_ID" && -n "$G4_APP_PATH" && -n "$G4_EXECUTABLE_PATH" ]]; then
    runtime="$(isolated_app_verify_running_identity \
      "$G4_APP_ID" "$G4_APP_PATH" "$G4_EXECUTABLE_PATH" 2>&1)" \
      || runtime="identity query failed or no matching process: $runtime"
  fi
  {
    echo "reason: $reason"
    echo "run_uuid: $RUN_UUID"
    echo "report_root: $EVIDENCE_DIR"
    echo "owner_root: ${G4_OWNER_ROOT:-<unset>}"
    echo "manifest: ${G4_MANIFEST:-<unset>}"
    echo "evidence_manifest: ${G4_EVIDENCE_MANIFEST:-<unset>}"
    echo "bundle_id: ${G4_APP_ID:-<unset>}"
    echo "bundle_path: ${G4_APP_PATH:-<unset>}"
    echo "executable_path: ${G4_EXECUTABLE_PATH:-<unset>}"
    echo "support_path: ${G4_SUPPORT:-<unset>}"
    echo "recorded_pid: ${G4_PID:-<unset>}"
    echo "runtime: $runtime"
    echo "action: preserve the owner root and identity manifest; retry only after exact identity verification"
  } >"$EVIDENCE_DIR/g4-cleanup-retry.txt"
  printf '\033[31m[cleanup retained]\033[0m %s\n' "$reason" >&2
  printf '  retry evidence: %s\n' "$EVIDENCE_DIR/g4-cleanup-retry.txt" >&2
  printf '  owner root:     %s\n' "${G4_OWNER_ROOT:-<unset>}" >&2
  printf '  manifest:       %s\n' "${G4_MANIFEST:-<unset>}" >&2
}

g4_reauthorize_recorded_pid() {
  local verified_pid
  [[ -n "$G4_APP_ID" && -n "$G4_APP_PATH" && -n "$G4_EXECUTABLE_PATH" ]] || return 1
  verified_pid="$(isolated_app_verify_running_identity \
    "$G4_APP_ID" "$G4_APP_PATH" "$G4_EXECUTABLE_PATH")" || return 1
  if [[ -n "$G4_PID" && "$verified_pid" != "$G4_PID" ]]; then
    printf 'BUGMAP G4 PID changed: recorded=%s verified=%s\n' "$G4_PID" "$verified_pid" >&2
    return 1
  fi
  G4_PID="$verified_pid"
  return 0
}

# Graceful wait and force escalation are one NSRunningApplication transaction
# over the exact bundle id + bundle path + executable path + recorded PID. A
# mismatch is evidence, never authority to terminate an arbitrary process.
g4_terminate_exact_process() {
  local running_status status
  [[ -n "$G4_APP_ID" ]] || return 0
  if isolated_app_identity_is_running "$G4_APP_ID"; then
    :
  else
    running_status=$?
    if [[ "$running_status" -eq 1 ]]; then
      G4_PID=""
      return 0
    fi
    return 1
  fi

  g4_reauthorize_recorded_pid || return 1
  if isolated_app_control_identity \
    terminate "$G4_APP_ID" "$G4_APP_PATH" "$G4_EXECUTABLE_PATH" "$G4_PID" 5; then
    G4_PID=""
    return 0
  else
    status=$?
  fi
  case "$status" in
    3) G4_PID=""; return 0 ;;
    *) return 1 ;;
  esac
}

g4_cleanup_owned_capsule() {
  if [[ "$G4_STAGED" -ne 1 ]]; then return 0; fi
  if ! g4_terminate_exact_process; then
    write_g4_retry_evidence "exact G4 process termination could not be proven"
    return 1
  fi
  [[ -n "$G4_MANIFEST" ]] || {
    write_g4_retry_evidence "identity manifest coordinate is missing; refusing guessed cleanup"
    return 1
  }
  if [[ -f "$G4_MANIFEST" ]]; then
    if ! isolated_app_validate_cleanup_manifest "$G4_MANIFEST" "$G4_OWNER_ROOT"; then
      write_g4_retry_evidence "identity manifest is invalid; refusing cleanup mutation"
      return 1
    fi
    if [[ -n "$OPEN_FIXTURE" ]] \
      && ! isolated_app_remove_exact_path "$OPEN_FIXTURE" "BUGMAP open fixture"; then
      write_g4_retry_evidence "owned G4 fixture cleanup failed"
      return 1
    fi
  fi
  # A signal can arrive after the exact reservation temporary is created but
  # before identity.plist is atomically published. cleanup_manifest recognizes
  # that one bounded state; any bundle/profile residue without authority is
  # still rejected and retained for evidence.
  if ! isolated_app_cleanup_manifest "$G4_MANIFEST" "$G4_OWNER_ROOT"; then
    write_g4_retry_evidence "manifested profile or LaunchServices cleanup failed"
    return 1
  fi
  if [[ -d "$G4_OWNER_ROOT" ]]; then
    if [[ ! -f "$G4_MANIFEST" && -f "$G4_EVIDENCE_MANIFEST" ]]; then
      /bin/cp -p "$G4_EVIDENCE_MANIFEST" "$G4_MANIFEST" || true
    fi
    write_g4_retry_evidence "owner root survived manifested cleanup; refusing to hide an unknown artifact"
    return 1
  fi
  G4_STAGED=0
  return 0
}

# Invoked indirectly by the EXIT trap below.
# shellcheck disable=SC2329
cleanup_bugmap_runtime() {
  local exit_code=$? cleanup_code=0
  set +e
  if [[ -n "$G4_SAMPLE_PID" ]] && /bin/kill -0 "$G4_SAMPLE_PID" 2>/dev/null; then
    /bin/kill -TERM "$G4_SAMPLE_PID" 2>/dev/null || true
    wait "$G4_SAMPLE_PID" 2>/dev/null || true
  fi
  G4_SAMPLE_PID=""
  if [[ "$G4_CLEANUP_FAILED" -eq 1 ]]; then
    cleanup_code=1
  elif ! g4_cleanup_owned_capsule; then
    G4_CLEANUP_FAILED=1
    cleanup_code=1
  fi
  if [[ "$exit_code" -eq 0 && "$cleanup_code" -ne 0 ]]; then exit_code=$cleanup_code; fi
  exit "$exit_code"
}
trap cleanup_bugmap_runtime EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

run_g4_fresh_launcher_baseline() {
  local verified_pid="$1"
  /usr/bin/osascript - "$verified_pid" "$G4_APP_ID" >"$EVIDENCE_DIR/g4-fresh-baseline.txt" <<'APPLESCRIPT'
property expectedBundleID : ""
on run argv
  set targetPID to (item 1 of argv) as integer
  set my expectedBundleID to item 2 of argv as text
  my waitForProcess(targetPID, 15)
  my waitForWindow(targetPID, 15)

  my makeExactProcessFrontmost(targetPID, 5)
  delay 0.5

  -- A single early frame can precede delayed workspace/recovery hydration.
  -- Require the exact empty launcher for three continuous seconds before the
  -- BUGMAP lane is allowed to open its witness.
  repeat with sampleNumber from 1 to 20
    set censusResult to my exactLauncherCensus(targetPID, 2)
    set windowCount to item 1 of censusResult
    set identifiers to item 2 of censusResult

    if windowCount is not 1 then
      error "fresh BUGMAP profile must keep exactly one launcher, got " & windowCount & " at sample " & sampleNumber
    end if
    if identifiers does not contain "pensieve.sidebar.emptyState" then
      error "fresh BUGMAP profile lost the empty sidebar at sample " & sampleNumber
    end if
    repeat with forbiddenIdentifier in {"pensieve.sidebar.list.openFiles", "pensieve.sidebar.list.workspace", "pensieve.recoveredDrafts", "pensieve.recoveredDrafts.row", "pensieve.emptyState.recents"}
      if identifiers contains (forbiddenIdentifier as text) then
        error "fresh BUGMAP profile exposed stale UI [" & (forbiddenIdentifier as text) & "] at sample " & sampleNumber
      end if
    end repeat
    delay 0.15
  end repeat

  return "FRESH_PROFILE_RESULT=PASS (stable 3s; one empty launcher; zero workspace/open files/recovery/recents)"
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
  error "Timed out resolving the exact BUGMAP process for frontmost pid=" & targetPID
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
  error "Timed out taking the exact BUGMAP launcher census for pid=" & targetPID
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
  error "Timed out waiting for process pid=" & targetPID
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
APPLESCRIPT
}

open_g4_fixture_in_running_process() {
  local before_pid after_pid
  g4_reauthorize_recorded_pid || return 1
  before_pid="$G4_PID"
  /usr/bin/open -a "$G4_APP_PATH" "$OPEN_FIXTURE" || return 1
  after_pid="$(isolated_app_verify_running_identity \
    "$G4_APP_ID" "$G4_APP_PATH" "$G4_EXECUTABLE_PATH")" || return 1
  [[ "$after_pid" == "$before_pid" ]] || {
    printf 'BUGMAP external open changed process identity: before=%s after=%s\n' \
      "$before_pid" "$after_pid" >&2
    return 1
  }
  G4_PID="$after_pid"
  return 0
}

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
declare -a MATRIX_ROWS=()

row() { # row <PASS|FAIL|SKIP> <id> <detail>
  local state="$1" id="$2" detail="$3"
  MATRIX_ROWS+=("$state|$id|$detail")
  case "$state" in
    PASS) PASS_COUNT=$((PASS_COUNT + 1)); printf '\033[32m[PASS]\033[0m %s — %s\n' "$id" "$detail" ;;
    FAIL) FAIL_COUNT=$((FAIL_COUNT + 1)); printf '\033[31m[FAIL]\033[0m %s — %s\n' "$id" "$detail" ;;
    SKIP) SKIP_COUNT=$((SKIP_COUNT + 1)); printf '\033[33m[SKIP]\033[0m %s — %s\n' "$id" "$detail" ;;
  esac
}

# ---------------------------------------------------------------- STATIC lane

if [[ -d "$APP_PATH" && -x "$APP_BINARY" ]]; then
  row PASS S1-bundle "bundle present with executable at $APP_BINARY"
else
  row FAIL S1-bundle "bundle or executable missing at $APP_PATH"
fi

if codesign --verify --deep --strict --verbose=2 "$APP_PATH" \
  >"$EVIDENCE_DIR/codesign-verify.txt" 2>&1; then
  row PASS S2-codesign "strict deep verify green (evidence: codesign-verify.txt)"
else
  row FAIL S2-codesign "codesign --verify --deep --strict failed (see codesign-verify.txt)"
fi

codesign -d --entitlements :- "$APP_PATH" >"$EVIDENCE_DIR/entitlements.plist" 2>/dev/null || true
# plutil keypaths treat dots as separators, so escape the entitlement key.
if plutil -extract 'com\.apple\.security\.device\.audio-input' raw \
  "$EVIDENCE_DIR/entitlements.plist" 2>/dev/null | grep -qx "true"; then
  row PASS S3-audio-entitlement "com.apple.security.device.audio-input = true"
else
  row FAIL S3-audio-entitlement "audio-input entitlement missing or false"
fi

MIC_PURPOSE="$(plutil -extract NSMicrophoneUsageDescription raw "$APP_PATH/Contents/Info.plist" 2>/dev/null || true)"
SPEECH_PURPOSE="$(plutil -extract NSSpeechRecognitionUsageDescription raw "$APP_PATH/Contents/Info.plist" 2>/dev/null || true)"
if [[ -n "$MIC_PURPOSE" && -n "$SPEECH_PURPOSE" ]]; then
  row PASS S4-purpose-strings "microphone + speech purpose strings present"
else
  row FAIL S4-purpose-strings "missing Info.plist usage descriptions (mic:'$MIC_PURPOSE' speech:'$SPEECH_PURPOSE')"
fi

{
  echo "stamp: $STAMP"
  echo "bundle: $APP_PATH"
  echo "bundle_id: $(plutil -extract CFBundleIdentifier raw "$APP_PATH/Contents/Info.plist" 2>/dev/null || echo '?')"
  echo "version: $(plutil -extract CFBundleShortVersionString raw "$APP_PATH/Contents/Info.plist" 2>/dev/null || echo '?') ($(plutil -extract CFBundleVersion raw "$APP_PATH/Contents/Info.plist" 2>/dev/null || echo '?'))"
  echo "binary_sha256: $(shasum -a 256 "$APP_BINARY" | awk '{print $1}')"
  echo "pensieve_commit: $(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || echo '?')"
  echo "pensieve_branch: $(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
  if [[ -d "$HOME/vc-workspace/vetcoders/vibecrafted/.git" ]]; then
    echo "vibecrafted_commit: $(git -C "$HOME/vc-workspace/vetcoders/vibecrafted" rev-parse HEAD)"
  fi
  echo "macos: $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
} >"$EVIDENCE_DIR/bundle-identity.txt"
row PASS S5-provenance "bundle hash + commits + macOS recorded (bundle-identity.txt)"

spctl --assess --type execute "$APP_PATH" >"$EVIDENCE_DIR/spctl.txt" 2>&1 || true
row PASS S6-gatekeeper "spctl verdict recorded (unnotarized local lane is expected): $(head -1 "$EVIDENCE_DIR/spctl.txt" 2>/dev/null || echo n/a)"

# ------------------------------------------------------------------ GUI lane
# Preflight: the GUI rows are truthful only on an unlocked console. A locked
# screen poisons every window/AX/screenshot artifact. A production Pensieve
# process is not a blocker because every probe has a unique identity.

GUI_BLOCKERS=()
if ioreg -k IOConsoleUsers 2>/dev/null | grep -q "ScreenIsLocked.*Yes"; then
  GUI_BLOCKERS+=("screen locked (window/AX/sample artifacts are poisoned under lock)")
fi

GUI_ROWS=(
  "G1-launch-ax|launch bundle, first window + AX surface appears"
  "G2-menu-census|File/Open Recent + Agents menus present via ui-smoke walk"
  "G3-toolbar-families|toolbar semantic families + AX labels (ui-smoke walk)"
  "G4-open-sample|3s sample during external file open — no registerOpenFile storm"
)
if [[ "$CRITICAL_ONLY" -eq 1 ]]; then
  GUI_ROWS=("G1-launch-ax|launch bundle, first window + AX surface appears"
    "G4-open-sample|3s sample during external file open — no registerOpenFile storm")
fi

if [[ ${#GUI_BLOCKERS[@]} -gt 0 ]]; then
  for entry in "${GUI_ROWS[@]}"; do
    row SKIP "${entry%%|*}" "${entry#*|} — blocked: ${GUI_BLOCKERS[*]}"
  done
else
  # G1+G2+G3 ride the existing accessibility walk (it owns launch, menu and
  # toolbar truth); G4 samples the fresh process during a scripted file open.
  # One bounded retry: System Events can drop a stale AppleEvent handle
  # (-10000) right after a quit+relaunch of the same bundle identifier.
  UI_SMOKE_OK=0
  UI_SMOKE_LOG=""
  for attempt in 1 2; do
    UI_SMOKE_LOG="$EVIDENCE_DIR/ui-smoke-attempt-$attempt.txt"
    if PENSIEVE_UI_SMOKE_ALLOW_STALE_SOURCE="${PENSIEVE_BUGMAP_ALLOW_STALE_SOURCE:-0}" \
      PENSIEVE_UI_SMOKE_ALLOW_DIRTY_SOURCE="${PENSIEVE_BUGMAP_ALLOW_DIRTY_SOURCE:-0}" \
      "$REPO_ROOT/scripts/ui-smoke.sh" "$APP_PATH" \
      >"$UI_SMOKE_LOG" 2>&1; then
      UI_SMOKE_OK=1
      break
    fi
    [[ "$attempt" -eq 1 ]] && sleep 2
  done
  if [[ "$UI_SMOKE_OK" -eq 1 ]]; then
    row PASS G1-launch-ax "ui-smoke launch + window + AX probe green ($(basename "$UI_SMOKE_LOG"))"
    if [[ "$CRITICAL_ONLY" -ne 1 ]]; then
      row PASS G2-menu-census "menu census green ($(basename "$UI_SMOKE_LOG"))"
      row PASS G3-toolbar-families "toolbar AX census green ($(basename "$UI_SMOKE_LOG"))"
    fi
  else
    row FAIL G1-launch-ax "ui-smoke failed (see ui-smoke-attempt-1.txt and ui-smoke-attempt-2.txt)"
    if [[ "$CRITICAL_ONLY" -ne 1 ]]; then
      row FAIL G2-menu-census "not reached (ui-smoke failed)"
      row FAIL G3-toolbar-families "not reached (ui-smoke failed)"
    fi
  fi

  G4_OWNER_ROOT="$EVIDENCE_DIR/runtime-owner-$RUN_UUID"
  /bin/mkdir "$G4_OWNER_ROOT"
  G4_OWNER_ROOT="$(cd -P "$G4_OWNER_ROOT" && pwd -P)"
  G4_MANIFEST="$G4_OWNER_ROOT/identity.plist"
  G4_EVIDENCE_MANIFEST="$EVIDENCE_DIR/g4-identity-$RUN_UUID.plist"
  G4_APP_ID="$(isolated_app_generate_bundle_id bugmap)"
  G4_TOKEN="${G4_APP_ID##*.}"
  G4_EXECUTABLE="Pbug${G4_TOKEN:1}"
  G4_APP_PATH="$G4_OWNER_ROOT/$G4_EXECUTABLE.app"
  G4_EXECUTABLE_PATH="$G4_APP_PATH/Contents/MacOS/$G4_EXECUTABLE"
  G4_SUPPORT="$G4_OWNER_ROOT/$G4_TOKEN.state"
  G4_SERVICE="$G4_APP_ID.completion-provider"
  G4_SOURCE_COMMIT="$SOURCE_COMMIT"
  SAMPLE_FILE="$EVIDENCE_DIR/open-sample-$RUN_UUID.txt"
  SAMPLE_STDERR="$EVIDENCE_DIR/open-sample-$RUN_UUID.stderr.txt"
  OPEN_FIXTURE="$G4_OWNER_ROOT/w4a-open-fixture-$RUN_UUID.md"
  G4_PROBE_ERROR=""

  # Arm cleanup before reservation publication so a signal in the plutil/ln
  # window can retire the exact temporary authority. No bundle or profile
  # mutation is allowed until the reservation has been published.
  G4_STAGED=1

  if [[ -n "$G4_PROBE_ERROR" ]]; then
    :
  elif [[ -z "$G4_SOURCE_COMMIT" ]]; then
    G4_PROBE_ERROR="source app has no PensieveBuildCommit; refusing an untraceable runtime capsule"
  elif ! isolated_app_reserve_manifest \
    "$G4_MANIFEST" "$G4_OWNER_ROOT" "$APP_PATH" "$G4_APP_PATH" "$G4_EXECUTABLE" \
    "$G4_APP_ID" "Pensieve BUGMAP Smoke $RUN_UUID" "$G4_SUPPORT" "$G4_SERVICE" \
    "$G4_SOURCE_COMMIT"
  then
    G4_PROBE_ERROR="could not reserve G4 cleanup authority before staging"
  fi

  if [[ -z "$G4_PROBE_ERROR" ]] && ! /bin/mkdir "$G4_SUPPORT"; then
    G4_PROBE_ERROR="could not create the canonical G4 support directory"
  fi

  if [[ -z "$G4_PROBE_ERROR" ]] \
    && ! { isolated_app_reset_defaults_domain "$G4_APP_ID" \
      && isolated_app_reset_keychain_item \
        "$G4_APP_ID" "$G4_SERVICE" "$ISOLATED_APP_KEYCHAIN_ACCOUNT" \
      && isolated_app_assert_profile_fresh \
        "$G4_APP_ID" "$G4_SUPPORT" "$G4_SERVICE" "$ISOLATED_APP_KEYCHAIN_ACCOUNT"; }
  then
    G4_PROBE_ERROR="isolated G4 identity was not fresh before staging"
  fi

  if [[ -z "$G4_PROBE_ERROR" ]] \
    && ! isolated_app_stage_bundle \
      "$APP_PATH" "$G4_APP_PATH" "$G4_EXECUTABLE" "$G4_APP_ID" \
      "$G4_EXECUTABLE" "Pensieve BUGMAP Smoke $RUN_UUID" "$G4_SUPPORT" "$G4_SERVICE" \
      "$REPO_ROOT" "${PENSIEVE_BUGMAP_ALLOW_STALE_SOURCE:-0}" \
      "${PENSIEVE_BUGMAP_ALLOW_DIRTY_SOURCE:-0}"
  then
    G4_PROBE_ERROR="could not stage the manifested G4 identity"
  fi

  if [[ -z "$G4_PROBE_ERROR" ]] \
    && ! isolated_app_finalize_manifest "$G4_MANIFEST" "$G4_OWNER_ROOT"
  then
    G4_PROBE_ERROR="could not finalize the staged G4 identity manifest"
  fi

  if [[ -z "$G4_PROBE_ERROR" ]] \
    && ! isolated_app_verify_bundle_from_manifest "$G4_MANIFEST" "$G4_OWNER_ROOT"
  then
    G4_PROBE_ERROR="staged G4 bundle does not match its identity manifest"
  elif [[ -z "$G4_PROBE_ERROR" ]] \
    && ! /bin/cp -p "$G4_MANIFEST" "$G4_EVIDENCE_MANIFEST"
  then
    G4_PROBE_ERROR="could not preserve the verified G4 identity in the UUID report"
  fi

  if [[ -z "$G4_PROBE_ERROR" ]]; then
    G4_OPEN_STATUS=0
    isolated_app_open_new \
      "$G4_APP_ID" "$G4_APP_PATH" "$G4_SUPPORT" "$G4_SERVICE" \
      || G4_OPEN_STATUS=$?
    G4_PID="$(isolated_app_wait_for_running_identity \
      "$G4_APP_ID" "$G4_APP_PATH" "$G4_EXECUTABLE_PATH" 120 2>/dev/null)" \
      || G4_PID=""
    if [[ -z "$G4_PID" ]]; then
      G4_PROBE_ERROR="empty G4 launch did not produce the exact manifested process (open status $G4_OPEN_STATUS)"
    elif ! run_g4_fresh_launcher_baseline "$G4_PID"; then
      G4_PROBE_ERROR="exact G4 process failed the fresh empty-launcher UI baseline"
    elif ! g4_reauthorize_recorded_pid; then
      G4_PROBE_ERROR="G4 identity changed during the fresh baseline"
    fi
  fi

  # The fixture does not exist until the empty-launcher baseline has passed,
  # so a stale workspace, recovered draft or Recent item cannot be hidden by
  # the very document this probe is about to open.
  if [[ -z "$G4_PROBE_ERROR" ]]; then
    printf '# W4-A open fixture\n' >"$OPEN_FIXTURE"
    if ! g4_reauthorize_recorded_pid; then
      G4_PROBE_ERROR="could not re-authenticate the exact G4 PID before sample"
    else
      /usr/bin/sample "$G4_PID" 3 -f "$SAMPLE_FILE" \
        >/dev/null 2>"$SAMPLE_STDERR" &
      G4_SAMPLE_PID=$!
      if ! g4_reauthorize_recorded_pid; then
        /bin/kill -TERM "$G4_SAMPLE_PID" 2>/dev/null || true
        wait "$G4_SAMPLE_PID" 2>/dev/null || true
        G4_SAMPLE_PID=""
        G4_PROBE_ERROR="G4 identity changed while attaching sample"
      else
        /bin/sleep 0.2
      fi
      if [[ -n "$G4_SAMPLE_PID" ]] && ! /bin/kill -0 "$G4_SAMPLE_PID" 2>/dev/null; then
        if wait "$G4_SAMPLE_PID"; then G4_SAMPLE_STATUS=0; else G4_SAMPLE_STATUS=$?; fi
        G4_SAMPLE_PID=""
        G4_PROBE_ERROR="sample exited before external open (status $G4_SAMPLE_STATUS)"
      elif [[ -n "$G4_SAMPLE_PID" ]] && ! open_g4_fixture_in_running_process; then
        G4_PROBE_ERROR="external open did not stay in the authenticated G4 process"
      fi
    fi
  fi

  if [[ -n "$G4_SAMPLE_PID" ]]; then
    if wait "$G4_SAMPLE_PID"; then G4_SAMPLE_STATUS=0; else G4_SAMPLE_STATUS=$?; fi
    G4_SAMPLE_PID=""
    if [[ "$G4_SAMPLE_STATUS" -ne 0 && -z "$G4_PROBE_ERROR" ]]; then
      G4_PROBE_ERROR="sample failed with status $G4_SAMPLE_STATUS"
    elif [[ ! -s "$SAMPLE_FILE" && -z "$G4_PROBE_ERROR" ]]; then
      G4_PROBE_ERROR="sample exited successfully but produced no output"
    fi
  fi

  if [[ -z "$G4_PROBE_ERROR" ]]; then
    # `sample` frames carry a leading sample count (1 sample ≈ 1 ms on the
    # stack). The P0-14 storm was a per-document standardizedFileURL sweep
    # pinning the main thread for hundreds of ms, so the honest metric is
    # total samples inside registerOpenFile, not textual occurrences.
    STORM_SAMPLES="$(sed -nE 's/.*[^0-9]([0-9]+) FolderManager\.registerOpenFile.*/\1/p' \
      "$SAMPLE_FILE" | awk '{sum += $1} END {print sum + 0}')"
    if [[ "${STORM_SAMPLES:-0}" -lt 50 ]]; then
      row PASS G4-open-sample "fresh exact-PID capsule; registerOpenFile ≈${STORM_SAMPLES:-0}ms/3000ms ($(basename "$SAMPLE_FILE"))"
    else
      row FAIL G4-open-sample "registerOpenFile ≈${STORM_SAMPLES}ms/3000ms — storm signature ($(basename "$SAMPLE_FILE"))"
    fi
  else
    row FAIL G4-open-sample "$G4_PROBE_ERROR"
  fi

  if [[ "$G4_STAGED" -eq 1 ]]; then
    if g4_cleanup_owned_capsule; then
      :
    else
      G4_CLEANUP_FAILED=1
      row FAIL G4-cleanup "G4 cleanup retained owner root + manifest; see g4-cleanup-retry.txt"
    fi
  fi
fi

# ------------------------------------------------------------------- summary

{
  echo "# BUGMAP P0 smoke matrix — $STAMP"
  echo "run_uuid: $RUN_UUID"
  echo "report_root: $EVIDENCE_DIR"
  echo "app: $APP_PATH"
  for entry in "${MATRIX_ROWS[@]}"; do
    IFS='|' read -r state id detail <<<"$entry"
    echo "- [$state] $id — $detail"
  done
  echo "pass=$PASS_COUNT fail=$FAIL_COUNT skip=$SKIP_COUNT"
} >"$EVIDENCE_DIR/matrix.md"

echo "──────────────────────────────────────────"
echo "matrix: pass=$PASS_COUNT fail=$FAIL_COUNT skip=$SKIP_COUNT → $EVIDENCE_DIR/matrix.md"

# A missing (skipped) row is an unproven row: exit nonzero so no caller can
# read a blocked lane as a green matrix.
exit $((FAIL_COUNT + SKIP_COUNT > 0 ? 1 : 0))
