#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "$0")" && pwd -P)"
REPO_ROOT="$(cd -P "$SCRIPT_DIR/.." && pwd -P)"
# shellcheck source=scripts/lib/isolated-app.sh
source "$SCRIPT_DIR/lib/isolated-app.sh"

MANUAL_ROOT="$REPO_ROOT/.runtime/manual-smoke"
MANIFEST_PATH="$MANUAL_ROOT/identity.plist"
APP_PATH=""
SUPPORT_PATH=""
EXECUTABLE_NAME=""
DEFAULT_SOURCE="$REPO_ROOT/dist/Pensieve.app"

STAGE_ACTIVE=0
STAGE_BUNDLE_ID=""

die() {
  printf '\033[31m[manual-smoke fail]\033[0m %s\n' "$*" >&2
  exit 1
}

log() {
  printf '\033[36m[manual-smoke]\033[0m %s\n' "$*"
}

ok() {
  printf '\033[32m[manual-smoke ok]\033[0m %s\n' "$*"
}

usage() {
  cat <<EOF
Usage:
  scripts/stage-manual-smoke.sh stage [source.app]
  scripts/stage-manual-smoke.sh reopen
  scripts/stage-manual-smoke.sh verify
  scripts/stage-manual-smoke.sh clean

stage   Retires the previous manifested manual identity, stages a new unique
        identity from source.app (default: dist/Pensieve.app), opens it, and
        proves the first UI is one empty launcher with no inherited state.
reopen  Reopens or activates the currently staged identity without resetting
        the manual test state.
verify  Verifies the manifest, bundle signature/identity, and the exact runtime
        bundle/executable when the app is running.
clean   Quits only the exact manifested process (with bounded, identity-scoped
        NSRunningApplication escalation), then removes only paths owned by
        identity.plist.
EOF
}

canonical_existing_path() {
  local path="$1"
  [[ -e "$path" ]] || return 1
  printf '%s/%s\n' "$(cd "$(dirname "$path")" && pwd -P)" "$(basename "$path")"
}

manifest_layout_is_manual() {
  isolated_app_validate_cleanup_manifest "$MANIFEST_PATH" "$MANUAL_ROOT" || return 1
  local bundle_path support_path executable_name executable_path
  bundle_path="$(isolated_app_manifest_value "$MANIFEST_PATH" bundlePath)" || return 1
  support_path="$(isolated_app_manifest_value "$MANIFEST_PATH" supportPath)" || return 1
  executable_name="$(isolated_app_manifest_value "$MANIFEST_PATH" executableName)" \
    || return 1
  executable_path="$(isolated_app_manifest_value "$MANIFEST_PATH" executablePath)" \
    || return 1
  [[ "$(/usr/bin/dirname "$bundle_path")" == "$MANUAL_ROOT" ]] || return 1
  [[ "$(/usr/bin/dirname "$support_path")" == "$MANUAL_ROOT" ]] || return 1
  case "$(/usr/bin/basename "$bundle_path")" in Pmanual*.app) ;; *) return 1 ;; esac
  case "$(/usr/bin/basename "$support_path")" in r*.state) ;; *) return 1 ;; esac
  case "$executable_name" in Pmanual*) ;; *) return 1 ;; esac
  [[ "$executable_path" == "$bundle_path/Contents/MacOS/$executable_name" ]] || return 1
  APP_PATH="$bundle_path"
  SUPPORT_PATH="$support_path"
  EXECUTABLE_NAME="$executable_name"
}

assert_no_unmanifested_artifacts() {
  [[ ! -e "$MANIFEST_PATH" && ! -L "$MANIFEST_PATH" ]] || return 0
  if [[ -d "$MANUAL_ROOT" ]] \
    && [[ -n "$(/usr/bin/find "$MANUAL_ROOT" -mindepth 1 -print -quit 2>/dev/null)" ]]; then
    die "manual-smoke artifacts exist without identity.plist; refusing to guess their owner"
  fi
}

cleanup_previous_manifested_identity() {
  if [[ ! -e "$MANIFEST_PATH" ]]; then
    assert_no_unmanifested_artifacts
    return 0
  fi
  manifest_layout_is_manual \
    || die "identity.plist is invalid or does not own the fixed manual-smoke paths"
  local prior_id prior_executable
  prior_id="$(isolated_app_manifest_value "$MANIFEST_PATH" bundleID)" \
    || die "identity.plist has no bundleID"
  prior_executable="$(isolated_app_manifest_value "$MANIFEST_PATH" executablePath)" \
    || die "identity.plist has no executablePath"
  terminate_manifested_identity "$prior_id" "$prior_executable"
  log "retiring previous manual identity $prior_id"
  isolated_app_cleanup_manifest "$MANIFEST_PATH" "$MANUAL_ROOT" \
    || die "could not completely retire previous manual identity $prior_id"
}

