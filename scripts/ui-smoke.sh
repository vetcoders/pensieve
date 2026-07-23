#!/usr/bin/env bash
set -euo pipefail

APP_PATH="dist/Pensieve.app"
APP_NAME="Pensieve"
APP_ID="io.vetcoders.pensieve"
COLD_ONLY=0
EXTRA_EXPECTED_IDENTIFIERS=()

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
# ("tell process Pensieve"), and System Events resolves that name to the OLDEST
# matching process. A run that dies mid-osascript leaves an orphaned, window-
# less Pensieve alive; the next run's `open -n` then spawns a second instance,
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
  return 0
}

if [[ $# -gt 0 && "$1" != --* ]]; then
  APP_PATH="$1"
  shift
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --toolbar-cold-only)
      COLD_ONLY=1
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

[[ -d "$APP_PATH" ]] || die "App bundle not found: $APP_PATH (run make release-local or make release first)"

# Real AX clicks require the display to be awake; a sleeping display
# (displaysleep) makes popover clicks land randomly, so wake it now and
# hold it awake for the duration of the smoke to keep this deterministic
# on an unattended machine.
caffeinate -u -t 2 || true
caffeinate -dsu &
CAFFEINATE_PID=$!

APP_PATH="$(cd "$(dirname "$APP_PATH")" && pwd)/$(basename "$APP_PATH")"
SMOKE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/pensieve-toolbar-smoke.XXXXXX")"
SMOKE_DOCUMENT="$SMOKE_ROOT/toolbar-cold.md"
cleanup() {
  kill "$CAFFEINATE_PID" 2>/dev/null || true
  # Every exit path -- success, assertion failure, or an error raised inside
  # osascript -- must leave zero live Pensieve processes, otherwise the survivor
  # becomes the orphan that corrupts the next run's census.
  terminate_app
  rm -f "$SMOKE_DOCUMENT"
  rmdir "$SMOKE_ROOT" 2>/dev/null || true
}
trap cleanup EXIT
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
EXECUTABLE_PATH="$APP_PATH/Contents/MacOS/Pensieve"
log "bundle path=$APP_PATH executable=$EXECUTABLE_PATH commit=$BUNDLE_COMMIT version=$BUNDLE_VERSION build=$BUNDLE_BUILD"

log "launching editable cold witness without post-launch activation"
# Pre-launch: guarantee no prior/orphaned instance survives, so `open -n` yields
# exactly one process named Pensieve and the bare-name census cannot lock onto a
# stale windowless survivor.
terminate_app
open -n -a "$APP_PATH" "$SMOKE_DOCUMENT" || {
  # LaunchServices can briefly retain the just-terminated bundle instance
  # and return -600 even after the process is gone. One bounded retry clears it.
  sleep 0.5
  open -n -a "$APP_PATH" "$SMOKE_DOCUMENT"
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
  set bestCensus to {}
  try
    tell application "System Events"
      tell process appName
        repeat with windowRef in windows
          set candidateCensus to {}
          try
            set toolbarElements to entire contents of toolbar 1 of windowRef
            repeat with elementRef in toolbarElements
              try
                set identifierValue to value of attribute "AXIdentifier" of elementRef
                if identifierValue is not missing value and identifierValue is not "" then
                  set end of candidateCensus to identifierValue as text
                end if
              end try
            end repeat
          end try
          if (count of candidateCensus) > (count of bestCensus) then
            set bestCensus to candidateCensus
          end if
        end repeat
      end tell
    end tell
  end try
  return bestCensus
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

on assertIdentifiersAbsent(census, excludedIdentifiers, stateName)
  repeat with excludedIdentifier in excludedIdentifiers
    if census contains (excludedIdentifier as text) then
      error stateName & " unexpectedly exposes " & (excludedIdentifier as text)
    end if
  end repeat
end assertIdentifiersAbsent

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

on settledToolbarCensus(appName, expectedIdentifiers, timeoutTenths)
  set latestCensus to {}
  repeat with i from 1 to timeoutTenths
    set latestCensus to my toolbarCensus(appName)
    if (my missingIdentifiers(latestCensus, expectedIdentifiers)) is {} then return latestCensus
    delay 0.1
  end repeat
  set missingItems to my missingIdentifiers(latestCensus, expectedIdentifiers)
  error "Cold toolbar census missing identifiers: " & my joined(missingItems, ", ") & ¬
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

-- NO-STIMULUS BOUNDARY: from process discovery through this census, the
-- harness only reads AX state and waits. It does not activate/focus the app,
-- click, move the pointer, resize, raise a menu, or mutate window geometry.
set coldCensus to my settledToolbarCensus(appName, baseExpectedIdentifiers, 80)
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
tell application "Pensieve" to activate
tell application "System Events" to tell process appName to set frontmost to true
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

    set splitCensus to my settledToolbarCensus(appName, baseExpectedIdentifiers, 40)
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
    set previewCensus to my settledToolbarCensus(appName, previewExpectedIdentifiers, 40)
    my assertIdentifiersAbsent(previewCensus, editingIdentifiers, "preview-only")
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
    set splitCensus to my settledToolbarCensus(appName, baseExpectedIdentifiers, 40)
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
    set untitledCensus to my settledToolbarCensus(appName, baseExpectedIdentifiers, 40)
    my assertWindowGeometry(appName, coldPosition, coldSize, "file-backed to untitled transition")
    log "AX_CENSUS_UNTITLED=" & my joined(untitledCensus, ",")

    if (count of windows) is 0 then error "Pensieve has no windows after menu probing"
  end tell
end tell


tell application "Finder" to activate
delay 0.3
tell application "Pensieve" to activate
tell application "System Events" to tell process appName
  set frontmost to true
  perform action "AXRaise" of window 1
end tell
delay 0.5
set regainCensus to my settledToolbarCensus(appName, baseExpectedIdentifiers, 40)
my assertWindowGeometry(appName, coldPosition, coldSize, "key-window regain/redraw")
log "AX_CENSUS_REGAIN_REDRAW=" & my joined(regainCensus, ",")
end run
APPLESCRIPT

ok "native UI smoke passed"
