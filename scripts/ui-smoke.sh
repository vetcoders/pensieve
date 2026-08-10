#!/usr/bin/env bash
set -euo pipefail

# The harness never drives the bundle the operator actually uses. It stages a
# renamed, re-signed copy under $SMOKE_ROOT and drives that instead, so the two
# identities the run touches -- the process name every pkill/System Events call
# resolves, and the defaults domain cfprefsd scopes reads and writes to -- both
# belong to the smoke alone. Before this, `pkill -x Pensieve` killed the
# operator's live app by name, and every harness launch wrote its temp-file
# bookmarks into the operator's io.vetcoders.pensieve domain until her real Open
# Files entries were evicted.
SOURCE_APP_PATH="dist/Pensieve.app"
APP_PATH=""
APP_NAME="PensieveSmoke"
APP_ID="io.vetcoders.pensieve.smoke"
SMOKE_SIGNING_MODE=""
COLD_ONLY=0
MENU_RESTORED_ONLY=0
EXTRA_EXPECTED_IDENTIFIERS=()

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

# Shell out to a tiny Swift snippet that queries CoreGraphics' window server
# directly, bypassing the Accessibility tree entirely. Used only to classify a
# census failure: an empty AX census can mean the app truly has no window (a
# real product FAIL) or that its window exists but is offscreen because the
# active Space cannot host it (e.g. a fullscreen Screen Sharing session) --
# an environment condition, not a product bug.
dump_window_server_state() {
  SMOKE_OWNER_NAME="$APP_NAME" swift - <<'EOF' 2>/dev/null || true
import CoreGraphics
import Foundation
// Passed through the environment rather than interpolated: the heredoc is
// quoted so the snippet stays a literal, and the owner name is the staged
// smoke bundle's, never the operator's app.
let owner = ProcessInfo.processInfo.environment["SMOKE_OWNER_NAME"] ?? "PensieveSmoke"
let wl = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
var total = 0, onscreen = 0
for w in wl where (w["kCGWindowOwnerName"] as? String) == owner
  && (w["kCGWindowLayer"] as? Int) == 0 {
  total += 1
  if (w["kCGWindowIsOnscreen"] as? Bool) == true { onscreen += 1 }
  print("CGWINDOW num=\(w["kCGWindowNumber"] ?? "?") name=\(w["kCGWindowName"] ?? "-") onscreen=\(w["kCGWindowIsOnscreen"] ?? false)")
}
print("CGWINDOW_SUMMARY total=\(total) onscreen=\(onscreen)")
EOF
}

# Terminate every running instance of the app under test and block until the
# process table is clear. AppleScript targets the app by bare process name
# ("tell process PensieveSmoke"), and System Events resolves that name to the
# OLDEST matching process. A run that dies mid-osascript leaves an orphaned,
# windowless instance alive; the next run's `open -n` then spawns a second one,
# and the census locks onto the windowless orphan -> empty `observed:` census.
# Guaranteeing a single instance (clean before launch, clean on every exit)
# removes that ambiguity at the source. Graceful quit first, then SIGTERM, then
# SIGKILL as a last resort, waiting for the process to actually disappear at
# each stage so `open -n` never races a survivor.
terminate_app() {
  osascript -e "with timeout of 2 seconds" \
    -e "tell application id \"$APP_ID\" to quit" \
    -e "end timeout" >/dev/null 2>&1 || true
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
  for _ in {1..30}; do
    pgrep -x "$APP_NAME" >/dev/null 2>&1 || return 0
    sleep 0.1
  done
  pkill -9 -x "$APP_NAME" >/dev/null 2>&1 || true
  for _ in {1..20}; do
    pgrep -x "$APP_NAME" >/dev/null 2>&1 || return 0
    sleep 0.1
  done
  if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
    printf '\033[33m[fail]\033[0m %s\n' \
      "$APP_NAME survived SIGKILL; a live survivor would corrupt the next run's single-instance census" >&2
    return 1
  fi
  return 0
}