verify_source_bundle() {
  local source="$1"
  local plist="$source/Contents/Info.plist"
  local actual_commit executable
  [[ -d "$source" && -f "$plist" ]] || die "source app is missing or malformed: $source"
  /usr/bin/codesign --verify --deep --strict "$source" >/dev/null 2>&1 \
    || die "source app does not pass strict codesign verification: $source"
  actual_commit="$(isolated_app_assert_source_provenance \
    "$REPO_ROOT" "$source" \
    "${PENSIEVE_MANUAL_SMOKE_ALLOW_STALE_SOURCE:-0}" \
    "${PENSIEVE_MANUAL_SMOKE_ALLOW_DIRTY_SOURCE:-0}")" \
    || die "source provenance check failed (historical and dirty-source overrides are separate and must be intentional)"
  executable="$(isolated_app_plist_value "$plist" CFBundleExecutable)" \
    || die "source app has no CFBundleExecutable"
  [[ -f "$source/Contents/MacOS/$executable" ]] \
    || die "source executable is missing: $source/Contents/MacOS/$executable"
  printf '%s\n' "$actual_commit"
}

run_osascript() {
  if command -v gtimeout >/dev/null 2>&1; then
    gtimeout --signal=TERM 90 /usr/bin/osascript "$@"
  else
    /usr/bin/osascript "$@"
  fi
}

# This is intentionally a UI assertion, not an inference from empty folders.
# A newly added persistence store outside the isolated capsule can pass every
# filesystem check and still put stale content in the launcher. The AX witness
# makes that regression visible before the operator starts a manual smoke.
run_fresh_ui_baseline() {
  local verified_pid="$1"
  local expected_bundle_id="$2"
  run_osascript - "$verified_pid" "$expected_bundle_id" <<'APPLESCRIPT'
on run argv
  set targetPID to (item 1 of argv) as integer
  set expectedBundleID to item 2 of argv as text
  my waitForProcess(targetPID, expectedBundleID, 15)
  my waitForWindow(targetPID, expectedBundleID, 15)
  my makeExactProcessFrontmost(targetPID, expectedBundleID, 5)
  delay 0.5

  -- A single early frame can precede delayed workspace/recovery hydration.
  -- Require the same empty launcher for three continuous seconds before the
  -- operator is allowed to use this identity.
  repeat with sampleNumber from 1 to 20
    set censusResult to my exactLauncherCensus(targetPID, expectedBundleID, 2)
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

  return "FRESH_PROFILE_RESULT=PASS (stable 3s; one empty launcher; zero workspace/open files/recovery/recents)"
end run

on makeExactProcessFrontmost(targetPID, expectedBundleID, timeoutSeconds)
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

on exactLauncherCensus(targetPID, expectedBundleID, timeoutSeconds)
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

-- `whose unix id is ...` is unreliable in System Events on current macOS: it
-- can throw -1728 even while `unix id of every application process` contains
-- the PID. Iterate and compare the numeric property instead; authority remains
-- the exact PID verified from bundle + executable by the shell harness. The
-- AX lookup independently requires the expected bundle identifier as well.
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

on waitForProcess(targetPID, expectedBundleID, timeoutSeconds)
  repeat with i from 1 to (timeoutSeconds * 10)
    if my processForPID(targetPID, expectedBundleID) is not missing value then return true
    delay 0.1
  end repeat
  error "Timed out waiting for process pid=" & targetPID
end waitForProcess

on waitForWindow(targetPID, expectedBundleID, timeoutSeconds)
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
}

stage_failure_cleanup() {
  local original_status="$?"
  [[ "$STAGE_ACTIVE" -eq 1 ]] || return "$original_status"
  trap - EXIT INT TERM
  set +e
  if [[ -n "$STAGE_BUNDLE_ID" ]] \
    && isolated_app_assert_not_running "$STAGE_BUNDLE_ID" >/dev/null 2>&1; then
    if ! isolated_app_cleanup_manifest "$MANIFEST_PATH" "$MANUAL_ROOT"; then
      printf '\033[33m[manual-smoke]\033[0m staging cleanup failed; retained owner root and manifest for an exact retry:\n  root: %s\n  manifest: %s\n  retry: make manual-smoke-clean\n' \
        "$MANUAL_ROOT" "$MANIFEST_PATH" >&2
    fi
  else
    printf '\033[33m[manual-smoke]\033[0m staging failed after launch; retained the exact identity for inspection and retry:\n  root: %s\n  manifest: %s\n  retry: make manual-smoke-clean\n' \
      "$MANUAL_ROOT" "$MANIFEST_PATH" >&2
  fi
  exit "$original_status"
}

