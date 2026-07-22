#!/usr/bin/env bash
# BUGMAP P0 runtime smoke matrix (W4-A).
#
# Splits the matrix into two lanes:
#   STATIC  — deterministic bundle-truth rows that never touch the GUI session
#             (identity, strict codesign, entitlements, purpose strings, hash,
#             provenance stamp). Always run.
#   GUI     — rows that need a live, unlocked login session AND a free stage
#             (no foreign Pensieve instance we must not kill). Guarded by a
#             preflight; a blocked lane is reported SKIP with the reason and
#             the script exits nonzero — a missing row is never a silent pass.
#
# Usage:
#   scripts/bugmap-p0-smoke.sh --app <path/to/Pensieve.app> --evidence <dir>
#     [--critical-only]   run only the critical rows (post-install re-check)
#     [--allow-kill]      permit terminating a running Pensieve instance so the
#                         GUI lane can own the stage (NEVER the default: the
#                         operator's live process is not ours to kill)
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

APP_ID="io.vetcoders.pensieve"
APP_BINARY="$APP_PATH/Contents/MacOS/Pensieve"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STAMP="$(date "+%Y-%m-%dT%H:%M:%S%z")"

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
# Preflight: the GUI rows are only truthful on an unlocked console with a free
# stage. A locked screen poisons every window/AX/screenshot artifact (apps
# launch "windowless", traces lie), and a running Pensieve we did not start is
# the operator's process — never killed, never bundle-swapped-under.

GUI_BLOCKERS=()
if ioreg -k IOConsoleUsers 2>/dev/null | grep -q "ScreenIsLocked.*Yes"; then
  GUI_BLOCKERS+=("screen locked (window/AX/sample artifacts are poisoned under lock)")
fi
LIVE_PID="$(pgrep -x Pensieve | head -1 || true)"
if [[ -n "$LIVE_PID" && "$ALLOW_KILL" -ne 1 ]]; then
  GUI_BLOCKERS+=("live Pensieve pid $LIVE_PID not owned by this rig (pass --allow-kill only when the operator cleared it)")
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
  for attempt in 1 2; do
    if "$REPO_ROOT/scripts/ui-smoke.sh" "$APP_PATH" \
      >"$EVIDENCE_DIR/ui-smoke.txt" 2>&1; then
      UI_SMOKE_OK=1
      break
    fi
    [[ "$attempt" -eq 1 ]] && sleep 2
  done
  if [[ "$UI_SMOKE_OK" -eq 1 ]]; then
    row PASS G1-launch-ax "ui-smoke launch + window + AX probe green"
    if [[ "$CRITICAL_ONLY" -ne 1 ]]; then
      row PASS G2-menu-census "menu census green (ui-smoke.txt)"
      row PASS G3-toolbar-families "toolbar AX census green (ui-smoke.txt)"
    fi
  else
    row FAIL G1-launch-ax "ui-smoke failed (see ui-smoke.txt)"
    if [[ "$CRITICAL_ONLY" -ne 1 ]]; then
      row FAIL G2-menu-census "not reached (ui-smoke failed)"
      row FAIL G3-toolbar-families "not reached (ui-smoke failed)"
    fi
  fi

  SMOKE_PID="$(pgrep -x Pensieve | head -1 || true)"
  if [[ -n "$SMOKE_PID" ]]; then
    SAMPLE_FILE="$EVIDENCE_DIR/open-sample.txt"
    OPEN_FIXTURE="$(mktemp -d)/w4a-open-fixture.md"
    printf '# W4-A open fixture\n' >"$OPEN_FIXTURE"
    open -a "$APP_PATH" "$OPEN_FIXTURE" || true
    sample "$SMOKE_PID" 3 -f "$SAMPLE_FILE" >/dev/null 2>&1 || true
    if [[ -s "$SAMPLE_FILE" ]]; then
      # `sample` frames carry a leading sample count (1 sample ≈ 1 ms on the
      # stack). The P0-14 storm was a per-document standardizedFileURL sweep
      # pinning the main thread for hundreds of ms, so the honest metric is
      # total samples inside registerOpenFile, not textual occurrences.
      STORM_SAMPLES="$(sed -nE 's/.*[^0-9]([0-9]+) FolderManager\.registerOpenFile.*/\1/p' \
        "$SAMPLE_FILE" | awk '{sum += $1} END {print sum + 0}')"
      if [[ "${STORM_SAMPLES:-0}" -lt 50 ]]; then
        row PASS G4-open-sample "registerOpenFile on-stack ≈${STORM_SAMPLES:-0}ms of 3000ms sampled (open-sample.txt)"
      else
        row FAIL G4-open-sample "registerOpenFile on-stack ≈${STORM_SAMPLES}ms in a 3s sample — storm signature (open-sample.txt)"
      fi
    else
      row FAIL G4-open-sample "sample produced no output"
    fi
    osascript -e "tell application id \"$APP_ID\" to quit" >/dev/null 2>&1 || true
  else
    row FAIL G4-open-sample "no Pensieve process to sample after ui-smoke"
  fi
fi

# ------------------------------------------------------------------- summary

{
  echo "# BUGMAP P0 smoke matrix — $STAMP"
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
