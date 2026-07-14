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
assertMenuItem(appName, "File", "Open Folder…")
assertMenuItem(appName, "File", "Close")
assertMenuItem(appName, "Mode", "Source Mode")
assertMenuItem(appName, "Mode", "Split Mode")
assertMenuItem(appName, "Format", "Bold")
assertMenuItem(appName, "Format", "Link")

tell application "System Events"
  tell process appName
    if (count of windows) is 0 then error "Pensieve has no windows after menu probing"
  end tell
end tell
APPLESCRIPT

ok "native UI smoke passed"