stage_command() {
  local source="${1:-$DEFAULT_SOURCE}"
  local source_commit source_version source_build bundle_id keychain_service display_name short_commit run_token
  local verified_pid
  source="$(canonical_existing_path "$source")" || die "source app not found: $source"
  source_commit="$(verify_source_bundle "$source")"
  source_version="$(isolated_app_plist_value \
    "$source/Contents/Info.plist" CFBundleShortVersionString)" || source_version="unknown"
  source_build="$(isolated_app_plist_value "$source/Contents/Info.plist" CFBundleVersion)" \
    || source_build="unknown"
  log "source=$source commit=$source_commit version=$source_version build=$source_build"

  cleanup_previous_manifested_identity
  /bin/mkdir -p "$MANUAL_ROOT"
  MANUAL_ROOT="$(cd "$MANUAL_ROOT" && pwd -P)"
  MANIFEST_PATH="$MANUAL_ROOT/identity.plist"

  bundle_id="$(isolated_app_generate_bundle_id manual)" \
    || die "could not mint a unique manual bundle identifier"
  run_token="${bundle_id##*.}"
  EXECUTABLE_NAME="Pmanual${run_token:1}"
  APP_PATH="$MANUAL_ROOT/$EXECUTABLE_NAME.app"
  SUPPORT_PATH="$MANUAL_ROOT/$run_token.state"
  [[ "$source" != "$APP_PATH" ]] || die "the staged manual app cannot be its own source"
  keychain_service="$bundle_id.completion-provider"
  short_commit="$(printf '%.8s' "$source_commit")"
  display_name="Pensieve Manual Smoke $short_commit"
  STAGE_BUNDLE_ID="$bundle_id"
  STAGE_ACTIVE=1
  trap stage_failure_cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  isolated_app_reserve_manifest \
    "$MANIFEST_PATH" "$MANUAL_ROOT" "$source" "$APP_PATH" "$EXECUTABLE_NAME" \
    "$bundle_id" "$display_name" "$SUPPORT_PATH" "$keychain_service" "$source_commit" \
    || die "could not reserve isolated cleanup authority"
  /bin/mkdir "$SUPPORT_PATH" \
    || die "could not create the canonical manual support directory"

  log "staging $source"
  isolated_app_stage_bundle \
    "$source" "$APP_PATH" "$EXECUTABLE_NAME" "$bundle_id" "$EXECUTABLE_NAME" \
    "$display_name" "$SUPPORT_PATH" "$keychain_service" "$REPO_ROOT" \
    "${PENSIEVE_MANUAL_SMOKE_ALLOW_STALE_SOURCE:-0}" \
    "${PENSIEVE_MANUAL_SMOKE_ALLOW_DIRTY_SOURCE:-0}" \
    || die "could not stage the isolated manual app"
  isolated_app_finalize_manifest "$MANIFEST_PATH" "$MANUAL_ROOT" \
    || die "could not finalize the isolated identity manifest"
  isolated_app_verify_bundle_from_manifest "$MANIFEST_PATH" "$MANUAL_ROOT" \
    || die "the staged bundle does not match identity.plist"
  isolated_app_assert_profile_fresh \
    "$bundle_id" "$SUPPORT_PATH" "$keychain_service" "$ISOLATED_APP_KEYCHAIN_ACCOUNT" \
    || die "the new manual identity is not a fresh profile"

  log "opening unique identity $bundle_id"
  isolated_app_open_new "$bundle_id" "$APP_PATH" "$SUPPORT_PATH" "$keychain_service" \
    || die "LaunchServices could not open the staged manual app"
  verified_pid="$(isolated_app_wait_for_running_identity \
    "$bundle_id" "$APP_PATH" "$APP_PATH/Contents/MacOS/$EXECUTABLE_NAME" 120)" \
    || die "the running process does not match the staged bundle and executable"
  log "runtime identity verified pid=$verified_pid"
  run_fresh_ui_baseline "$verified_pid" "$bundle_id" \
    || die "fresh launcher UI baseline failed"
  isolated_app_verify_running_identity \
    "$bundle_id" "$APP_PATH" "$APP_PATH/Contents/MacOS/$EXECUTABLE_NAME" >/dev/null \
    || die "the app identity changed during the UI baseline"

  STAGE_ACTIVE=0
  trap - EXIT INT TERM
  ok "fresh manual smoke is open"
  printf '  app:      %s\n' "$APP_PATH"
  printf '  manifest: %s\n' "$MANIFEST_PATH"
  printf '  bundle:   %s\n' "$bundle_id"
  printf '  source:   %s\n' "$source"
  printf '  commit:   %s\n' "$source_commit"
  printf '  version:  %s (%s)\n' "$source_version" "$source_build"
  printf '  signing:  %s\n' "$ISOLATED_APP_SIGNING_MODE"
}

