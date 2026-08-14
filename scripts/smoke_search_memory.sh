#!/usr/bin/env bash
# Pensieve multi-root search/index memory smoke (B-04 / audit F-8-R03).
#
# Stages an exact copy of dist/Pensieve.app under a unique process name, bundle
# id, defaults domain, Application Support root and Keychain service, proves an
# empty-launcher baseline, then generates a synthetic markdown vault (~1000 files
# across 3 roots) and drives File → Open Folder for each root via AppleScript.
# It polls index.db for reindex completion, captures
# peak RSS + /usr/bin/sample stack profile, and probes search latency via
# a direct sqlite3 FTS5 query against the populated index.db. Cleanup is scoped
# to the unique run identity. The production bundle, process, preferences and
# ~/Library/Application Support/Pensieve are never moved, reset or terminated.
#
# Output: dist/smoke/search-memory-<ISO-timestamp>-<run-uuid>.md
# Operator runs ad-hoc, NOT part of `swift test` / `make ci`.
#
# Usage:
#   make smoke-search-memory                           # default
#   FILES=2000 ROOTS=4 make smoke-search-memory       # override scale
#   SAMPLE_DURATION_SEC=40 make smoke-search-memory   # longer profile window
#
# Requirements:
#   - macOS (uses /usr/bin/sample, /usr/bin/sqlite3, osascript, codesign)
#   - a current, strictly signed dist/Pensieve.app (`make release-local`)
#   - Accessibility permission for the parent terminal (System Settings →
#     Privacy & Security → Accessibility) so AppleScript can drive Open
#     Folder via System Events keystrokes.
#   - The production Pensieve process may remain open. This harness never
#     addresses it by process name or production bundle identifier.

set -euo pipefail

# ─── Resolve paths ────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -P "$SCRIPT_DIR/.." && pwd -P)"
DIST_DIR="$REPO_ROOT/dist"
SMOKE_DIR="$DIST_DIR/smoke"
# shellcheck source=scripts/lib/isolated-app.sh
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/isolated-app.sh"

# ─── Config (env-overridable) ─────────────────────────────────────────────
FILES="${FILES:-1000}"
ROOTS="${ROOTS:-3}"
SAMPLE_DURATION_SEC="${SAMPLE_DURATION_SEC:-30}"
APP_LAUNCH_SETTLE_SEC="${APP_LAUNCH_SETTLE_SEC:-3}"
REINDEX_MAX_WAIT_SEC="${REINDEX_MAX_WAIT_SEC:-90}"
REINDEX_STABLE_TICKS="${REINDEX_STABLE_TICKS:-4}"
SEARCH_QUERY="${SEARCH_QUERY:-note}"

# ─── Helpers ──────────────────────────────────────────────────────────────
log()  { printf "\033[36m[smoke]\033[0m %s\n" "$*"; }
ok()   { printf "\033[32m[ ok ]\033[0m %s\n" "$*"; }
warn() { printf "\033[33m[warn]\033[0m %s\n" "$*" >&2; }
die()  { printf "\033[31m[fail]\033[0m %s\n" "$*" >&2; exit 1; }

require_positive_integer() {
    local label="${1:-value}"
    local value="${2:-}"
    case "$value" in
        '' | *[!0-9]*) die "$label must be a positive integer (got: ${value:-empty})" ;;
    esac
    [[ "$value" -gt 0 ]] || die "$label must be greater than zero (got: $value)"
}

# ─── Pre-flight ───────────────────────────────────────────────────────────
[[ "$(uname -s)" = "Darwin" ]] || die "macOS-only (uses /usr/bin/sample + codesign)"
[[ -x /usr/bin/sample ]] || die "/usr/bin/sample missing (Apple tool, ships with macOS)"
[[ -x /usr/bin/sqlite3 ]] || die "/usr/bin/sqlite3 missing"
command -v codesign >/dev/null 2>&1 || die "codesign missing"
command -v osascript >/dev/null 2>&1 || die "osascript missing"
command -v python3 >/dev/null 2>&1 || die "python3 missing (used to generate fixture)"
command -v swift >/dev/null 2>&1 || die "swift missing"

require_positive_integer FILES "$FILES"
require_positive_integer ROOTS "$ROOTS"
require_positive_integer SAMPLE_DURATION_SEC "$SAMPLE_DURATION_SEC"
require_positive_integer REINDEX_MAX_WAIT_SEC "$REINDEX_MAX_WAIT_SEC"
require_positive_integer REINDEX_STABLE_TICKS "$REINDEX_STABLE_TICKS"
[[ "$FILES" -ge "$ROOTS" ]] \
    || die "FILES must be at least ROOTS so every fixture root is non-empty"

TS="$(date -u +"%Y%m%dT%H%M%SZ")"
RUN_TOKEN="r$(/usr/bin/uuidgen | /usr/bin/tr '[:upper:]' '[:lower:]' | /usr/bin/tr -d '-')"
[[ "$RUN_TOKEN" == r???????????????????????????????? ]] \
    || die "could not mint a valid run UUID"
SESSION_DIR="$SMOKE_DIR/session-$TS-$RUN_TOKEN"
VAULT_DIR="$SESSION_DIR/vault"
CAPSULE_ROOT="$SESSION_DIR/runtime-owner"
SOURCE_APP="${APP_BUNDLE:-$DIST_DIR/Pensieve.app}"
SOURCE_APP="$(cd -P "$(dirname "$SOURCE_APP")" 2>/dev/null && pwd -P)/$(basename "$SOURCE_APP")"
APP_BUNDLE_ID="$(isolated_app_generate_bundle_id memory)"
EXECUTABLE_NAME="Pmem${RUN_TOKEN:1}"
SMOKE_APP="$CAPSULE_ROOT/$EXECUTABLE_NAME.app"
SMOKE_APPSUP="$CAPSULE_ROOT/smoke-appsupport"
SMOKE_KEYCHAIN_SERVICE="$APP_BUNDLE_ID.completion-provider"
IDENTITY_MANIFEST="$CAPSULE_ROOT/identity.plist"
SAMPLE_OUTPUT="$SESSION_DIR/sample-profile.txt"
RSS_TRACE="$SESSION_DIR/rss-trace.txt"
APP_LOG="$SESSION_DIR/app.log"
REPORT="$SMOKE_DIR/search-memory-$TS-$RUN_TOKEN.md"
INDEX_ARTIFACT="$SESSION_DIR/index.db"
CLEANUP_STATUS_FILE="$SESSION_DIR/cleanup-status.txt"

