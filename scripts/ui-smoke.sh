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

# Restored-window menu-bar probe state. The probe forces state restoration to be
# deterministic by writing NSQuitAlwaysKeepsWindows into the app's OWN defaults
# domain for the duration of the run, then reverting to the pre-run state on
# exit so the operator's real preferences are left untouched. QAKW = the
# NSQuitAlwaysKeepsWindows key.
RESTORATION_DEFAULT_ARMED=0
QAKW_WAS_SET=0
PRIOR_QAKW=""

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
  pgrep -x "$APP_NAME" >/dev/null 2>&1 && die "$APP_NAME survived SIGKILL; a live survivor would corrupt the next run's single-instance census"
  return 0
}

# Force macOS/SwiftUI state restoration to fire on the next launch regardless of
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
    defaults write "$APP_ID" NSQuitAlwaysKeepsWindows -bool "$PRIOR_QAKW" 2>/dev/null || true
  else
    defaults delete "$APP_ID" NSQuitAlwaysKeepsWindows 2>/dev/null || true
  fi
  RESTORATION_DEFAULT_ARMED=0
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

# P1-02 arbiter. The value-based `WindowGroup(for: DocumentRef.self)` in
# PensieveApp.swift carries no `.commands` of its own; review feared a window
# restored INTO that group would surface a default menu bar without our custom
# Mode/Format/Agents menus. The rebuttal: SwiftUI assembles ONE app-wide menu
# bar from the whole scene tree, owned by the launcher group's `.commands`, so a
# restored value-based scene inherits it. This probe delivers the runtime proof:
# it drives a real restoration round-trip (launch -> graceful quit persists the
# scene -> relaunch reopens it) and asserts the process menu bar exposes our
# custom command surface while the RESTORED window is key.
#
# Note on scope: current builds open documents through the AppKit factory
# (DocumentWindowRegistry), never `openWindow(value:)`, so a fresh document
# cannot seed a NEW value-based scene. The value-based group is only ever fed by
# a pre-existing (legacy) persisted scene. When the host has such a scene the
# probe asserts against it; when it does not, the only window that comes back is
# the launcher (which owns `.commands` and is not the surface under dispute), so
# the probe SKIPs green rather than asserting on the wrong window. The AppleScript
# classifies the two by the key window's title.
run_restored_menu_probe() {
  log "restored-window menu-bar probe (P1-02 arbiter: value-based WindowGroup scene)"
  arm_restoration_default

  local restored_ax_runner=()
  if command -v gtimeout >/dev/null 2>&1; then
    restored_ax_runner=(gtimeout --signal=TERM 90)
  fi

  # Clear whatever instance an earlier phase left behind so `open` yields exactly
  # one process and the bare-name AppleScript target is unambiguous.
  terminate_app

  # Launch WITHOUT a document; SwiftUI restores the persisted value-based
  # WindowGroup scene. A LaunchServices race can return -600 right after the
  # prior terminate; one bounded retry clears it.
  log "restored-probe: launch #1 (no document) to open the restorable scene"
  open_smoke_app -a "$APP_PATH" || {
    sleep 0.5
    open_smoke_app -a "$APP_PATH"
  }
  local _
  for _ in {1..120}; do
    pgrep -x "$APP_NAME" >/dev/null 2>&1 && break
    sleep 0.1
  done
  pgrep -x "$APP_NAME" >/dev/null 2>&1 || die "restored-probe: launch #1 never started $APP_NAME"
  sleep 3

  # Graceful quit persists the open scene (NSQuitAlwaysKeepsWindows armed above).
  log "restored-probe: graceful quit to persist restoration state"
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

  # Relaunch: macOS reopens the persisted scene as the RESTORED window under test.
  log "restored-probe: relaunch and assert restored-window menu bar"
  open_smoke_app -a "$APP_PATH" || {
    sleep 0.5
    open_smoke_app -a "$APP_PATH"
  }
  for _ in {1..120}; do
    pgrep -x "$APP_NAME" >/dev/null 2>&1 && break
    sleep 0.1
  done
  pgrep -x "$APP_NAME" >/dev/null 2>&1 || die "restored-probe: relaunch never started $APP_NAME"

  "${restored_ax_runner[@]}" osascript - "$APP_NAME" <<'APPLESCRIPT'
on run argv
  set appName to item 1 of argv
  my waitForProcess(appName, 15)
  my waitForWindow(appName, 15)

  -- Focus the restored process explicitly so the key window (and thus the
  -- app-wide menu bar it is serviced by) is the one under assertion.
  tell application "System Events" to set targetPID to unix id of process appName
  tell application "System Events"
    set frontmost of (first process whose unix id is targetPID) to true
  end tell
  delay 0.6

  set keyTitle to ""
  try
    tell application "System Events" to tell process appName
      set keyTitle to title of (first window whose value of attribute "AXMain" is true)
    end tell
  end try
  if keyTitle is missing value then set keyTitle to ""

  set allTitles to {}
  try
    tell application "System Events" to tell process appName
      set allTitles to title of every window
    end tell
  end try

  set menuNames to {}
  try
    tell application "System Events" to tell process appName
      set menuNames to name of every menu bar item of menu bar 1
    end tell
  end try

  -- Classify the restored key window. A launcher / empty scene carries no
  -- document filename title; a value-based restored DOCUMENT scene does. Only
  -- the latter is the surface the P1-02 dispute is about.
  -- The launcher window is titled after the running app, which is the staged
  -- smoke bundle's name here and "Pensieve" in any bundle staged from a
  -- differently-named source; neither is a document scene.
  set isRestoredDoc to (keyTitle is not "") and (keyTitle is not appName) ¬
    and (keyTitle is not "Pensieve") and (keyTitle is not "Untitled")

  set missingMenus to {}
  repeat with m in {"Mode", "Format", "Agents"}
    if menuNames does not contain (contents of m) then set end of missingMenus to (contents of m)
  end repeat

  set missingItems to {}
  if not my hasMenuItem(appName, "File", "New File…") then set end of missingItems to "File>New File…"
  if not my hasMenuItem(appName, "Mode", "Source Mode") then set end of missingItems to "Mode>Source Mode"
  if not my hasMenuItem(appName, "Format", "Bold") then set end of missingItems to "Format>Bold"
  if not my hasMenuItem(appName, "Agents", "Dispatch Document to Agent…") then ¬
    set end of missingItems to "Agents>Dispatch Document to Agent…"

  log "MENU_RESTORED_WITNESS_TITLE=" & keyTitle
  log "MENU_RESTORED_WINDOWS=" & my joined(allTitles, ",")
  log "MENU_RESTORED_MENUBAR=" & my joined(menuNames, ",")

  if not isRestoredDoc then
    log "MENU_RESTORED_RESULT=SKIP (no value-based restored document scene on host; key window title=[" & keyTitle & "])"
    return "restored-menu probe skipped: launcher-only restore, no value-based scene"
  end if

  if (missingMenus is not {}) or (missingItems is not {}) then
    error "P1-02 FAIL: restored value-based window [" & keyTitle & ¬
      "] menu bar missing custom surface -> menus:{" & my joined(missingMenus, ", ") & ¬
      "} items:{" & my joined(missingItems, ", ") & "}; actual menubar={" & ¬
      my joined(menuNames, ", ") & "}; windows={" & my joined(allTitles, ", ") & "}"
  end if

  log "MENU_RESTORED_RESULT=PASS (restored value-based window carries Mode/Format/Agents + custom items)"
  return "restored value-based window menu bar carries the custom command surface"
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
  tell application "System Events"
    tell process appName
      repeat with i from 1 to (timeoutSeconds * 10)
        if (count of windows) > 0 then return true
        delay 0.1
      end repeat
    end tell
  end tell
  error "Timed out waiting for a restored window"
end waitForWindow

on hasMenuItem(appName, menuName, itemName)
  set present to false
  try
    tell application "System Events" to tell process appName
      set present to (exists menu item itemName of menu 1 of menu bar item menuName of menu bar 1)
    end tell
  end try
  return present
end hasMenuItem

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
SMOKE_SUPPORT="$SMOKE_ROOT/support"
cleanup() {
  kill "$CAFFEINATE_PID" 2>/dev/null || true
  # Every exit path -- success, assertion failure, or an error raised inside
  # osascript -- must leave zero live smoke processes, otherwise the survivor
  # becomes the orphan that corrupts the next run's census.
  terminate_app
  # Revert any smoke-domain default the restored-window probe armed. It was
  # never written to the operator's domain, but leaving it set would make the
  # next run's restoration state depend on the previous one.
  disarm_restoration_default
  # The staged bundle, its Application Support tree and the witness document
  # all live under SMOKE_ROOT; the run owns that directory outright.
  if [[ -n "${SMOKE_ROOT:-}" && "$SMOKE_ROOT" == */pensieve-toolbar-smoke.* ]]; then
    rm -rf "$SMOKE_ROOT"
  fi
}
trap cleanup EXIT

mkdir -p "$SMOKE_SUPPORT"
APP_PATH="$SMOKE_ROOT/$APP_NAME.app"
stage_smoke_app "$SOURCE_APP_PATH" "$APP_PATH" "$SMOKE_SUPPORT"
printf '# Toolbar cold-frame witness\n\nEditable staged document.\n' >"$SMOKE_DOCUMENT"

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
EXPECTED_TOOLBAR_IDENTIFIERS+=("${EXTRA_EXPECTED_IDENTIFIERS[@]}")

BUNDLE_COMMIT="$(/usr/libexec/PlistBuddy -c 'Print :PensieveBuildCommit' "$APP_PATH/Contents/Info.plist")"
BUNDLE_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")"
BUNDLE_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_PATH/Contents/Info.plist")"
EXECUTABLE_PATH="$APP_PATH/Contents/MacOS/$APP_NAME"
log "source bundle=$SOURCE_APP_PATH commit=$BUNDLE_COMMIT version=$BUNDLE_VERSION build=$BUNDLE_BUILD"
log "staged bundle=$APP_PATH executable=$EXECUTABLE_PATH id=$APP_ID signature=$SMOKE_SIGNING_MODE"
log "isolated support dir=$SMOKE_SUPPORT (PENSIEVE_SUPPORT_DIR)"

if [[ $MENU_RESTORED_ONLY -eq 1 ]]; then
  run_restored_menu_probe
  ok "restored-window menu-bar probe passed"
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
ax_runner=()
if command -v gtimeout >/dev/null 2>&1; then
  ax_runner=(gtimeout --signal=TERM 60)
fi
"${ax_runner[@]}" osascript - "$APP_NAME" "$COLD_ONLY" "$BASE_EXPECTED_IDENTIFIER_COUNT" \
  "${EXPECTED_TOOLBAR_IDENTIFIERS[@]}" <<'APPLESCRIPT'
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

on toolbarElementByDescription(appName, targetDescription)
  tell application "System Events"
    tell process appName
      set toolbarElements to entire contents of toolbar 1 of window 1
      repeat with elementRef in toolbarElements
        set elementDescription to ""
        try
          set elementDescription to get description of elementRef
        end try
        if elementDescription is targetDescription then return contents of elementRef
      end repeat
    end tell
  end tell
  error "Missing toolbar control: " & targetDescription
end toolbarElementByDescription

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

    set appearanceControl to my toolbarElementByDescription(appName, "Preview Appearance")
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
    set appearanceControl to my toolbarElementByDescription(appName, "Preview Appearance")
    click appearanceControl
    delay 0.3
    if (count of menus of appearanceControl) is 0 then
      error "Preview Appearance menu did not reopen after dismissal"
    end if
    key code 53

    set rewriteControl to my toolbarElementByDescription(appName, "Rewrite with AI")
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

ok "native UI smoke passed"

# --toolbar-cold-only returns after the cold census (the toolbar AppleScript
# exits early but bash falls through to here), so the restored-window probe runs
# only on a full pass. The toolbar phase leaves an activated instance running;
# the probe manages its own launch/quit/relaunch cycle, starting with
# terminate_app.
if [[ $COLD_ONLY -eq 0 ]]; then
  run_restored_menu_probe
  ok "restored-window menu-bar probe passed"
fi