# Run an Accessibility AppleScript with GNU timeout when available. A function
# keeps the no-timeout path explicit; expanding an empty command-prefix array is
# an `unbound variable` error under macOS' Bash 3.2 when `set -u` is active.
run_ax_osascript() {
  local timeout_seconds="$1"
  shift
  if command -v gtimeout >/dev/null 2>&1; then
    gtimeout --signal=TERM "$timeout_seconds" osascript "$@"
  else
    osascript "$@"
  fi
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

arm_pensieve_restore_off() {
  if [[ "$PENSIEVE_RESTORE_DEFAULT_ARMED" -eq 1 ]]; then
    defaults write "$APP_ID" Pensieve.restoreSessionOnLaunch -bool false
    return 0
  fi
  if PRIOR_PENSIEVE_RESTORE="$(defaults read "$APP_ID" Pensieve.restoreSessionOnLaunch 2>/dev/null)"; then
    PENSIEVE_RESTORE_WAS_SET=1
  else
    PENSIEVE_RESTORE_WAS_SET=0
    PRIOR_PENSIEVE_RESTORE=""
  fi
  defaults write "$APP_ID" Pensieve.restoreSessionOnLaunch -bool false
  PENSIEVE_RESTORE_DEFAULT_ARMED=1
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
  open --env "PENSIEVE_SUPPORT_DIR=$SMOKE_SUPPORT" "$@"
}

plist_set_string() {
  local plist="$1" key="$2" value="$3"
  /usr/libexec/PlistBuddy -c "Set :$key $value" "$plist" >/dev/null 2>&1 \
    || /usr/libexec/PlistBuddy -c "Add :$key string $value" "$plist" >/dev/null \
    || die "could not set $key in $plist"
}

# Build the isolated bundle the whole run drives: a copy of the app under test
# with a smoke-only identity.
#
# Three things have to change together, because each one closes a different
# leak. The EXECUTABLE name is what the kernel reports as the process name, so
# `pkill -x` / `pgrep -x` / `tell process` resolve the smoke and can never reach
# the operator's running app. The BUNDLE IDENTIFIER is what cfprefsd keys
# preferences on, so every default the app reads or writes -- including the
# workspace file bookmarks that a harness run kept appending -- lands in
# io.vetcoders.pensieve.smoke. And PENSIEVE_SUPPORT_DIR redirects the four
# Application Support derivations, which the other two cannot reach:
# NSHomeDirectory() reads getpwuid, so FileManager resolves the operator's real
# ~/Library/Application Support no matter what identity the bundle carries.
#
# The override is written into the staged Info.plist as LSEnvironment (the app
# gets it however LaunchServices starts it) and passed again on each `open
# --env` (belt and braces if a staged bundle's LSEnvironment is ever ignored).
stage_smoke_app() {
  local source="$1" staged="$2" support="$3"
  local contents="$staged/Contents"
  local plist="$contents/Info.plist"

  rm -rf "$staged"
  # ditto, not cp -R: it is the tool that copies a bundle's extended attributes
  # and resource forks intact, which a code-signed bundle depends on.
  ditto "$source" "$staged" || die "could not stage a smoke copy of $source"
  [[ -f "$plist" ]] || die "staged bundle has no Info.plist: $plist"

  local source_executable
  source_executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$plist" 2>/dev/null)"
  [[ -n "$source_executable" ]] || die "source bundle declares no CFBundleExecutable: $source"
  if [[ "$source_executable" != "$APP_NAME" ]]; then
    mv "$contents/MacOS/$source_executable" "$contents/MacOS/$APP_NAME" \
      || die "could not rename the staged executable to $APP_NAME"
  fi

  plist_set_string "$plist" CFBundleExecutable "$APP_NAME"
  plist_set_string "$plist" CFBundleIdentifier "$APP_ID"
  plist_set_string "$plist" CFBundleName "$APP_NAME"
  plist_set_string "$plist" CFBundleDisplayName "$APP_NAME"
  /usr/libexec/PlistBuddy -c "Delete :LSEnvironment" "$plist" >/dev/null 2>&1 || true
  /usr/libexec/PlistBuddy -c "Add :LSEnvironment dict" "$plist" >/dev/null \
    || die "could not add LSEnvironment to $plist"
  /usr/libexec/PlistBuddy -c "Add :LSEnvironment:PENSIEVE_SUPPORT_DIR string $support" "$plist" \
    >/dev/null || die "could not set PENSIEVE_SUPPORT_DIR in $plist"

  # Every edit above broke the inherited seal, so the copy has to be signed
  # again or macOS refuses to launch it. Developer ID when the same identity
  # build-release.sh uses is in the keychain, ad-hoc otherwise -- this is a
  # locally staged copy that never leaves the machine, so either is enough.
  rm -rf "$contents/_CodeSignature"
  local identity="" identity_file="$HOME/.keys/signing-identity.txt"
  if [[ -f "$identity_file" ]]; then
    identity="$(head -n1 "$identity_file" | sed -e 's/[[:space:]]*$//')"
    if [[ -n "$identity" ]] \
      && ! security find-identity -v -p codesigning | grep -qF -- "$identity"; then
      identity=""
    fi
  fi
  if [[ -n "$identity" ]] && codesign --force --deep --sign "$identity" "$staged" >/dev/null 2>&1
  then
    SMOKE_SIGNING_MODE="Developer ID ($identity)"
  else
    [[ -n "$identity" ]] && log "Developer ID re-sign failed; falling back to ad-hoc"
    codesign --force --deep --sign - "$staged" >/dev/null 2>&1 \
      || die "could not sign the staged smoke bundle"
    SMOKE_SIGNING_MODE="ad-hoc"
  fi
  codesign --verify --strict "$staged" >/dev/null 2>&1 \
    || die "staged smoke bundle failed codesign --verify; it would not launch"
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

  local document_title="${SMOKE_DOCUMENT##*/}"
  document_title="${document_title%.md}"

  log "saved-state probe: launch #1 with document [$document_title]"
  open_smoke_app -a "$APP_PATH" "$SMOKE_DOCUMENT" || {
    sleep 0.5
    open_smoke_app -a "$APP_PATH" "$SMOKE_DOCUMENT"
  }

  local _
  for _ in {1..120}; do
    pgrep -x "$APP_NAME" >/dev/null 2>&1 && break
    sleep 0.1
  done
  pgrep -x "$APP_NAME" >/dev/null 2>&1 \
    || die "saved-state probe: document launch never started $APP_NAME"

  run_ax_osascript 45 - "$APP_NAME" "$document_title" <<'APPLESCRIPT'
on run argv
  set appName to item 1 of argv
  set documentTitle to item 2 of argv
  my waitForProcess(appName, 15)
  my waitForWindow(appName, 15)

  tell application "System Events" to tell process appName
    set frontmost to true
    delay 0.5
    set allTitles to title of every window
  end tell

  repeat with candidateTitle in allTitles
    if (candidateTitle as text) contains documentTitle then
      log "SAVED_STATE_PRECONDITION=PASS title=[" & (candidateTitle as text) & "]"
      return "document window established"
    end if
  end repeat
  error "saved-state probe precondition failed: no document window titled [" & documentTitle & "] in {" & my joined(allTitles, ",") & "}"
end run

on waitForProcess(appName, timeoutSeconds)
  tell application "System Events"
    repeat with i from 1 to (timeoutSeconds * 10)
      if exists process appName then return true
      delay 0.1
    end repeat
  end tell
  error "Timed out waiting for " & appName
end waitForProcess

on waitForWindow(appName, timeoutSeconds)
  tell application "System Events" to tell process appName
    repeat with i from 1 to (timeoutSeconds * 10)
      if (count of windows) > 0 then return true
      delay 0.1
    end repeat
  end tell
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
  osascript -e "with timeout of 5 seconds" \
    -e "tell application id \"$APP_ID\" to quit" \
    -e "end timeout" >/dev/null 2>&1 || true
  for _ in {1..60}; do
    pgrep -x "$APP_NAME" >/dev/null 2>&1 || break
    sleep 0.1
  done
  if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
    pkill -x "$APP_NAME" >/dev/null 2>&1 || true
    sleep 0.5
  fi

  log "saved-state probe: relaunch with Pensieve restore still OFF"
  open_smoke_app -a "$APP_PATH" || {
    sleep 0.5
    open_smoke_app -a "$APP_PATH"
  }
  for _ in {1..120}; do
    pgrep -x "$APP_NAME" >/dev/null 2>&1 && break
    sleep 0.1
  done
  pgrep -x "$APP_NAME" >/dev/null 2>&1 \
    || die "saved-state probe: relaunch never started $APP_NAME"

  run_ax_osascript 60 - "$APP_NAME" "$document_title" <<'APPLESCRIPT'
on run argv
  set appName to item 1 of argv
  set forbiddenDocumentTitle to item 2 of argv
  my waitForProcess(appName, 15)
  my waitForWindow(appName, 15)

  tell application "System Events" to tell process appName
    set frontmost to true
    delay 0.8
    set windowCount to count of windows
    set allTitles to title of every window
    set menuNames to name of every menu bar item of menu bar 1
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

on waitForProcess(appName, timeoutSeconds)
  tell application "System Events"
    repeat with i from 1 to (timeoutSeconds * 10)
      if exists process appName then return true
      delay 0.1
    end repeat
  end tell
  error "Timed out waiting for " & appName
end waitForProcess

on waitForWindow(appName, timeoutSeconds)
  tell application "System Events" to tell process appName
    repeat with i from 1 to (timeoutSeconds * 10)
      if (count of windows) > 0 then return true
      delay 0.1
    end repeat
  end tell
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

  open_smoke_app -a "$APP_PATH" || {
    sleep 0.5
    open_smoke_app -a "$APP_PATH"
  }

  run_ax_osascript 45 - "$APP_NAME" <<'APPLESCRIPT'
on run argv
  set appName to item 1 of argv
  my waitForProcess(appName, 15)
  my waitForWindow(appName, 15)

  tell application "System Events" to tell process appName
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

on waitForProcess(appName, timeoutSeconds)
  tell application "System Events"
    repeat with i from 1 to (timeoutSeconds * 10)
      if exists process appName then return true
      delay 0.1
    end repeat
  end tell
  error "Timed out waiting for " & appName
end waitForProcess

on waitForWindow(appName, timeoutSeconds)
  tell application "System Events" to tell process appName
    repeat with i from 1 to (timeoutSeconds * 10)
      if (count of windows) > 0 then return true
      delay 0.1
    end repeat
  end tell
  error "Timed out waiting for a window"
end waitForWindow
APPLESCRIPT

  pgrep -x "$APP_NAME" >/dev/null 2>&1 \
    || die "closing the final window terminated $APP_NAME instead of leaving a zero-window process"

  # `open` can return -600 while LaunchServices is reconnecting to a just-
  # windowless process even when the event is delivered. The AX assertion below
  # is the source of truth; do not retry and risk sending the same URL twice.
  open_smoke_app -a "$APP_PATH" "$SMOKE_EXTERNAL_DOCUMENT" >/dev/null 2>&1 || true

  local external_title="${SMOKE_EXTERNAL_DOCUMENT##*/}"
  external_title="${external_title%.md}"
  run_ax_osascript 45 - "$APP_NAME" "$external_title" <<'APPLESCRIPT'
on run argv
  set appName to item 1 of argv
  set documentTitle to item 2 of argv
  my waitForProcess(appName, 15)
  my waitForWindow(appName, 15)

  tell application "System Events" to tell process appName
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

on waitForProcess(appName, timeoutSeconds)
  tell application "System Events"
    repeat with i from 1 to (timeoutSeconds * 10)
      if exists process appName then return true
      delay 0.1
    end repeat
  end tell
  error "Timed out waiting for " & appName
end waitForProcess

on waitForWindow(appName, timeoutSeconds)
  tell application "System Events" to tell process appName
    repeat with i from 1 to (timeoutSeconds * 10)
      if (count of windows) > 0 then return true
      delay 0.1
    end repeat
  end tell
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
# inconclusive -- the witness window exists but is offscreen (e.g. active
# Space unavailable) rather than a genuine census FAIL. Never treat 3 as a
# PASS; re-run once a normal desktop Space is active.
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

# Real AX clicks require the display to be awake; a sleeping display
# (displaysleep) makes popover clicks land randomly, so wake it now and
# hold it awake for the duration of the smoke to keep this deterministic
# on an unattended machine.
caffeinate -u -t 2 || true
caffeinate -dsu &
CAFFEINATE_PID=$!

SOURCE_APP_PATH="$(cd "$(dirname "$SOURCE_APP_PATH")" && pwd)/$(basename "$SOURCE_APP_PATH")"
SMOKE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/pensieve-toolbar-smoke.XXXXXX")"
SMOKE_DOCUMENT="$SMOKE_ROOT/toolbar-cold.md"
SMOKE_EXTERNAL_DOCUMENT="$SMOKE_ROOT/external-after-zero-windows.md"
SMOKE_SUPPORT="$SMOKE_ROOT/support"
cleanup() {
  local cleanup_status=0
  local step_status=0
  kill "$CAFFEINATE_PID" 2>/dev/null || true
  # Every exit path -- success, assertion failure, or an error raised inside
  # osascript -- must leave zero live smoke processes, otherwise the survivor
  # becomes the orphan that corrupts the next run's census.
  terminate_app
  step_status=$?
  if [[ "$cleanup_status" -eq 0 && "$step_status" -ne 0 ]]; then
    cleanup_status="$step_status"
  fi
  # Revert any smoke-domain defaults the saved-state probe armed. They were
  # never written to the operator's domain, but leaving it set would make the
  # next run's restoration state depend on the previous one.
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
  # The staged bundle, its Application Support tree and the witness document
  # all live under SMOKE_ROOT; the run owns that directory outright.
  if [[ -n "${SMOKE_ROOT:-}" && "$SMOKE_ROOT" == */pensieve-toolbar-smoke.* ]]; then
    rm -rf "$SMOKE_ROOT"
    step_status=$?
    if [[ "$cleanup_status" -eq 0 && "$step_status" -ne 0 ]]; then
      cleanup_status="$step_status"
    fi
  fi
  return "$cleanup_status"
}

# Bash 3.2 can replace a failing main-script status with the final successful
# command from an EXIT trap. Preserve the original status explicitly: a smoke
# that aborts before launching the app must never be reported as green merely
# because cleanup succeeded.
on_exit() {
  local original_status="$?"
  local cleanup_status=0
  trap - EXIT
  set +e
  cleanup
  cleanup_status=$?
  if [[ "$original_status" -ne 0 ]]; then
    exit "$original_status"
  fi
  exit "$cleanup_status"
}
trap on_exit EXIT

mkdir -p "$SMOKE_SUPPORT"
APP_PATH="$SMOKE_ROOT/$APP_NAME.app"
stage_smoke_app "$SOURCE_APP_PATH" "$APP_PATH" "$SMOKE_SUPPORT"
printf '# Toolbar cold-frame witness\n\nEditable staged document.\n' >"$SMOKE_DOCUMENT"
printf '# External open after zero windows\n' >"$SMOKE_EXTERNAL_DOCUMENT"

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
  pensieve.toolbar.appearance
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
EXECUTABLE_PATH="$APP_PATH/Contents/MacOS/$APP_NAME"
log "source bundle=$SOURCE_APP_PATH commit=$BUNDLE_COMMIT version=$BUNDLE_VERSION build=$BUNDLE_BUILD"
log "staged bundle=$APP_PATH executable=$EXECUTABLE_PATH id=$APP_ID signature=$SMOKE_SIGNING_MODE"
log "isolated support dir=$SMOKE_SUPPORT (PENSIEVE_SUPPORT_DIR)"

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
on waitForProcess(appName, timeoutSeconds)
  tell application "System Events"
    repeat with i from 1 to (timeoutSeconds * 10)
      if exists process appName then return true
      delay 0.1
    end repeat
  end tell
  error "Timed out waiting for " & appName
end waitForProcess

on waitForWindow(appName, timeoutSeconds)
  tell application "System Events"
    tell process appName
      repeat with i from 1 to (timeoutSeconds * 10)
        if (count of windows) > 0 then return true
        delay 0.1
      end repeat
    end tell
  end tell
  error "Timed out waiting for a visible window"
end waitForWindow

on toolbarCensus(appName)
  -- Census the WINDOW UNDER TEST — always `window 1`, the frontmost/key window
  -- that receives the menu-driven mode changes and whose geometry the geometry
  -- assertions pin. The rest of this script already operates on `window 1`
  -- (geometry reads, the Preview Appearance control lookup), so the census must
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
    tell application "System Events"
      tell process appName
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

on assertWindowGeometry(appName, expectedPosition, expectedSize, stateName)
  tell application "System Events" to tell process appName
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
on settledToolbarCensus(appName, expectedIdentifiers, excludedIdentifiers, timeoutTenths)
  set stableCount to 0
  set latestCensus to {}
  set latestMissing to {}
  set latestUnexpected to {}
  repeat with i from 1 to timeoutTenths
    set latestCensus to my toolbarCensus(appName)
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
  if (count of latestUnexpected) > 0 then
    error "Toolbar census unexpectedly exposes: " & my joined(latestUnexpected, ", ") & ¬
      "; observed: " & my joined(latestCensus, ", ")
  end if
  error "Cold toolbar census missing identifiers: " & my joined(latestMissing, ", ") & ¬
    "; observed: " & my joined(latestCensus, ", ")
end settledToolbarCensus

on assertMenuItem(appName, menuName, itemName)
  tell application "System Events"
    tell process appName
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

on toolbarElementByAccessibleName(appName, targetName)
  -- AX attribute propagation can lag behind the identifier-based toolbar
  -- census: a control can exist (and already show up by identifier) before
  -- its localized accessible name is queryable. Retry with a bounded backoff
  -- instead of failing on the first miss.
  repeat with attemptNumber from 1 to 5
    tell application "System Events"
      tell process appName
        set toolbarElements to entire contents of toolbar 1 of window 1
        repeat with elementRef in toolbarElements
          set elementDescription to ""
          set elementTitle to ""
          try
            set elementDescription to get description of elementRef
          end try
          try
            set elementTitle to get title of elementRef
          end try
          -- macOS 27 exposes native SwiftUI toolbar menu names through
          -- AXTitle while AXDescription remains the generic "menu button".
          -- Older bridges used AXDescription. Require the exact authored name
          -- in either standard accessible-name slot so a raw symbol name or an
          -- anonymous menu still fails this assertion.
          if elementDescription is targetName or elementTitle is targetName then
            return contents of elementRef
          end if
        end repeat
      end tell
    end tell
    if attemptNumber < 5 then delay 1
  end repeat
  error "Missing toolbar control with accessible name: " & targetName
end toolbarElementByAccessibleName

on windowElementByIdentifier(appName, targetIdentifier, timeoutTenths)
  repeat with attemptNumber from 1 to timeoutTenths
    tell application "System Events" to tell process appName
      set windowElements to entire contents of window 1
      repeat with elementRef in windowElements
        try
          set identifierValue to value of attribute "AXIdentifier" of elementRef
          if identifierValue is targetIdentifier then return contents of elementRef
        end try
      end repeat
    end tell
    delay 0.1
  end repeat
  error "Timed out waiting for window element: " & targetIdentifier
end windowElementByIdentifier

on run argv
set appName to item 1 of argv
set coldOnly to item 2 of argv is "1"
set baseExpectedCount to item 3 of argv as integer
set expectedIdentifiers to items 4 thru -1 of argv
set baseExpectedIdentifiers to items 4 thru (3 + baseExpectedCount) of argv
my waitForProcess(appName, 12)
my waitForWindow(appName, 12)

-- Resolve the exact running instance's PID once, up front, via System
-- Events process identity (not an app-name activate). Reused below so every
-- later re-activation targets this specific process instead of letting
-- LaunchServices resolve "Pensieve" by name, which could pick a different
-- installed copy (dist/ vs /Applications) sharing that display name.
tell application "System Events" to set targetPID to unix id of process appName

-- NO-STIMULUS BOUNDARY: from process discovery through this census, the
-- harness only reads AX state and waits. It does not activate/focus the app,
-- click, move the pointer, resize, raise a menu, or mutate window geometry.
set coldCensus to my settledToolbarCensus(appName, baseExpectedIdentifiers, {}, 80)
set missingItems to my missingIdentifiers(coldCensus, expectedIdentifiers)
if (count of missingItems) > 0 then
  error "Cold toolbar census missing identifiers: " & my joined(missingItems, ", ") & ¬
    "; observed: " & my joined(coldCensus, ", ")
end if
tell application "System Events" to tell process appName
  set coldPosition to position of window 1
  set coldSize to size of window 1
end tell
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
tell application "System Events"
  set frontmost of (first process whose unix id is targetPID) to true
end tell
delay 0.5

assertMenuItem(appName, "File", "New File…")
assertMenuItem(appName, "File", "Open File…")
assertMenuItem(appName, "File", "Open Recent")
assertMenuItem(appName, "File", "Open Folder…")
assertMenuItem(appName, "File", "Close")
assertMenuItem(appName, "Mode", "Source Mode")
assertMenuItem(appName, "Mode", "Split Mode")
assertMenuItem(appName, "Format", "Bold")
assertMenuItem(appName, "Format", "Link")
-- Dispatch entry points are menu rows that only open the confirmation sheet
-- (W3-A gateway); their presence in the menu bar is part of the P0 contract.
assertMenuItem(appName, "Agents", "Dispatch Document to Agent…")
assertMenuItem(appName, "Agents", "Dispatch Document with Workflow")

set editingIdentifiers to {¬
  "pensieve.toolbar.undo", "pensieve.toolbar.redo", ¬
  "pensieve.toolbar.richMarkdownToggle", "pensieve.toolbar.format.bold", ¬
  "pensieve.toolbar.format.strike", "pensieve.toolbar.format.italic", ¬
  "pensieve.toolbar.format.quote", "pensieve.toolbar.format.code", ¬
  "pensieve.toolbar.format.link", "pensieve.toolbar.format.bulletedList", ¬
  "pensieve.toolbar.format.numberedList"}
set previewExpectedIdentifiers to my identifiersExcluding(baseExpectedIdentifiers, editingIdentifiers)

tell application "System Events"
  tell process appName
    -- Put the preview surface on screen so the appearance control is part of
    -- the live toolbar, then prove it is a native menu that actually opens.
    -- A plain button backed by transient SwiftUI popover state can still pass
    -- static identifier tests while swallowing the first click and flickering
    -- closed on the second.
    tell menu bar 1
      tell menu bar item "Mode"
        click
        delay 0.2
        click menu item "Split Mode" of menu 1
      end tell
    end tell
    delay 0.5

    set splitCensus to my settledToolbarCensus(appName, baseExpectedIdentifiers, {}, 40)
    my assertWindowGeometry(appName, coldPosition, coldSize, "split transition")
    log "AX_CENSUS_SPLIT=" & my joined(splitCensus, ",")

    tell menu bar 1
      tell menu bar item "Mode"
        click
        delay 0.2
        click menu item "Preview Mode" of menu 1
      end tell
    end tell
    delay 0.5
    set previewCensus to my settledToolbarCensus(appName, previewExpectedIdentifiers, editingIdentifiers, 40)
    my assertWindowGeometry(appName, coldPosition, coldSize, "preview transition")
    log "AX_CENSUS_PREVIEW=" & my joined(previewCensus, ",")

    tell menu bar 1
      tell menu bar item "Mode"
        click
        delay 0.2
        click menu item "Split Mode" of menu 1
      end tell
    end tell
    delay 0.5
    set splitCensus to my settledToolbarCensus(appName, baseExpectedIdentifiers, {}, 40)
    my assertWindowGeometry(appName, coldPosition, coldSize, "split restore")

    set appearanceControl to my toolbarElementByAccessibleName(appName, "Preview Appearance")
    if (role of appearanceControl) is not "AXMenuButton" then
      error "Preview Appearance must be a native menu button, got " & (role of appearanceControl)
    end if

    click appearanceControl
    delay 0.3
    if (count of menus of appearanceControl) is 0 then
      error "Preview Appearance menu did not open after click"
    end if
    set appearanceItems to get name of every menu item of menu 1 of appearanceControl
    if appearanceItems does not contain "Flavor" then
      error "Preview Appearance menu is missing the Flavor picker"
    end if
    if appearanceItems does not contain "Theme" then
      error "Preview Appearance menu is missing the Theme picker"
    end if
    key code 53
    delay 0.5

    -- Dismissing a native menu invalidates its AXUIElement; reacquiring the
    -- toolbar control mirrors a later user click instead of testing a stale
    -- Accessibility handle.
    set appearanceControl to my toolbarElementByAccessibleName(appName, "Preview Appearance")
    click appearanceControl
    delay 0.3
    if (count of menus of appearanceControl) is 0 then
      error "Preview Appearance menu did not reopen after dismissal"
    end if
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
    set rewriteControl to my toolbarElementByAccessibleName(appName, "Rewrite with AI")
    if (role of rewriteControl) is not "AXMenuButton" then
      error "Rewrite with AI must be a native menu button, got " & (role of rewriteControl)
    end if
    if enabled of rewriteControl then
      click rewriteControl
      delay 0.3
      if (count of menus of rewriteControl) is 0 then
        error "Rewrite with AI menu did not open after click"
      end if
      set rewriteItems to get name of every menu item of menu 1 of rewriteControl
      if rewriteItems does not contain "Improve Writing" then
        error "Rewrite with AI menu is missing Improve Writing"
      end if
      if rewriteItems does not contain "Fix Grammar" then
        error "Rewrite with AI menu is missing Fix Grammar"
      end if
      key code 53
    end if

    tell menu bar 1
      tell menu bar item "File"
        click
        delay 0.2
        click menu item "New File…" of menu 1
      end tell
    end tell
    delay 0.5
    set untitledCensus to my settledToolbarCensus(appName, baseExpectedIdentifiers, {}, 40)
    my assertWindowGeometry(appName, coldPosition, coldSize, "file-backed to untitled transition")
    log "AX_CENSUS_UNTITLED=" & my joined(untitledCensus, ",")

    -- A toolbar census can prove the editing chrome exists while missing the
    -- product failure this probe is for: a native Untitled tab whose body is
    -- still the launcher. Resolve the actual NSTextView, make it first responder,
    -- type through the real responder chain, and require the model-backed AX
    -- value to change. `click editorElement` is not a physical mouse click:
    -- System Events asks the element for AXPress, which NSTextView does not
    -- implement on macOS 27, so it can leave the previous control focused even
    -- though normal in-app clicking works.
    set editorElement to my windowElementByIdentifier(appName, "pensieve.editor", 50)
    set focused of editorElement to true
    if focused of editorElement is not true then
      error "Untitled editor refused first-responder focus"
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

    if (count of windows) is 0 then error appName & " has no windows after menu probing"
  end tell
end tell


tell application "Finder" to activate
delay 0.3
-- Reactivate the exact resolved PID (see targetPID above), not the app name,
-- so this regain step re-focuses the process under test unambiguously.
tell application "System Events"
  set frontmost of (first process whose unix id is targetPID) to true
  tell process appName
    perform action "AXRaise" of window 1
  end tell
end tell
delay 0.5
set regainCensus to my settledToolbarCensus(appName, baseExpectedIdentifiers, {}, 40)
my assertWindowGeometry(appName, coldPosition, coldSize, "key-window regain/redraw")
log "AX_CENSUS_REGAIN_REDRAW=" & my joined(regainCensus, ",")
end run
APPLESCRIPT

ax_census_output=$(run_ax_osascript 60 "$ax_census_script" "$APP_NAME" "$COLD_ONLY" "$BASE_EXPECTED_IDENTIFIER_COUNT" \
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
  ax_census_env_pattern='observed:  \(-2700\)|observed: ;'
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

ok "native UI smoke passed"

# --toolbar-cold-only returns after the cold census (the toolbar AppleScript
# exits early but bash falls through to here), so the saved-state probe runs
# only on a full pass. The toolbar phase leaves an activated instance running;
# the probe manages its own launch/quit/relaunch cycle, starting with
# terminate_app.
if [[ $COLD_ONLY -eq 0 ]]; then
  run_saved_state_isolation_probe
  ok "Saved Application State isolation probe passed"
  run_zero_window_external_open_probe
  ok "Zero-window external-open probe passed"
fi