[[ -d "$SOURCE_APP" ]] || die "source app missing: $SOURCE_APP (run make release-local)"
SOURCE_COMMIT="$(isolated_app_assert_source_provenance \
    "$REPO_ROOT" "$SOURCE_APP" \
    "${PENSIEVE_SMOKE_ALLOW_STALE_SOURCE:-0}" \
    "${PENSIEVE_SMOKE_ALLOW_DIRTY_SOURCE:-0}")" \
    || die "source provenance check failed (rebuild from the current clean product sources)"

mkdir -p "$SMOKE_DIR" "$SESSION_DIR" "$CAPSULE_ROOT"
SMOKE_DIR="$(cd -P "$SMOKE_DIR" && pwd -P)"
SESSION_DIR="$(cd -P "$SESSION_DIR" && pwd -P)"
VAULT_DIR="$SESSION_DIR/vault"
CAPSULE_ROOT="$(cd -P "$CAPSULE_ROOT" && pwd -P)"
SMOKE_APP="$CAPSULE_ROOT/$EXECUTABLE_NAME.app"
SMOKE_APPSUP="$CAPSULE_ROOT/smoke-appsupport"
IDENTITY_MANIFEST="$CAPSULE_ROOT/identity.plist"
SAMPLE_OUTPUT="$SESSION_DIR/sample-profile.txt"
RSS_TRACE="$SESSION_DIR/rss-trace.txt"
APP_LOG="$SESSION_DIR/app.log"
REPORT="$SMOKE_DIR/search-memory-$TS-$RUN_TOKEN.md"
INDEX_ARTIFACT="$SESSION_DIR/index.db"
CLEANUP_STATUS_FILE="$SESSION_DIR/cleanup-status.txt"

# Refresh the generated README so an older harness description cannot survive
# beside evidence produced by the current isolation contract.
cat >"$SMOKE_DIR/README.md" <<'EOF'
# Pensieve — Search/Index Memory Smoke

Ad-hoc memory smoke for the multi-root reindex path. Auto-generated by
`make smoke-search-memory` (see `scripts/smoke_search_memory.sh`). NOT part
of `swift test` / `make ci`. Operator runs this when:

- Auditing the F-8 streaming reindex bound on a real-shaped vault.
- Verifying a change in `IndexDatabase.replaceSearchIndex` does not regress
  the single-body-in-memory invariant.
- Pre-release sanity on the workspace search hot path.

## What it does

The script stages the current signed `dist/Pensieve.app` under a new per-run
process name and bundle identifier, injects unique `PENSIEVE_SUPPORT_DIR` and
`PENSIEVE_KEYCHAIN_SERVICE` values, and first proves an empty-launcher baseline.
Only then does it generate a synthetic markdown vault (~1000 files × ~3 roots).
AppleScript drives File → Open Folder for each fixture root; the normal workspace
path then triggers a real `IndexDatabase.replaceSearchIndex` against the whole
fixture inside the session directory. The smoke captures peak RSS, sample stack
profile, and search latency.

## Safety

- The production bundle, process, defaults domain and Application Support
  directory are never addressed by this harness.
- Every run receives a unique bundle identifier, executable/process name,
  defaults domain, Application Support root and Keychain service.
- Runtime verification resolves the live PID back to the exact staged bundle
  and executable before the test drives or samples it.
- An EXIT/INT/TERM trap unregisters and removes only that run's manifest-owned
  identity. No broad process kill or global LaunchServices reset is used.

## Requirements

The AppleScript Open Folder drive needs **Accessibility** access for the
terminal that invoked `make` (System Settings → Privacy & Security →
Accessibility → enable iTerm / Terminal / Claude). The script fails fast
with a clear message if that permission is missing.

## Each run produces

- `search-memory-<ISO>-<run-uuid>.md` — human-readable report (this directory).
- `session-<ISO>-<run-uuid>/` — vault fixture, copied `index.db`, sample profile, RSS
  trace and app stdout/stderr. The staged `.app` and mutable support profile
  are retired at cleanup; the forensic outputs remain.

## How to read the report

- **Peak RSS** — physical footprint of the Pensieve process during reindex
  (max over a 0.5s-cadence `ps -o rss=` poller). F-8 target: under 200 MB
  for a ~1000-file vault.
- **Reindex duration** — wall-clock from the first Open Folder drive to a
  stable `workspace_search_documents` row count.
- **Search latency** — direct FTS5 query latency via `sqlite3` against the
  populated `index.db` (proxies the in-process `performSearch` cost).
- **Top stack frames** — `/usr/bin/sample`'s Call graph excerpt: where the
  process spent CPU during the sample window.

If peak RSS exceeds 200 MB, surface it with the operator before shipping.
EOF

# ─── Source artifact ──────────────────────────────────────────────────────
log "source app: $SOURCE_APP (commit ${SOURCE_COMMIT:-unknown})"

# ─── Pre-flight: confirm AppleScript can drive System Events ──────────────
log "checking AppleScript / Accessibility access"
if ! osascript -e 'tell application "System Events" to get name of every process' \
    >/dev/null 2>>"$APP_LOG"
then
    warn "AppleScript could not query System Events."
    warn "System Settings → Privacy & Security → Accessibility → enable your terminal."
    die "Accessibility permission missing — see $APP_LOG"
fi
ok "AppleScript / Accessibility OK"

# ─── Production boundary ──────────────────────────────────────────────────
# Production state is never moved, linked, reset or queried by this harness.
log "production Application Support remains untouched"

