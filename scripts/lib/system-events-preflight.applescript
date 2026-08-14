tell application "System Events"
  if UI elements enabled is false then error "Accessibility UI scripting is disabled"
  set frontProcesses to application processes whose frontmost is true
  if (count of frontProcesses) is 0 then error "No frontmost application process is available"
  set frontProcess to item 1 of frontProcesses
  set frontPID to unix id of frontProcess
  set frontWindowCount to count of windows of frontProcess
end tell

return "SYSTEM_EVENTS_AUTOMATION=PASS"