verify_command() {
  [[ -f "$MANIFEST_PATH" ]] || die "no staged manual identity; run stage first"
  manifest_layout_is_manual || die "identity.plist is invalid or owns different paths"
  isolated_app_verify_bundle_from_manifest "$MANIFEST_PATH" "$MANUAL_ROOT" \
    || die "staged bundle does not match the manifest or its signature is invalid"
  local bundle_id executable_path pid running_status
  bundle_id="$(isolated_app_manifest_value "$MANIFEST_PATH" bundleID)"
  executable_path="$(isolated_app_manifest_value "$MANIFEST_PATH" executablePath)"
  if isolated_app_identity_is_running "$bundle_id"; then
    pid="$(isolated_app_verify_running_identity "$bundle_id" "$APP_PATH" "$executable_path")" \
      || die "a process uses this identity but not this exact bundle/executable"
    ok "static and runtime identity verified (pid=$pid)"
  else
    running_status=$?
    [[ "$running_status" -eq 1 ]] \
      || die "could not query NSRunningApplication for the staged identity"
    ok "staged bundle and manifest verified (app is not running)"
  fi
  printf '  app:    %s\n' "$APP_PATH"
  printf '  bundle: %s\n' "$bundle_id"
}

reopen_command() {
  verify_command
  local bundle_id service executable_path pid
  bundle_id="$(isolated_app_manifest_value "$MANIFEST_PATH" bundleID)"
  service="$(isolated_app_manifest_value "$MANIFEST_PATH" keychainService)"
  executable_path="$(isolated_app_manifest_value "$MANIFEST_PATH" executablePath)"
  isolated_app_reopen "$bundle_id" "$APP_PATH" "$SUPPORT_PATH" "$service" \
    || die "could not reopen the staged manual app"
  pid="$(isolated_app_wait_for_running_identity "$bundle_id" "$APP_PATH" "$executable_path" 120)" \
    || die "reopened process does not match the manifest"
  ok "manual smoke is open (pid=$pid); its existing manual test state was preserved"
}

terminate_manifested_identity() {
  local bundle_id="$1"
  local executable_path="$2"
  local pid="" status

  if isolated_app_identity_is_running "$bundle_id"; then
    pid="$(isolated_app_verify_running_identity \
      "$bundle_id" "$APP_PATH" "$executable_path")" \
      || die "the manifested identity is running from an unexpected bundle or executable"
  else
    status=$?
    [[ "$status" -eq 1 ]] \
      || die "could not query the manifested identity before cleanup"
    return 0
  fi

  log "terminating exact manual-smoke identity $bundle_id (pid=$pid)"
  if isolated_app_control_identity \
    terminate "$bundle_id" "$APP_PATH" "$executable_path" "$pid" 5; then
    return 0
  else
    status=$?
  fi
  case "$status" in
    3) return 0 ;;
    4) die "refusing termination because the exact runtime identity changed" ;;
    5) die "NSRunningApplication could not terminate the exact manual-smoke process" ;;
    *) die "could not terminate the exact manual-smoke identity (status=$status)" ;;
  esac
}

clean_command() {
  if [[ ! -e "$MANIFEST_PATH" ]]; then
    assert_no_unmanifested_artifacts
    ok "manual smoke is already clean"
    return 0
  fi
  manifest_layout_is_manual || die "identity.plist is invalid or owns different paths"
  local bundle_id executable_path
  bundle_id="$(isolated_app_manifest_value "$MANIFEST_PATH" bundleID)"
  executable_path="$(isolated_app_manifest_value "$MANIFEST_PATH" executablePath)"
  terminate_manifested_identity "$bundle_id" "$executable_path"
  isolated_app_cleanup_manifest "$MANIFEST_PATH" "$MANUAL_ROOT" \
    || die "could not completely clean the manifested manual identity"
  ok "removed the exact manual-smoke identity and profile"
}

command_name="${1:-}"
case "$command_name" in
  stage)
    [[ $# -le 2 ]] || die "stage accepts at most one source app"
    stage_command "${2:-$DEFAULT_SOURCE}"
    ;;
  reopen)
    [[ $# -eq 1 ]] || die "reopen accepts no arguments"
    reopen_command
    ;;
  verify)
    [[ $# -eq 1 ]] || die "verify accepts no arguments"
    verify_command
    ;;
  clean)
    [[ $# -eq 1 ]] || die "clean accepts no arguments"
    clean_command
    ;;
  -h | --help | help | "")
    usage
    [[ -n "$command_name" ]] || exit 2
    ;;
  *)
    usage >&2
    die "unknown command: $command_name"
    ;;
esac