# ─── Cleanup hook (exact run identity + child samplers) ───────────────────
PENSIEVE_PID=""
SAMPLE_PID=""
RSS_POLLER_PID=""
IDENTITY_CLEANUP_ARMED=0
SMOKE_FAILURE_COUNT=0
SMOKE_FAILURE_SUMMARY=""

record_smoke_failure() {
    local message="${1:-unspecified smoke failure}"
    SMOKE_FAILURE_COUNT=$((SMOKE_FAILURE_COUNT + 1))
    if [[ -z "$SMOKE_FAILURE_SUMMARY" ]]; then
        SMOKE_FAILURE_SUMMARY="$message"
    else
        SMOKE_FAILURE_SUMMARY="$SMOKE_FAILURE_SUMMARY; $message"
    fi
    warn "$message"
}

record_cleanup_status() {
    local status="${1:-unknown}"
    local detail="${2:-no detail}"
    local bundle_present=0 support_present=0 manifest_present=0
    [[ -e "$SMOKE_APP" || -L "$SMOKE_APP" ]] && bundle_present=1
    [[ -e "$SMOKE_APPSUP" || -L "$SMOKE_APPSUP" ]] && support_present=1
    [[ -e "$IDENTITY_MANIFEST" || -L "$IDENTITY_MANIFEST" ]] && manifest_present=1
    {
        printf 'status=%s\n' "$status"
        printf 'recorded_at=%s\n' "$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')"
        printf 'run_token=%s\n' "$RUN_TOKEN"
        printf 'bundle_id=%s\n' "$APP_BUNDLE_ID"
        printf 'bundle_path=%s\n' "$SMOKE_APP"
        printf 'support_path=%s\n' "$SMOKE_APPSUP"
        printf 'identity_manifest=%s\n' "$IDENTITY_MANIFEST"
        printf 'bundle_present=%s\n' "$bundle_present"
        printf 'support_present=%s\n' "$support_present"
        printf 'manifest_present=%s\n' "$manifest_present"
        printf 'detail=%s\n' "$detail"
    } >"$CLEANUP_STATUS_FILE"
}

owned_identity_is_absent() {
    local status
    if isolated_app_identity_is_running "$APP_BUNDLE_ID" >/dev/null 2>&1; then
        return 1
    else
        status=$?
    fi
    [[ "$status" -eq 1 ]]
}

verify_owned_pid() {
    local observed_pid
    [[ -n "$PENSIEVE_PID" ]] || {
        warn "no stored isolated PID is available for exact re-authorization"
        return 1
    }
    if ! observed_pid="$(isolated_app_verify_running_identity \
        "$APP_BUNDLE_ID" "$SMOKE_APP" \
        "$SMOKE_APP/Contents/MacOS/$EXECUTABLE_NAME" 2>>"$APP_LOG")"; then
        warn "could not re-authorize the isolated runtime identity"
        return 1
    fi
    if [[ "$observed_pid" != "$PENSIEVE_PID" ]]; then
        warn "isolated runtime PID changed: expected=$PENSIEVE_PID observed=$observed_pid"
        return 1
    fi
    return 0
}

terminate_owned_app() {
    local context="${1:-termination}"
    local status
    if [[ -z "$PENSIEVE_PID" ]]; then
        if owned_identity_is_absent; then return 0; fi
        warn "$context: isolated bundle id is live but no exact PID is owned"
        return 1
    fi

    if ! verify_owned_pid; then
        if owned_identity_is_absent; then
            PENSIEVE_PID=""
            return 0
        fi
        warn "$context: refusing lifecycle action without exact runtime ownership"
        return 1
    fi

    if isolated_app_control_identity \
        terminate "$APP_BUNDLE_ID" "$SMOKE_APP" \
        "$SMOKE_APP/Contents/MacOS/$EXECUTABLE_NAME" "$PENSIEVE_PID" 5
    then
        PENSIEVE_PID=""
        return 0
    else
        status=$?
    fi
    case "$status" in
        3) PENSIEVE_PID=""; return 0 ;;
        4)
            warn "$context: exact runtime identity changed during termination"
            return 1
            ;;
        5) warn "$context: isolated process survived exact NSRunningApplication termination" ;;
        *) return 1 ;;
    esac
    return 1
}

