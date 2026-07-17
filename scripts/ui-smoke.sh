#!/usr/bin/env bash
set -euo pipefail

APP_PATH="${1:-dist/Pensieve.app}"
APP_NAME="Pensieve"
APP_ID="io.vetcoders.pensieve"

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

[[ -d "$APP_PATH" ]] || die "App bundle not found: $APP_PATH (run make release-local or make release first)"

log "launching $APP_PATH"
osascript -e "with timeout of 2 seconds" \
  -e "tell application id \"$APP_ID\" to quit" \
  -e "end timeout" >/dev/null 2>&1 || true
sleep 0.5
pkill -x "$APP_NAME" >/dev/null 2>&1 || true
for _ in {1..20}; do
  pgrep -x "$APP_NAME" >/dev/null 2>&1 || break
  sleep 0.1
done
open "$APP_PATH" || {
  # LaunchServices can briefly retain the just-terminated bundle instance
  # and return -600 even after the process is gone. One bounded retry clears it.
  sleep 0.5
  open "$APP_PATH"
}

log "probing Accessibility surface"
osascript <<'APPLESCRIPT'
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

set appName to "Pensieve"
waitForProcess(appName, 12)
waitForWindow(appName, 12)

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

    if (count of windows) is 0 then error "Pensieve has no windows after menu probing"
  end tell
end tell
APPLESCRIPT

ok "native UI smoke passed"