cleanup() {
    local exit_code=$? cleanup_code=0 termination_ok=1
    set +e
    if [[ -n "$RSS_POLLER_PID" ]]; then
        /bin/kill "$RSS_POLLER_PID" 2>/dev/null
        wait "$RSS_POLLER_PID" 2>/dev/null
        RSS_POLLER_PID=""
    fi
    if [[ -n "$SAMPLE_PID" ]]; then
        /bin/kill -INT "$SAMPLE_PID" 2>/dev/null
        wait "$SAMPLE_PID" 2>/dev/null
        SAMPLE_PID=""
    fi
    if ! terminate_owned_app "EXIT cleanup"; then
        cleanup_code=1
        termination_ok=0
    fi
    if [[ "$termination_ok" -eq 1 && "$IDENTITY_CLEANUP_ARMED" = "1" ]]; then
        isolated_app_cleanup_manifest "$IDENTITY_MANIFEST" "$CAPSULE_ROOT" \
            || cleanup_code=1
    elif [[ "$termination_ok" -eq 1 && ( -e "$SMOKE_APP" || -L "$SMOKE_APP" ) ]]; then
        isolated_app_remove_exact_path "$SMOKE_APP" "partial memory-smoke bundle" \
            || cleanup_code=1
    fi
    if [[ "$cleanup_code" -eq 0 ]]; then
        record_cleanup_status clean \
            "isolated process absent and all manifest-owned mutable identity surfaces retired" \
            || cleanup_code=1
    else
        record_cleanup_status failed \
            "cleanup was incomplete; some identity surfaces may already be retired; inspect the recorded per-path presence flags before retry" \
            || true
    fi
    if [[ "$exit_code" -eq 0 && "$cleanup_code" -ne 0 ]]; then exit_code=$cleanup_code; fi
    exit "$exit_code"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
record_cleanup_status pending \
    "run is active; this file is replaced with the authoritative cleanup result on exit"

# Stage a fresh, uniquely-owned identity. Nothing in this block targets the
# production bundle id, process name, defaults domain or support directory.
log "staging isolated identity $APP_BUNDLE_ID from $SOURCE_APP"
# Arm cleanup before entering the atomic reservation call. A signal delivered
# while plutil is writing its temporary authority still reaches the bounded
# manifest cleanup; the runtime capsule is separate from retained evidence.
IDENTITY_CLEANUP_ARMED=1
isolated_app_reserve_manifest \
    "$IDENTITY_MANIFEST" "$CAPSULE_ROOT" "$SOURCE_APP" "$SMOKE_APP" \
    "$EXECUTABLE_NAME" "$APP_BUNDLE_ID" "Pensieve Memory Smoke" \
    "$SMOKE_APPSUP" "$SMOKE_KEYCHAIN_SERVICE" "$SOURCE_COMMIT" \
    || die "could not reserve isolated cleanup authority"
/bin/mkdir "$SMOKE_APPSUP" \
    || die "could not create the canonical memory-smoke support directory"
isolated_app_stage_bundle \
    "$SOURCE_APP" "$SMOKE_APP" "$EXECUTABLE_NAME" "$APP_BUNDLE_ID" \
    "$EXECUTABLE_NAME" "Pensieve Memory Smoke" "$SMOKE_APPSUP" \
    "$SMOKE_KEYCHAIN_SERVICE" "$REPO_ROOT" \
    "${PENSIEVE_SMOKE_ALLOW_STALE_SOURCE:-0}" \
    "${PENSIEVE_SMOKE_ALLOW_DIRTY_SOURCE:-0}" \
    || die "could not stage isolated app"
isolated_app_finalize_manifest "$IDENTITY_MANIFEST" "$CAPSULE_ROOT" \
    || die "could not finalize isolated identity manifest"
isolated_app_verify_bundle_from_manifest "$IDENTITY_MANIFEST" "$CAPSULE_ROOT" \
    || die "staged bundle does not match its identity manifest"
isolated_app_reset_defaults_domain "$APP_BUNDLE_ID" \
    || die "could not reset new defaults domain"
isolated_app_reset_keychain_item \
    "$APP_BUNDLE_ID" "$SMOKE_KEYCHAIN_SERVICE" "$ISOLATED_APP_KEYCHAIN_ACCOUNT" \
    || die "could not reset new Keychain service"
isolated_app_assert_profile_fresh \
    "$APP_BUNDLE_ID" "$SMOKE_APPSUP" "$SMOKE_KEYCHAIN_SERVICE" \
    || die "new memory-smoke profile is not fresh"
ok "fresh isolated app staged: $SMOKE_APP"

assert_fresh_launcher_baseline() {
    verify_owned_pid || return 1
    if /usr/bin/osascript - "$PENSIEVE_PID" "$APP_BUNDLE_ID" <<'APPLESCRIPT' >>"$APP_LOG" 2>&1
property expectedBundleID : ""
on run argv
  set targetPID to (item 1 of argv) as integer
  set my expectedBundleID to item 2 of argv as text
  my waitForProcess(targetPID, 15)
  my waitForWindow(targetPID, 15)

  -- A single clean frame can race startup hydration. Sample the exact process
  -- for about three seconds, and reject any transient stale surface.
  set forbiddenIdentifiers to {"pensieve.sidebar.list.openFiles", "pensieve.sidebar.list.workspace", "pensieve.recoveredDrafts", "pensieve.recoveredDrafts.row", "pensieve.emptyState.recents"}
  repeat with sampleIndex from 1 to 20
    set appProcess to my processForPID(targetPID, expectedBundleID)
    if appProcess is missing value then error "exact memory-smoke process disappeared during baseline sample " & sampleIndex

    tell application "System Events"
      tell appProcess
        set frontmost to true
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

    if windowCount is not 1 then
      error "fresh profile sample " & sampleIndex & " must expose exactly one launcher, got " & windowCount
    end if
    if identifiers does not contain "pensieve.sidebar.emptyState" then
      error "fresh profile sample " & sampleIndex & " did not expose the empty sidebar; identifiers={" & my joined(identifiers, ",") & "}"
    end if
    repeat with forbiddenIdentifier in forbiddenIdentifiers
      if identifiers contains (forbiddenIdentifier as text) then
        error "fresh profile sample " & sampleIndex & " exposed stale UI [" & (forbiddenIdentifier as text) & "]"
      end if
    end repeat
    delay 0.15
  end repeat
  return "FRESH_PROFILE_RESULT=PASS (stable 3s; one empty launcher; zero workspace/open files/recovery/recents)"
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
    then
        ok "fresh profile: stable 3s; one empty launcher; zero workspace/open files/recovery/recents"
    else
        return 1
    fi
}

# ─── Launch Pensieve via LaunchServices ───────────────────────────────────
# AppleScript needs a LaunchServices-registered app to drive menus by bundle
# id. The helper injects the isolated support and Keychain overrides.
log "launching exact staged path via LaunchServices"
isolated_app_open_new \
    "$APP_BUNDLE_ID" "$SMOKE_APP" "$SMOKE_APPSUP" "$SMOKE_KEYCHAIN_SERVICE" \
    >>"$APP_LOG" 2>&1 \
    || die "open command failed; see $APP_LOG"

# Resolve the exact running bundle and executable, not a process-name match.
PENSIEVE_PID="$(isolated_app_wait_for_running_identity \
    "$APP_BUNDLE_ID" "$SMOKE_APP" "$SMOKE_APP/Contents/MacOS/$EXECUTABLE_NAME")" \
    || die "could not prove exact staged process identity after open"

sleep "$APP_LAUNCH_SETTLE_SEC"

if ! isolated_app_control_identity \
    status "$APP_BUNDLE_ID" "$SMOKE_APP" \
    "$SMOKE_APP/Contents/MacOS/$EXECUTABLE_NAME" "$PENSIEVE_PID" 0 \
    >/dev/null 2>>"$APP_LOG"
then
    warn "Pensieve died during startup — last log lines:"
    tail -20 "$APP_LOG" >&2 || true
    die "Pensieve subprocess crashed (pid $PENSIEVE_PID); see $APP_LOG"
fi
ok "Pensieve up (pid $PENSIEVE_PID)"

# The first runtime witness must be an exact-PID proof of a genuinely empty
# launcher. Only after that proof may this run create fixture documents.
assert_fresh_launcher_baseline \
    || die "fresh-profile launcher baseline failed; see $APP_LOG"

# ─── Fixture generation ────────────────────────────────────────────────────
log "generating fixture: $FILES files × $ROOTS roots → $VAULT_DIR"
START_FIXTURE=$(date +%s)
python3 - "$VAULT_DIR" "$FILES" "$ROOTS" <<'PYEOF'
import os, sys, random, string
base, files, roots = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
random.seed(20260529)
root_dirs = [os.path.join(base, f"root-{i+1}") for i in range(roots)]
for r in root_dirs:
    os.makedirs(r, exist_ok=True)
words = [
    "note", "memo", "todo", "idea", "draft", "plan", "review", "check",
    "audit", "ship", "fix", "test", "build", "deploy", "release",
    "spec", "rfc", "design", "arch", "pattern", "swift", "macos",
    "markdown", "fts", "index", "search", "workspace", "pensieve",
]
alpha = string.ascii_lowercase + " " * 6
for i in range(files):
    root = root_dirs[i % roots]
    size = random.randint(1024, 50 * 1024)
    chunks = []
    used = 0
    while used < size:
        if random.random() < 0.18:
            w = random.choice(words)
        else:
            w_len = random.randint(2, 9)
            w = "".join(random.choices(alpha, k=w_len)).strip() or "x"
        chunks.append(w)
        used += len(w) + 1
    body = " ".join(chunks)[:size]
    title = f"Note {i:04d} {random.choice(words)}"
    path = os.path.join(root, f"note-{i:04d}.md")
    with open(path, "w") as f:
        f.write(f"# {title}\n\n{body}\n")
PYEOF
FIXTURE_SEC=$(( $(date +%s) - START_FIXTURE ))
FIXTURE_SIZE="$(du -sh "$VAULT_DIR" | cut -f1 | tr -d ' ')"
ok "fixture ready: $FIXTURE_SIZE in ${FIXTURE_SEC}s"

verify_owned_pid || die "isolated runtime identity changed before sampling"

# ─── RSS poller (background) ──────────────────────────────────────────────
log "starting RSS poller → $RSS_TRACE"
(
    while isolated_app_control_identity \
        status "$APP_BUNDLE_ID" "$SMOKE_APP" \
        "$SMOKE_APP/Contents/MacOS/$EXECUTABLE_NAME" "$PENSIEVE_PID" 0 \
        >/dev/null 2>>"$APP_LOG"
    do
        rss_kb="$(ps -o rss= -p "$PENSIEVE_PID" 2>/dev/null | tr -d ' ' || echo 0)"
        printf "%s %s\n" "$(date +%s)" "${rss_kb:-0}" >>"$RSS_TRACE"
        sleep 0.5
    done
) &
RSS_POLLER_PID=$!

# ─── Sample profile (background) ──────────────────────────────────────────
verify_owned_pid || die "isolated runtime identity changed before /usr/bin/sample"
log "starting /usr/bin/sample for ${SAMPLE_DURATION_SEC}s → $SAMPLE_OUTPUT"
/usr/bin/sample "$PENSIEVE_PID" "$SAMPLE_DURATION_SEC" -file "$SAMPLE_OUTPUT" -mayDie \
    >/dev/null 2>&1 &
SAMPLE_PID=$!

# ─── Drive Open Folder dialog for each root via AppleScript ──────────────
log "driving Open Folder dialog for $ROOTS root(s) via AppleScript"
REINDEX_START=$(date +%s)
ROOT_DRIVE_SUCCESSES=0
ROOT_DRIVE_FAILURES=0
for i in $(seq 1 "$ROOTS"); do
    ROOT_PATH="$VAULT_DIR/root-$i"
    log "  opening root-$i: $ROOT_PATH"
    if ! verify_owned_pid; then
        ROOT_DRIVE_FAILURES=$((ROOT_DRIVE_FAILURES + 1))
        warn "exact runtime ownership failed before root-$i; refusing UI drive"
    elif /usr/bin/osascript - "$PENSIEVE_PID" "$APP_BUNDLE_ID" "$ROOT_PATH" <<'APPLESCRIPT' 2>>"$APP_LOG"
property expectedBundleID : ""
on run argv
  set targetPID to (item 1 of argv) as integer
  set my expectedBundleID to item 2 of argv as text
  set rootPath to item 3 of argv
  try
    set clipboardSnapshot to the clipboard as record
  on error recordCaptureMessage
    try
      set clipboardSnapshot to the clipboard as text
    on error textCaptureMessage
      error "could not snapshot the clipboard; refusing to overwrite it (record=" & recordCaptureMessage & "; text=" & textCaptureMessage & ")"
    end try
  end try

  try
    set the clipboard to rootPath
    set appProcess to my processForPID(targetPID, expectedBundleID)
    if appProcess is missing value then
      error "exact target process is missing for pid=" & targetPID
    end if
    tell application "System Events"
      set frontmost of appProcess to true
      delay 0.6
      if frontmost of appProcess is not true then
        error "exact target process did not become frontmost for pid=" & targetPID
      end if
      -- File → Open Folder…  (⌘⇧O in Commands.swift)
      keystroke "o" using {command down, shift down}
      delay 0.8
      -- Go to Folder…  (⌘⇧G inside NSOpenPanel)
      keystroke "g" using {command down, shift down}
      delay 0.5
      -- Clipboard paste avoids keyboard-layout corruption for absolute paths.
      keystroke "v" using {command down}
      delay 0.3
      keystroke return
      delay 0.6
      -- "Open" button in the panel (default action)
      keystroke return
      delay 0.5
    end tell
  on error errorMessage number errorNumber
    try
      set the clipboard to clipboardSnapshot
    on error restoreMessage number restoreNumber
      error "Open Folder drive failed (" & errorMessage & "); clipboard restore also failed (" & restoreMessage & ")" number restoreNumber
    end try
    error errorMessage number errorNumber
  end try

  set the clipboard to clipboardSnapshot
  return "OPEN_ROOT_RESULT=PASS pid=" & targetPID & " path=" & rootPath
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
APPLESCRIPT
    then
        ROOT_DRIVE_SUCCESSES=$((ROOT_DRIVE_SUCCESSES + 1))
    else
        ROOT_DRIVE_FAILURES=$((ROOT_DRIVE_FAILURES + 1))
        warn "AppleScript drive failed for root-$i; the smoke may produce 0 rows"
    fi
    sleep 2
done
if [[ "$ROOT_DRIVE_SUCCESSES" -eq "$ROOTS" && "$ROOT_DRIVE_FAILURES" -eq 0 ]]; then
    ok "Open Folder drive complete for all $ROOTS root(s)"
else
    record_smoke_failure \
        "Open Folder drive succeeded for $ROOT_DRIVE_SUCCESSES/$ROOTS roots ($ROOT_DRIVE_FAILURES failures)"
fi
if ! verify_owned_pid; then
    record_smoke_failure \
        "isolated app was not alive under exact ownership after the final root drive"
fi

# ─── Wait for reindex to settle ───────────────────────────────────────────
INDEX_DB="$SMOKE_APPSUP/index.db"
log "waiting up to ${REINDEX_MAX_WAIT_SEC}s for reindex to settle (polling index.db)"
LAST_ROW_COUNT=-1
STABLE_TICKS=0
REINDEX_STABLE=0
ELAPSED=0
while (( ELAPSED < REINDEX_MAX_WAIT_SEC )); do
    if [[ -f "$INDEX_DB" ]]; then
        CURRENT_COUNT="$(/usr/bin/sqlite3 -readonly "$INDEX_DB" \
            "SELECT count(*) FROM workspace_search_documents" 2>/dev/null || echo 0)"
    else
        CURRENT_COUNT=0
    fi
    case "$CURRENT_COUNT" in
        '' | *[!0-9]*) CURRENT_COUNT=0 ;;
    esac
    if [[ "$CURRENT_COUNT" = "$LAST_ROW_COUNT" ]] \
        && [[ "$CURRENT_COUNT" -eq "$FILES" ]]
    then
        STABLE_TICKS=$(( STABLE_TICKS + 1 ))
        if (( STABLE_TICKS >= REINDEX_STABLE_TICKS )); then
            REINDEX_STABLE=1
            break
        fi
    else
        STABLE_TICKS=0
    fi
    LAST_ROW_COUNT="$CURRENT_COUNT"
    sleep 1
    ELAPSED=$(( ELAPSED + 1 ))
done
REINDEX_SEC=$(( $(date +%s) - REINDEX_START ))
INDEXED_ROWS="$LAST_ROW_COUNT"

if [[ "$INDEXED_ROWS" -eq "$FILES" && "$REINDEX_STABLE" -eq 1 ]]; then
    ok "reindex reached the exact fixture cardinality: $INDEXED_ROWS/$FILES rows in ${REINDEX_SEC}s"
else
    record_smoke_failure \
        "reindex did not reach a stable exact cardinality after ${ELAPSED}s: indexed=$INDEXED_ROWS expected=$FILES stable=$REINDEX_STABLE"
    warn "check $APP_LOG and Accessibility if one or more Open Folder drives missed"
fi
if ! verify_owned_pid; then
    record_smoke_failure \
        "isolated app was not alive under exact ownership after reindex polling"
fi

RSS_AFTER_INDEX="$(ps -o rss= -p "$PENSIEVE_PID" 2>/dev/null | awk '{print int($1/1024)}' || echo 0)"

# ─── Search latency via direct FTS5 query ─────────────────────────────────
log "probing search latency via sqlite3 FTS5 query: \"$SEARCH_QUERY\""
SEARCH_MS="?"
SEARCH_HITS="?"
if [[ -f "$INDEX_DB" ]] && (( INDEXED_ROWS > 0 )); then
    START_NS="$(python3 -c 'import time; print(time.monotonic_ns())')"
    SEARCH_HITS="$(/usr/bin/sqlite3 -readonly "$INDEX_DB" \
        "SELECT count(*) FROM workspace_search_documents WHERE workspace_search_documents MATCH '${SEARCH_QUERY}'" \
        2>/dev/null || echo 0)"
    END_NS="$(python3 -c 'import time; print(time.monotonic_ns())')"
    SEARCH_MS=$(( (END_NS - START_NS) / 1000000 ))
else
    warn "index.db empty or missing — search latency skipped"
fi
RSS_AFTER_SEARCH="$(ps -o rss= -p "$PENSIEVE_PID" 2>/dev/null | awk '{print int($1/1024)}' || echo 0)"

# Wait for /usr/bin/sample to finish and preserve its real exit status.
SAMPLE_STATUS=0
if wait "$SAMPLE_PID"; then
    SAMPLE_STATUS=0
else
    SAMPLE_STATUS=$?
fi
SAMPLE_PID=""

# Stop RSS poller before quitting Pensieve so trace stops cleanly
if [[ -n "$RSS_POLLER_PID" ]]; then
    if kill -0 "$RSS_POLLER_PID" 2>/dev/null; then
        /bin/kill "$RSS_POLLER_PID" 2>/dev/null || true
    fi
    wait "$RSS_POLLER_PID" 2>/dev/null || true
fi
RSS_POLLER_PID=""

# ─── Peak RSS from the completed poller trace ─────────────────────────────
PEAK_RSS_MB=0
RSS_VALID=0
if [[ -s "$RSS_TRACE" ]] && awk '
    { samples += 1 }
    NF != 2 || $1 !~ /^[0-9]+$/ || $2 !~ /^[0-9]+$/ || $2 + 0 <= 0 { bad=1 }
    END { exit(bad || samples == 0) }
' "$RSS_TRACE"
then
    RSS_VALID=1
    PEAK_RSS_MB="$(awk '{ if ($2+0 > max) max = $2+0 } END { printf "%d", max/1024 }' "$RSS_TRACE")"
else
    record_smoke_failure "RSS evidence is missing or invalid: $RSS_TRACE"
fi

# ─── Physical footprint (peak) from sample output ─────────────────────────
SAMPLE_PEAK_FOOTPRINT="?"
if [[ -s "$SAMPLE_OUTPUT" ]]; then
    SAMPLE_PEAK_FOOTPRINT="$(awk -F': *' '/Physical footprint \(peak\):/ { print $2; exit }' \
        "$SAMPLE_OUTPUT" | tr -d ' ' || echo '?')"
fi

SAMPLE_VALID=0
if [[ "$SAMPLE_STATUS" -eq 0 ]] \
    && [[ -s "$SAMPLE_OUTPUT" ]] \
    && /usr/bin/grep -q '^Call graph:' "$SAMPLE_OUTPUT" \
    && /usr/bin/grep -q 'Physical footprint (peak):' "$SAMPLE_OUTPUT" \
    && [[ -n "$SAMPLE_PEAK_FOOTPRINT" ]] \
    && [[ "$SAMPLE_PEAK_FOOTPRINT" != "?" ]]
then
    SAMPLE_VALID=1
else
    record_smoke_failure \
        "/usr/bin/sample evidence is invalid (exit=$SAMPLE_STATUS file=$SAMPLE_OUTPUT)"
fi
if ! verify_owned_pid; then
    record_smoke_failure \
        "isolated app was not alive under exact ownership after sampling"
fi

# ─── Extract top stack frames ─────────────────────────────────────────────
# Cap line count in-awk so we don't pipe to `head` (which would SIGPIPE
# the upstream awk under set -e -o pipefail and abort the script).
TOP_STACKS_SNIPPET="(sample produced no Call graph; check $SAMPLE_OUTPUT)"
if [[ -s "$SAMPLE_OUTPUT" ]]; then
    TOP_STACKS_SNIPPET="$(awk -v max=60 '
        /^Call graph:/ { capture=1; print; lines++; next }
        /^Binary Images:/ { exit }
        capture { if (lines < max) { print; lines++ } else { exit } }
    ' "$SAMPLE_OUTPUT")"
    if [[ -z "$TOP_STACKS_SNIPPET" ]]; then
        TOP_STACKS_SNIPPET="$(awk -v max=60 'NR <= max { print }' "$SAMPLE_OUTPUT")"
    fi
fi

# ─── WAL-consistent forensic snapshot ─────────────────────────────────────
# A byte copy of index.db can omit committed WAL pages. sqlite3's backup API
# acquires a coherent read snapshot while the isolated app is still alive.
BACKUP_VALID=0
BACKUP_ROWS="?"
BACKUP_QUICK_CHECK="?"
if [[ -f "$INDEX_DB" ]]; then
    if python3 - "$INDEX_DB" "$INDEX_ARTIFACT" <<PYEOF
import os
import sqlite3
import sys

source_path, destination_path = sys.argv[1:3]
if os.path.exists(destination_path):
    os.unlink(destination_path)
source = sqlite3.connect(source_path)
destination = sqlite3.connect(destination_path)
try:
    source.backup(destination)
finally:
    destination.close()
    source.close()
PYEOF
    then
        BACKUP_QUICK_CHECK="$(/usr/bin/sqlite3 -readonly "$INDEX_ARTIFACT" \
            "PRAGMA quick_check" 2>/dev/null || echo "?")"
        BACKUP_ROWS="$(/usr/bin/sqlite3 -readonly "$INDEX_ARTIFACT" \
            "SELECT count(*) FROM workspace_search_documents" 2>/dev/null || echo "?")"
        if [[ "$BACKUP_QUICK_CHECK" == "ok" ]] \
            && [[ "$BACKUP_ROWS" == "$INDEXED_ROWS" ]]
        then
            BACKUP_VALID=1
            ok "WAL-consistent index snapshot verified: $INDEX_ARTIFACT ($BACKUP_ROWS rows)"
        else
            record_smoke_failure \
                "index snapshot verification failed (quick_check=$BACKUP_QUICK_CHECK rows=$BACKUP_ROWS live_rows=$INDEXED_ROWS)"
        fi
    else
        record_smoke_failure "could not create a WAL-consistent index snapshot from $INDEX_DB"
    fi
else
    record_smoke_failure "could not create a WAL-consistent index snapshot from $INDEX_DB"
fi

# ─── Quit Pensieve through the exact owned identity ───────────────────────
TERMINATION_VALID=0
log "quitting isolated Pensieve process $PENSIEVE_PID"
if verify_owned_pid; then
    if terminate_owned_app "post-measurement termination"; then
        TERMINATION_VALID=1
    else
        record_smoke_failure \
            "isolated app could not be terminated under exact runtime ownership"
    fi
else
    record_smoke_failure \
        "isolated app was absent or changed identity before controlled termination"
fi

# ─── Write report ─────────────────────────────────────────────────────────
COMMIT_SLUG="$(git -C "$REPO_ROOT" rev-parse --short=8 HEAD 2>/dev/null || echo unknown)"
COMMIT_FULL="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"

PEAK_VERDICT="under 200 MB target"
if [[ "$RSS_VALID" -ne 1 ]]; then
    PEAK_VERDICT="UNAVAILABLE — invalid RSS evidence"
elif (( PEAK_RSS_MB > 200 )); then
    PEAK_VERDICT="OVER 200 MB — flag for operator review"
fi

OVERALL_STATUS="PASS (cleanup pending)"
if [[ "$SMOKE_FAILURE_COUNT" -ne 0 ]]; then
    OVERALL_STATUS="FAIL (cleanup pending)"
fi
FAILURE_DETAIL="${SMOKE_FAILURE_SUMMARY:-none}"

cat >"$REPORT" <<EOF
# Search Memory Smoke — $TS — $RUN_TOKEN

| Metric                | Value                          |
|-----------------------|--------------------------------|
| Overall               | **$OVERALL_STATUS**            |
| Run token             | \`$RUN_TOKEN\`                 |
| Commit                | \`$COMMIT_SLUG\` ($COMMIT_FULL) |
| Fixture               | $FILES files × $ROOTS roots ($FIXTURE_SIZE on disk) |
| Fixture gen time      | ${FIXTURE_SEC}s                |
| Fresh launcher        | PASS — exact PID, stable 3s, one empty launcher, no stale surfaces |
| Roots opened          | $ROOT_DRIVE_SUCCESSES/$ROOTS ($ROOT_DRIVE_FAILURES failures) |
| Reindex wall-clock    | ${REINDEX_SEC}s                |
| Indexed rows          | $INDEXED_ROWS / $FILES expected |
| RSS evidence          | valid=$RSS_VALID               |
| Peak RSS (poller)     | **${PEAK_RSS_MB} MB** — $PEAK_VERDICT |
| Sample evidence       | valid=$SAMPLE_VALID, exit=$SAMPLE_STATUS |
| Physical footprint    | $SAMPLE_PEAK_FOOTPRINT (sample) |
| RSS after reindex     | ${RSS_AFTER_INDEX} MB          |
| RSS after search      | ${RSS_AFTER_SEARCH} MB         |
| Search query          | \`$SEARCH_QUERY\`              |
| Search latency        | ${SEARCH_MS} ms (sqlite3 direct FTS5) |
| Search hits           | $SEARCH_HITS                   |
| Sample window         | ${SAMPLE_DURATION_SEC}s        |
| Index snapshot        | valid=$BACKUP_VALID, quick_check=$BACKUP_QUICK_CHECK, rows=$BACKUP_ROWS |
| App termination       | valid=$TERMINATION_VALID       |
| Cleanup               | pending — see \`cleanup-status.txt\` after command exit |

Failure detail: $FAILURE_DETAIL

## Session artifacts

\`\`\`
$SESSION_DIR
├── vault/                      # synthetic fixture (root-1 .. root-$ROOTS)
├── index.db                    # forensic copy; never reused as live state
├── identity.plist              # exact run identity and source commit
├── sample-profile.txt          # /usr/bin/sample output (stack profile)
├── rss-trace.txt               # 0.5s-cadence RSS samples (epoch_sec rss_kb)
├── cleanup-status.txt          # authoritative post-exit cleanup outcome
└── app.log                     # isolated Pensieve stdout/stderr
\`\`\`

## /usr/bin/sample — Call graph excerpt

\`\`\`
$TOP_STACKS_SNIPPET
\`\`\`

## Notes

- Brief: W-C-1 (B-04 / audit F-8-R03 close-out).
- The fresh-profile baseline ran before fixture creation and proved for about three seconds that the exact PID exposed exactly one empty launcher, with no workspace, open-files, recovery or recents surfaces in any sample.
- Source bundle: $SOURCE_APP at commit \`$SOURCE_COMMIT\`.
- Isolated identity: \`$APP_BUNDLE_ID\`, executable \`$EXECUTABLE_NAME\`, support root \`$SMOKE_APPSUP\` and a run-specific Keychain service. The PID was resolved back to the exact staged bundle and executable before any UI drive or sampling.
- Production boundary: \`io.vetcoders.pensieve\` and \`~/Library/Application Support/Pensieve\` were never moved, reset, queried or terminated. Cleanup is scoped to the manifest-owned run identity; its post-exit result is recorded in \`$CLEANUP_STATUS_FILE\` rather than predicted by this report.
- Workspace populated by AppleScript driving File → Open Folder (⌘⇧O) → Go to Folder (⌘⇧G) → path → Return → Return, repeated for each root. Each \`controller.openFolder(url:)\` call appends a new root via \`mergedRoots(current:adding:)\`; the workspace builder reindexes against all roots together.
- Clipboard contents were snapshotted and restored around every Open Folder drive, including AppleScript failure paths.
- \`index.db\` is a SQLite backup-API snapshot of the live WAL database, followed by \`PRAGMA quick_check\` and row-count verification; it is not a raw file copy.
- Search latency is the direct FTS5 query against the populated
  \`workspace_search_documents\` table — proxies the in-process
  \`IndexDatabase.performSearch\` cost; does not include the UI debounce
  or main-thread hop.
- Peak RSS is from a 0.5s-cadence \`ps -o rss=\` poller, max over the
  reindex+search window. Physical footprint (peak) is from sample.
- F-8 target: peak RSS under 200 MB for ~1000 files. Anything higher is
  informational here (no test assertion) and should be triaged by the
  operator.

EOF

ok "report written: $REPORT"
echo ""
echo "  Overall:  $OVERALL_STATUS"
echo "  Peak RSS: ${PEAK_RSS_MB} MB ($PEAK_VERDICT)"
echo "  Sample:   physical footprint peak $SAMPLE_PEAK_FOOTPRINT"
echo "  Reindex:  ${REINDEX_SEC}s wall-clock, $INDEXED_ROWS rows"
echo "  Search:   ${SEARCH_MS} ms ($SEARCH_HITS hits for \"$SEARCH_QUERY\")"
echo ""
echo "  Report:   $REPORT"
echo "  Session:  $SESSION_DIR"

if [[ "$SMOKE_FAILURE_COUNT" -ne 0 ]]; then
    die "search-memory smoke failed: $SMOKE_FAILURE_SUMMARY"
fi
