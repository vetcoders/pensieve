#!/usr/bin/env bash

# Shared macOS app-isolation primitives for Pensieve smoke harnesses.
#
# This file is sourced by scripts that already choose their own `set` flags. It
# deliberately does not enable `set -euo pipefail`: every public function
# returns a status so callers can preserve their own cleanup and error policy.
# The implementation stays compatible with the system Bash 3.2 shipped by
# macOS.

ISOLATED_APP_PRODUCTION_BUNDLE_ID="io.vetcoders.pensieve"
ISOLATED_APP_PRODUCTION_KEYCHAIN_SERVICE="io.vetcoders.pensieve.completion-provider"
ISOLATED_APP_KEYCHAIN_ACCOUNT="api-key"
ISOLATED_APP_TRUSTED_TEAM_IDENTIFIER="MW223P3NPX"
ISOLATED_APP_REQUIRED_BUILD_CONFIGURATION="release"
ISOLATED_APP_REQUIRED_BUILD_ARCHITECTURE="arm64"
ISOLATED_APP_REQUIRED_FFI_PROFILE="release"
ISOLATED_APP_REQUIRED_ENTITLEMENTS="Pensieve/Resources/Pensieve.entitlements"
ISOLATED_APP_SIGNING_MODE=""

ISOLATED_APP_LIB_DIR="$(cd "$(/usr/bin/dirname "${BASH_SOURCE[0]}")" && pwd)"
ISOLATED_APP_SYSTEM_EVENTS_PREFLIGHT_SCRIPT="$ISOLATED_APP_LIB_DIR/system-events-preflight.applescript"
# shellcheck source=scripts/lib/build-provenance.sh
source "$ISOLATED_APP_LIB_DIR/build-provenance.sh"

isolated_app_error() {
  printf 'isolated-app: %s\n' "$*" >&2
}

# Run a command behind a watchdog available on a stock macOS installation.
# Callers use this before any UI-owned state exists, so an unavailable watchdog
# is an environment result instead of permission to run an unbounded probe.
isolated_app_run_bounded_command() {
  local timeout_seconds="${1:-}"
  shift || return 2
  [[ "$timeout_seconds" =~ ^[1-9][0-9]*$ && $# -gt 0 ]] || return 2

  if command -v gtimeout >/dev/null 2>&1; then
    gtimeout --signal=TERM "$timeout_seconds" "$@"
    return $?
  fi
  if [[ -x /usr/bin/perl ]]; then
    /usr/bin/perl -e '
      use strict;
      use warnings;
      my $seconds = shift @ARGV;
      die "invalid timeout\n" unless defined($seconds) && $seconds =~ /\A[1-9][0-9]*\z/;
      alarm($seconds);
      exec @ARGV;
      die "could not exec bounded command: $!\n";
    ' "$timeout_seconds" "$@"
    return $?
  fi
  isolated_app_error \
    "no bounded command watchdog is available (need gtimeout or /usr/bin/perl)"
  return 3
}

# Prove that the current *calling process* can drive the same System Events
# Automation + Accessibility route used by the smoke harness. This must run
# before staging, cleaning a previous manual experiment, minting a capsule, or
# launching Pensieve. A TCC denial is therefore environment-inconclusive and
# cannot leave behind an app, defaults domain, Open Recent row, or support tree.
#
isolated_app_assert_system_events_automation() {
  local output="" status=0
  [[ -f "$ISOLATED_APP_SYSTEM_EVENTS_PREFLIGHT_SCRIPT" ]] || {
    isolated_app_error \
      "tracked System Events preflight is missing: $ISOLATED_APP_SYSTEM_EVENTS_PREFLIGHT_SCRIPT"
    return 1
  }
  output="$(isolated_app_run_bounded_command \
    10 /usr/bin/osascript "$ISOLATED_APP_SYSTEM_EVENTS_PREFLIGHT_SCRIPT" 2>&1)" \
    || status=$?

  if [[ "$status" -ne 0 ]]; then
    case "$output" in
      *-1743* | *"Not authorized"* | *"not authorized"* | *"assistive access"* \
        | *"Accessibility UI scripting is disabled"* \
        | *"No frontmost application process is available"*)
        isolated_app_error \
          "System Events Automation/Accessibility is unavailable for the host running this command; allow that host in System Settings > Privacy & Security > Automation and Accessibility; no smoke identity was created"
        [[ -z "$output" ]] || printf '%s\n' "$output" >&2
        return 3
        ;;
    esac
    case "$status" in
      3 | 124 | 142)
        isolated_app_error \
          "System Events preflight failed before smoke staging; no smoke identity was created"
        [[ -z "$output" ]] || printf '%s\n' "$output" >&2
        return 3
        ;;
    esac
    isolated_app_error \
      "System Events preflight script failed before smoke staging"
    [[ -z "$output" ]] || printf '%s\n' "$output" >&2
    return 1
  fi
  [[ "$output" == "SYSTEM_EVENTS_AUTOMATION=PASS" ]] || {
    isolated_app_error \
      "System Events preflight returned an unexpected witness before smoke staging"
    [[ -z "$output" ]] || printf '%s\n' "$output" >&2
    return 1
  }
  printf '%s\n' "$output"
}

isolated_app_signing_mode() {
  printf '%s\n' "$ISOLATED_APP_SIGNING_MODE"
}

isolated_app_manifest_value() {
  local manifest="${1:-}"
  local key="${2:-}"
  [[ -f "$manifest" && -n "$key" ]] || return 1
  /usr/bin/plutil -extract "$key" raw -o - -- "$manifest" 2>/dev/null
}

isolated_app_plist_value() {
  local plist="${1:-}"
  local key="${2:-}"
  [[ -f "$plist" && -n "$key" ]] || return 1
  /usr/bin/plutil -extract "$key" raw -o - -- "$plist" 2>/dev/null
}

isolated_app_plist_set_string() {
  local plist="${1:-}"
  local key="${2:-}"
  local value="${3:-}"
  [[ -f "$plist" && -n "$key" ]] || return 1
  /usr/bin/plutil -replace "$key" -string "$value" -- "$plist" >/dev/null 2>&1 \
    || /usr/bin/plutil -insert "$key" -string "$value" -- "$plist" >/dev/null 2>&1
}

isolated_app_source_team_identifier() {
  local source_bundle="${1:-}"
  local team
  isolated_app_assert_bundle_path "$source_bundle" || return 1
  team="$(/usr/bin/codesign -d --verbose=4 "$source_bundle" 2>&1 \
    | /usr/bin/sed -n 's/^TeamIdentifier=//p' | /usr/bin/head -n 1)" || return 1
  [[ -n "$team" && "$team" != "not set" ]] || {
    isolated_app_error "source bundle has no sealed TeamIdentifier: $source_bundle"
    return 1
  }
  printf '%s\n' "$team"
}

isolated_app_assert_strict_signature() {
  local bundle="${1:-}"
  isolated_app_assert_bundle_path "$bundle" || return 1
  /usr/bin/codesign --verify --deep --strict "$bundle" >/dev/null 2>&1 || {
    isolated_app_error "bundle failed strict codesign verification: $bundle"
    return 1
  }
}

isolated_app_assert_trusted_source_signature() {
  local source_bundle="${1:-}"
  local team
  isolated_app_assert_strict_signature "$source_bundle" || return 1
  team="$(isolated_app_source_team_identifier "$source_bundle")" || return 1
  [[ "$team" == "$ISOLATED_APP_TRUSTED_TEAM_IDENTIFIER" ]] || {
    isolated_app_error \
      "source bundle TeamIdentifier $team is not trusted (expected $ISOLATED_APP_TRUSTED_TEAM_IDENTIFIER)"
    return 1
  }
}

# Isolated staging deliberately starts from the Developer ID product lane.
# Reusing an already rewritten smoke bundle would inherit an untrusted profile
# lineage, while a Mac App Store build would move defaults and support data into
# a sandbox container that this cleanup contract does not own. Reject both
# shapes before any override or destination mutation.
isolated_app_assert_supported_source_bundle() {
  local source_bundle="${1:-}"
  local plist bundle_id executable entitlements sandboxed="false"
  isolated_app_assert_bundle_path "$source_bundle" || return 1
  plist="$source_bundle/Contents/Info.plist"
  bundle_id="$(isolated_app_plist_value "$plist" CFBundleIdentifier)" || return 1
  executable="$(isolated_app_plist_value "$plist" CFBundleExecutable)" || return 1
  [[ "$bundle_id" == "$ISOLATED_APP_PRODUCTION_BUNDLE_ID" ]] || {
    isolated_app_error \
      "source bundle must use the canonical Pensieve product identity, found: $bundle_id"
    return 1
  }
  [[ "$executable" == "Pensieve" ]] || {
    isolated_app_error \
      "source bundle must use the canonical Pensieve executable, found: $executable"
    return 1
  }

  entitlements="$(/usr/bin/codesign -d --entitlements :- "$source_bundle" 2>/dev/null)" \
    || {
      isolated_app_error "could not read source bundle entitlements: $source_bundle"
      return 1
    }
  if [[ -n "$entitlements" ]]; then
    printf '%s' "$entitlements" | /usr/bin/plutil -lint - >/dev/null 2>&1 || {
      isolated_app_error "source bundle entitlements are not a readable plist"
      return 1
    }
    # Entitlement names contain dots. `plutil -extract` treats them as a
    # key-path and can silently miss the literal sandbox key; PlistBuddy reads
    # the dotted dictionary key literally.
    sandboxed="$(printf '%s' "$entitlements" \
      | /usr/libexec/PlistBuddy \
        -c 'Print :com.apple.security.app-sandbox' /dev/stdin 2>/dev/null \
      || printf 'false')"
  fi
  [[ "$sandboxed" != "true" && "$sandboxed" != "1" ]] || {
    isolated_app_error \
      "Mac App Store sandbox bundles are not supported by the Developer ID smoke cleanup lane"
    return 1
  }
}

# Validate the sealed provenance record against the payload that actually sits
# in the bundle. This deliberately does not trust caller-supplied hashes. It is
# also valid after identity rewriting: canonical Mach-O digests remove the
# signature and non-runtime debug/linkedit bookkeeping while still detecting
# changed code, data, exports, relocations and dylib load commands.
isolated_app_verify_embedded_provenance() {
  local bundle="${1:-}"
  local verification_mode="${2:-strict}"
  local manifest info_plist executable commit info_commit input_digest ffi_profile
  local configuration architecture main_macho ffi_macho

  case "$verification_mode" in
    strict|staged) ;;
    *)
      isolated_app_error "unknown embedded-provenance mode: $verification_mode"
      return 1
      ;;
  esac

  isolated_app_assert_bundle_path "$bundle" || return 1
  manifest="$(build_provenance_bundle_manifest_path "$bundle")"
  info_plist="$bundle/Contents/Info.plist"
  [[ -f "$manifest" && -f "$info_plist" ]] || {
    isolated_app_error "bundle is missing its sealed build provenance or Info.plist: $bundle"
    return 1
  }
  executable="$(isolated_app_plist_value "$info_plist" CFBundleExecutable)" || return 1
  [[ -n "$executable" && "$executable" != */* ]] || return 1
  main_macho="$bundle/Contents/MacOS/$executable"
  ffi_macho="$bundle/Contents/Frameworks/libqube_ffi.dylib"
  [[ -f "$main_macho" && -f "$ffi_macho" ]] || {
    isolated_app_error "bundle is missing a provenance-pinned runtime payload: $bundle"
    return 1
  }

  commit="$(build_provenance_read_manifest_value "$manifest" Commit)" || return 1
  info_commit="$(isolated_app_plist_value "$info_plist" PensieveBuildCommit)" || return 1
  [[ "$commit" == "$info_commit" ]] || {
    isolated_app_error "embedded provenance commit does not match Info.plist"
    return 1
  }
  input_digest="$(build_provenance_read_manifest_value \
    "$manifest" RuntimeInputSHA256)" || return 1
  ffi_profile="$(build_provenance_read_manifest_value "$manifest" FFIProfile)" || return 1
  configuration="$(build_provenance_read_manifest_value \
    "$manifest" BuildConfiguration)" || return 1
  architecture="$(build_provenance_read_manifest_value "$manifest" Architecture)" || return 1
  [[ "$configuration" == "$ISOLATED_APP_REQUIRED_BUILD_CONFIGURATION" ]] || {
    isolated_app_error \
      "source build configuration $configuration is not the required $ISOLATED_APP_REQUIRED_BUILD_CONFIGURATION"
    return 1
  }
  [[ "$architecture" == "$ISOLATED_APP_REQUIRED_BUILD_ARCHITECTURE" ]] || {
    isolated_app_error \
      "source build architecture $architecture is not the required $ISOLATED_APP_REQUIRED_BUILD_ARCHITECTURE"
    return 1
  }

  if [[ "$verification_mode" == "staged" ]]; then
    build_provenance_verify_staged_manifest \
      "$manifest" "$commit" "$input_digest" "$ffi_profile" "$configuration" \
      "$architecture" "$main_macho" "$ffi_macho"
  else
    build_provenance_verify_manifest \
      "$manifest" "$commit" "$input_digest" "$ffi_profile" "$configuration" \
      "$architecture" "$main_macho" "$ffi_macho"
  fi
}

isolated_app_runtime_input_status() {
  local repo_root="${1:-}"
  local ffi_profile="${2:-}"
  /usr/bin/git -C "$repo_root" status --porcelain=v1 --untracked-files=all -- \
    VERSION \
    scripts/build-release.sh \
    scripts/lib/bundle-identity.sh \
    scripts/lib/build-provenance.sh \
    scripts/lib/rpath-hygiene.sh \
    Pensieve/Package.swift \
    Pensieve/Package.resolved \
    Pensieve/Sources \
    Pensieve/Resources \
    Pensieve/scripts \
    "Pensieve/Vendor/qube-ffi/$ffi_profile/libqube_ffi.dylib" 2>/dev/null
}

# isolated_app_assert_source_provenance <repo-root> <source.app>
#   [allow-historical] [allow-dirty-runtime-inputs]
#
# Missing/invalid signatures, the wrong TeamIdentifier, missing provenance and
# payload mismatches are never overridable. A historical override is honored
# only when the artifact commit really differs from HEAD. For a current-commit
# artifact, dirty input bytes require the dirty override AND must still hash to
# exactly the digest sealed into the app. Harness-only edits are not runtime
# inputs and therefore do not make an otherwise exact build stale.
isolated_app_assert_source_provenance() {
  local repo_root="${1:-}"
  local source_bundle="${2:-}"
  local allow_historical="${3:-0}"
  local allow_dirty="${4:-0}"
  local expected_commit actual_commit ffi_profile embedded_input commit_input
  local current_input dirty_runtime_inputs current_differs_from_commit="false"

  isolated_app_assert_absolute_path "$repo_root" "repository root" || return 1
  isolated_app_assert_bundle_path "$source_bundle" || return 1
  [[ "$allow_historical" == "0" || "$allow_historical" == "1" ]] || return 1
  [[ "$allow_dirty" == "0" || "$allow_dirty" == "1" ]] || return 1
  /usr/bin/git -C "$repo_root" rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
    isolated_app_error "cannot prove source provenance outside a Git worktree: $repo_root"
    return 1
  }

  # These checks are deliberately before every override branch. The embedded
  # manifest proves payload self-consistency; the release-policy verifier below
  # additionally proves the exact Developer ID certificate lineage, canonical
  # product identity, entitlements, hardened runtime, version/build numbering,
  # architecture and FFI profile.
  isolated_app_assert_trusted_source_signature "$source_bundle" || return 1
  isolated_app_assert_supported_source_bundle "$source_bundle" || return 1
  isolated_app_verify_embedded_provenance "$source_bundle" || return 1

  expected_commit="$(/usr/bin/git -C "$repo_root" rev-parse HEAD 2>/dev/null)" || return 1
  actual_commit="$(isolated_app_plist_value \
    "$source_bundle/Contents/Info.plist" PensieveBuildCommit)" || return 1
  ffi_profile="$(build_provenance_read_manifest_value \
    "$(build_provenance_bundle_manifest_path "$source_bundle")" FFIProfile)" || return 1
  [[ "$ffi_profile" == "$ISOLATED_APP_REQUIRED_FFI_PROFILE" ]] || {
    isolated_app_error \
      "source FFI profile $ffi_profile is not the required $ISOLATED_APP_REQUIRED_FFI_PROFILE"
    return 1
  }
  embedded_input="$(build_provenance_read_manifest_value \
    "$(build_provenance_bundle_manifest_path "$source_bundle")" \
    RuntimeInputSHA256)" || return 1
  commit_input="$(build_provenance_commit_runtime_input_digest \
    "$repo_root" "$actual_commit" "$ffi_profile")" || {
    isolated_app_error \
      "could not independently reproduce runtime inputs from source commit $actual_commit"
    return 1
  }

  if [[ "$actual_commit" != "$expected_commit" ]]; then
    if [[ "$allow_historical" != "1" ]]; then
      isolated_app_error \
        "source app commit $actual_commit does not match worktree HEAD $expected_commit"
      return 1
    fi
    [[ "$embedded_input" == "$commit_input" ]] || {
      isolated_app_error \
        "historical source is not an exact build of commit $actual_commit; historical dirty artifacts are never accepted"
      return 1
    }
    build_provenance_verify_bundle_against_commit_digest \
      "$source_bundle" \
      "$repo_root" \
      "$actual_commit" \
      "$commit_input" \
      "$ISOLATED_APP_REQUIRED_BUILD_CONFIGURATION" \
      "$ISOLATED_APP_REQUIRED_BUILD_ARCHITECTURE" \
      "$ISOLATED_APP_REQUIRED_FFI_PROFILE" \
      "$ISOLATED_APP_TRUSTED_TEAM_IDENTIFIER" \
      "git:$ISOLATED_APP_REQUIRED_ENTITLEMENTS" \
      true \
      "$ISOLATED_APP_PRODUCTION_BUNDLE_ID" \
      Pensieve \
      Pensieve \
      developer-id || return 1
    isolated_app_error \
      "warning: intentionally testing commit-exact historical source $actual_commit (HEAD $expected_commit)"
    printf '%s\n' "$actual_commit"
    return 0
  fi

  dirty_runtime_inputs="$(isolated_app_runtime_input_status "$repo_root" "$ffi_profile")" \
    || return 1
  current_input="$(build_provenance_runtime_input_digest "$repo_root" "$ffi_profile")" \
    || return 1
  if [[ "$current_input" != "$commit_input" ]]; then
    current_differs_from_commit="true"
  fi
  if [[ ( -n "$dirty_runtime_inputs" || "$current_differs_from_commit" == "true" ) \
    && "$allow_dirty" != "1" ]]; then
    isolated_app_error "runtime inputs differ from HEAD; rebuild or use the explicit dirty-input lane:"
    if [[ -n "$dirty_runtime_inputs" ]]; then
      printf '%s\n' "$dirty_runtime_inputs" >&2
    else
      isolated_app_error \
        "runtime bytes differ even though Git status hides the mutation"
    fi
    return 1
  fi
  [[ "$current_input" == "$embedded_input" ]] || {
    isolated_app_error \
      "source app runtime-input digest does not match the current worktree bytes; rebuild required"
    return 1
  }

  if [[ "$embedded_input" == "$commit_input" ]]; then
    build_provenance_verify_bundle_against_commit_digest \
      "$source_bundle" \
      "$repo_root" \
      "$actual_commit" \
      "$commit_input" \
      "$ISOLATED_APP_REQUIRED_BUILD_CONFIGURATION" \
      "$ISOLATED_APP_REQUIRED_BUILD_ARCHITECTURE" \
      "$ISOLATED_APP_REQUIRED_FFI_PROFILE" \
      "$ISOLATED_APP_TRUSTED_TEAM_IDENTIFIER" \
      "git:$ISOLATED_APP_REQUIRED_ENTITLEMENTS" \
      true \
      "$ISOLATED_APP_PRODUCTION_BUNDLE_ID" \
      Pensieve \
      Pensieve \
      developer-id || return 1
  else
    [[ "$allow_dirty" == "1" ]] || {
      isolated_app_error "a dirty source artifact requires the explicit dirty-input lane"
      return 1
    }
    build_provenance_verify_bundle_against_source \
      "$source_bundle" \
      "$repo_root" \
      "$actual_commit" \
      "$ISOLATED_APP_REQUIRED_BUILD_CONFIGURATION" \
      "$ISOLATED_APP_REQUIRED_BUILD_ARCHITECTURE" \
      "$ISOLATED_APP_REQUIRED_FFI_PROFILE" \
      "$ISOLATED_APP_TRUSTED_TEAM_IDENTIFIER" \
      "git:$ISOLATED_APP_REQUIRED_ENTITLEMENTS" \
      true \
      "$ISOLATED_APP_PRODUCTION_BUNDLE_ID" \
      Pensieve \
      Pensieve \
      developer-id \
      "$embedded_input" || return 1
  fi
  if [[ -n "$dirty_runtime_inputs" || "$current_differs_from_commit" == "true" ]]; then
    isolated_app_error "warning: testing an artifact built from the exact current dirty runtime inputs:"
    if [[ -n "$dirty_runtime_inputs" ]]; then
      printf '%s\n' "$dirty_runtime_inputs" >&2
    else
      isolated_app_error \
        "Git status hid the mutation, but byte-level provenance matched the artifact"
    fi
  fi

  # The commit verifier and fresh dependency resolution above are deliberately
  # expensive. Re-read HEAD after them so a concurrent docs-only checkout or
  # commit cannot relabel this current-source run as current while leaving the
  # compiler-visible digest unchanged.
  build_provenance_assert_head "$repo_root" "$expected_commit" || return 1

  printf '%s\n' "$actual_commit"
}

isolated_app_assert_nonproduction_id() {
  local bundle_id="${1:-}"
  if [[ -z "$bundle_id" ]]; then
    isolated_app_error "bundle identifier is empty"
    return 1
  fi
  if [[ "$bundle_id" == "$ISOLATED_APP_PRODUCTION_BUNDLE_ID" ]]; then
    isolated_app_error "refusing production bundle identifier $bundle_id"
    return 1
  fi
  return 0
}

# Destructive helpers accept only identities minted by the isolated lanes
# in this repository. Merely being "not production" is not enough authority to
# delete another application's profile.
isolated_app_assert_owned_id() {
  local bundle_id="${1:-}"
  isolated_app_assert_nonproduction_id "$bundle_id" || return 1
  if [[ "$bundle_id" \
    =~ ^io\.vetcoders\.pensieve\.(manual|smoke|memory|bugmap)\.r[0-9a-f]{32}$ ]]; then
    return 0
  fi
  isolated_app_error "refusing non-isolated bundle identifier $bundle_id"
  return 1
}

isolated_app_generate_bundle_id() {
  local lane="${1:-manual}"
  local token
  case "$lane" in
    manual | smoke | memory | bugmap) ;;
    *)
      isolated_app_error "unsupported isolated identity lane: $lane"
      return 1
      ;;
  esac
  token="$(/usr/bin/uuidgen 2>/dev/null | /usr/bin/tr '[:upper:]' '[:lower:]' \
    | /usr/bin/tr -d '-')" || return 1
  [[ -n "$token" ]] || return 1
  printf 'io.vetcoders.pensieve.%s.r%s\n' "$lane" "$token"
}

isolated_app_assert_keychain_service() {
  local bundle_id="${1:-}"
  local service="${2:-}"
  isolated_app_assert_owned_id "$bundle_id" || return 1
  if [[ "$service" != "$bundle_id.completion-provider" ]]; then
    isolated_app_error \
      "keychain service must be derived from the isolated bundle id: $bundle_id.completion-provider"
    return 1
  fi
  if [[ "$service" == "$ISOLATED_APP_PRODUCTION_KEYCHAIN_SERVICE" ]]; then
    isolated_app_error "refusing production Keychain service $service"
    return 1
  fi
  return 0
}

isolated_app_assert_absolute_path() {
  local path="${1:-}"
  local purpose="${2:-path}"
  if [[ -z "$path" || "$path" != /* ]]; then
    isolated_app_error "$purpose must be an absolute path: ${path:-<empty>}"
    return 1
  fi
  case "$path" in
    / | "$HOME" | "$HOME/Library" | "$HOME/Library/Application Support")
      isolated_app_error "refusing broad $purpose: $path"
      return 1
      ;;
    */../* | */.. | */./* | */.)
      isolated_app_error "refusing non-normalized $purpose: $path"
      return 1
      ;;
  esac
  return 0
}

isolated_app_canonical_directory() {
  local path="${1:-}"
  local purpose="${2:-directory}"
  isolated_app_assert_absolute_path "$path" "$purpose" || return 1
  if [[ ! -d "$path" || -L "$path" ]]; then
    isolated_app_error "$purpose must be a real directory, not a symlink: $path"
    return 1
  fi
  (
    cd -P -- "$path" 2>/dev/null || exit 1
    pwd -P
  )
}

isolated_app_assert_canonical_directory() {
  local path="${1:-}"
  local purpose="${2:-directory}"
  local canonical actual_uid expected_uid
  canonical="$(isolated_app_canonical_directory "$path" "$purpose")" || return 1
  if [[ "$canonical" != "$path" ]]; then
    isolated_app_error "$purpose must use its canonical path: $path -> $canonical"
    return 1
  fi
  actual_uid="$(/usr/bin/stat -f '%u' -- "$path" 2>/dev/null)" || return 1
  expected_uid="$(/usr/bin/id -u)" || return 1
  if [[ "$actual_uid" != "$expected_uid" ]]; then
    isolated_app_error \
      "$purpose must be owned by uid $expected_uid, observed uid $actual_uid: $path"
    return 1
  fi
  return 0
}

isolated_app_assert_direct_owned_path() {
  local owner_root="${1:-}"
  local path="${2:-}"
  local purpose="${3:-owned path}"
  local parent canonical_parent
  isolated_app_assert_canonical_directory "$owner_root" "isolated owner root" || return 1
  isolated_app_assert_absolute_path "$path" "$purpose" || return 1
  if [[ -L "$path" ]]; then
    isolated_app_error "$purpose must not be a symlink: $path"
    return 1
  fi
  parent="$(/usr/bin/dirname "$path")" || return 1
  if [[ "$parent" != "$owner_root" ]]; then
    isolated_app_error "$purpose must be a direct child of $owner_root: $path"
    return 1
  fi
  canonical_parent="$(isolated_app_canonical_directory "$parent" "$purpose parent")" \
    || return 1
  if [[ "$canonical_parent" != "$owner_root" ]]; then
    isolated_app_error "$purpose parent escapes its canonical owner: $path"
    return 1
  fi
  return 0
}

isolated_app_assert_support_path() {
  local path="${1:-}"
  isolated_app_assert_absolute_path "$path" "support path" || return 1
  if [[ "$path" == "$HOME/Library/Application Support/Pensieve" ]]; then
    isolated_app_error "refusing production Application Support path $path"
    return 1
  fi
  if [[ -L "$path" ]]; then
    isolated_app_error "support path must not be a symlink: $path"
    return 1
  fi
  if [[ -e "$path" && ! -d "$path" ]]; then
    isolated_app_error "support path must be a directory when it exists: $path"
    return 1
  fi
  return 0
}

isolated_app_assert_bundle_path() {
  local path="${1:-}"
  isolated_app_assert_absolute_path "$path" "bundle path" || return 1
  case "$path" in
    *.app) ;;
    *)
      isolated_app_error "bundle path is not an .app: $path"
      return 1
      ;;
  esac
  if [[ "$path" == "/Applications/Pensieve.app" ]]; then
    isolated_app_error "refusing production application bundle $path"
    return 1
  fi
  return 0
}

isolated_app_assert_shared_owner_parent() {
  local bundle_path="${1:-}"
  local support_path="${2:-}"
  local bundle_parent support_parent canonical_parent
  isolated_app_assert_bundle_path "$bundle_path" || return 1
  isolated_app_assert_support_path "$support_path" || return 1
  if [[ -L "$bundle_path" || -L "$support_path" ]]; then
    isolated_app_error "bundle and support paths must not be symlinks"
    return 1
  fi
  bundle_parent="$(/usr/bin/dirname "$bundle_path")" || return 1
  support_parent="$(/usr/bin/dirname "$support_path")" || return 1
  if [[ "$bundle_parent" != "$support_parent" ]]; then
    isolated_app_error \
      "bundle and support paths must share one isolated owner directory: $bundle_path ; $support_path"
    return 1
  fi
  canonical_parent="$(isolated_app_canonical_directory \
    "$bundle_parent" "isolated owner directory")" || return 1
  if [[ "$canonical_parent" != "$bundle_parent" ]]; then
    isolated_app_error \
      "bundle/support owner must use its canonical path: $bundle_parent -> $canonical_parent"
    return 1
  fi
  return 0
}

isolated_app_preferences_path() {
  local bundle_id="${1:-}"
  isolated_app_assert_owned_id "$bundle_id" || return 1
  printf '%s/Library/Preferences/%s.plist\n' "$HOME" "$bundle_id"
}

isolated_app_recent_documents_path() {
  local bundle_id="${1:-}"
  isolated_app_assert_owned_id "$bundle_id" || return 1
  printf '%s/Library/Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.ApplicationRecentDocuments/%s.sfl4\n' \
    "$HOME" "$bundle_id"
}

# The SharedFileList daemon can publish an application-specific recent-documents
# file after the application process has already exited. A single unlink is
# therefore not evidence that the UUID-owned list was retired. Keep removing
# only the exact owned path until it has remained absent for a bounded quiet
# period; fail closed if the daemon never quiesces.
isolated_app_retire_recent_documents() {
  local bundle_id="${1:-}"
  local recent_path attempt=0 quiet_checks=0
  local required_quiet_checks=30
  local maximum_checks=100

  isolated_app_assert_owned_id "$bundle_id" || return 1
  recent_path="$(isolated_app_recent_documents_path "$bundle_id")" || return 1
  while [[ "$attempt" -lt "$maximum_checks" ]]; do
    isolated_app_remove_exact_path \
      "$recent_path" "isolated recent-documents list" || return 1
    /bin/sleep 0.1
    if [[ -e "$recent_path" || -L "$recent_path" ]]; then
      quiet_checks=0
    else
      quiet_checks=$((quiet_checks + 1))
      if [[ "$quiet_checks" -ge "$required_quiet_checks" ]]; then
        return 0
      fi
    fi
    attempt=$((attempt + 1))
  done

  isolated_app_error \
    "recent-documents list did not remain retired for $bundle_id: $recent_path"
  return 1
}

isolated_app_saved_state_path() {
  local bundle_id="${1:-}"
  isolated_app_assert_owned_id "$bundle_id" || return 1
  printf '%s/Library/Saved Application State/%s.savedState\n' "$HOME" "$bundle_id"
}

isolated_app_sandbox_saved_state_path() {
  local bundle_id="${1:-}"
  isolated_app_assert_owned_id "$bundle_id" || return 1
  printf '%s/Library/Containers/%s/Data/Library/Saved Application State/%s.savedState\n' \
    "$HOME" "$bundle_id" "$bundle_id"
}

isolated_app_cache_path() {
  local bundle_id="${1:-}"
  isolated_app_assert_owned_id "$bundle_id" || return 1
  printf '%s/Library/Caches/%s\n' "$HOME" "$bundle_id"
}

isolated_app_webkit_path() {
  local bundle_id="${1:-}"
  isolated_app_assert_owned_id "$bundle_id" || return 1
  printf '%s/Library/WebKit/%s\n' "$HOME" "$bundle_id"
}

# WebKit's auxiliary processes use two per-user Darwin directories outside
# ~/Library. `getconf` is the only source of truth for these roots; canonicalize
# its /var spelling before recording or comparing coordinates so a manifest
# cannot redirect cleanup through an alias or a caller-controlled TMPDIR.
isolated_app_darwin_user_directory() {
  local kind="${1:-}"
  local key path canonical expected_leaf
  case "$kind" in
    cache)
      key="DARWIN_USER_CACHE_DIR"
      expected_leaf="C"
      ;;
    temp)
      key="DARWIN_USER_TEMP_DIR"
      expected_leaf="T"
      ;;
    *) return 1 ;;
  esac
  path="$(/usr/bin/getconf "$key" 2>/dev/null)" || return 1
  path="${path%/}"
  isolated_app_assert_absolute_path "$path" "$key" || return 1
  [[ -d "$path" && ! -L "$path" ]] || return 1
  canonical="$(cd -P -- "$path" 2>/dev/null && pwd -P)" || return 1
  isolated_app_assert_canonical_directory "$canonical" "$key" || return 1
  [[ "$(/usr/bin/basename "$canonical")" == "$expected_leaf" ]] || {
    isolated_app_error "$key did not resolve to the expected $expected_leaf directory"
    return 1
  }
  printf '%s\n' "$canonical"
}

isolated_app_darwin_webkit_path() {
  local bundle_id="${1:-}"
  local root="${2:-}"
  local role="${3:-}"
  isolated_app_assert_owned_id "$bundle_id" || return 1
  isolated_app_assert_canonical_directory "$root" "Darwin WebKit root" || return 1
  case "$role" in GPU | Networking | WebContent) ;; *) return 1 ;; esac
  printf '%s/com.apple.WebKit.%s+%s\n' "$root" "$role" "$bundle_id"
}

isolated_app_darwin_webkit_cache_is_empty() {
  local bundle_id="${1:-}"
  local root="${2:-}"
  local role path
  isolated_app_assert_owned_id "$bundle_id" || return 2
  isolated_app_assert_canonical_directory "$root" "Darwin WebKit cache root" || return 2
  for role in GPU Networking WebContent; do
    path="$(isolated_app_darwin_webkit_path "$bundle_id" "$root" "$role")" || return 2
    [[ ! -e "$path" && ! -L "$path" ]] || return 1
  done
  return 0
}

isolated_app_darwin_webkit_temp_metadata_is_protected() {
  local mode="${1:-}"
  local flags_decimal="${2:-}"
  local rootless_value="${3:-}"
  [[ "$flags_decimal" =~ ^[0-9]+$ ]] || return 1
  [[ "$mode" == "700" \
    && "$((flags_decimal & 1048576))" -ne 0 \
    && "$rootless_value" == "folders" ]]
}

isolated_app_darwin_webkit_temp_shell_metadata() {
  local path="${1:-}"
  local actual_uid mode flags_decimal rootless_value
  isolated_app_assert_absolute_path "$path" "Darwin WebKit temp shell" || return 2
  actual_uid="$(/usr/bin/stat -f '%u' -- "$path" 2>/dev/null)" || return 2
  mode="$(/usr/bin/stat -f '%Lp' -- "$path" 2>/dev/null)" || return 2
  flags_decimal="$(/usr/bin/stat -f '%f' -- "$path" 2>/dev/null)" || return 2
  rootless_value="$(
    /usr/bin/xattr -p com.apple.rootless "$path" 2>/dev/null
  )" || return 2
  printf '%s|%s|%s|%s\n' \
    "$actual_uid" "$mode" "$flags_decimal" "$rootless_value"
}

# DARWIN_USER_TEMP_DIR entries are OS-managed shells. They can carry rootless /
# nounlink metadata and therefore are not application-owned residue. Never
# delete them. Accept only the exact direct-child names WebKit owns for this
# UUID, and only while each object is an empty, current-user-owned directory.
# Require the exact protection shape observed on WebKit-created shells: mode
# 0700, the SF_NOUNLINK bit (0x00100000), and rootless=folders. This applies to
# every caller-supplied root; a synthetic ordinary directory must never be
# misclassified as an OS-managed shell merely because it is empty.
isolated_app_darwin_webkit_temp_shell_snapshot() {
  local bundle_id="${1:-}"
  local root="${2:-}"
  local role path expected_uid first_entry metadata remainder
  local actual_uid mode flags_decimal rootless_value count=0 roles=""
  isolated_app_assert_owned_id "$bundle_id" || return 2
  isolated_app_assert_canonical_directory "$root" "Darwin WebKit temp root" || return 2
  expected_uid="$(/usr/bin/id -u)" || return 2
  for role in GPU Networking WebContent; do
    path="$(isolated_app_darwin_webkit_path "$bundle_id" "$root" "$role")" || return 2
    if [[ -L "$path" ]]; then
      isolated_app_error "Darwin WebKit temp shell is a symlink: $path"
      return 1
    fi
    if [[ -e "$path" ]]; then
      [[ -d "$path" ]] || {
        isolated_app_error "Darwin WebKit temp shell is not a directory: $path"
        return 1
      }
      if ! metadata="$(
        isolated_app_darwin_webkit_temp_shell_metadata "$path"
      )"; then
        isolated_app_error \
          "Darwin WebKit temp shell metadata is unreadable or missing: $path"
        return 2
      fi
      actual_uid="${metadata%%|*}"
      remainder="${metadata#*|}"
      mode="${remainder%%|*}"
      remainder="${remainder#*|}"
      flags_decimal="${remainder%%|*}"
      rootless_value="${remainder#*|}"
      [[ "$actual_uid" == "$expected_uid" ]] || {
        isolated_app_error "Darwin WebKit temp shell has an unexpected owner: $path"
        return 1
      }
      if ! isolated_app_darwin_webkit_temp_metadata_is_protected \
        "$mode" "$flags_decimal" "$rootless_value"; then
        isolated_app_error \
          "Darwin WebKit temp shell lacks the expected OS protection metadata: $path"
        return 1
      fi
      first_entry="$(/usr/bin/find -P "$path" -mindepth 1 -maxdepth 1 \
        -print -quit 2>/dev/null)" || return 2
      [[ -z "$first_entry" ]] || {
        isolated_app_error "Darwin WebKit temp shell is not empty: $path"
        return 1
      }
      count=$((count + 1))
      if [[ -n "$roles" ]]; then roles="$roles,"; fi
      roles="$roles$role"
    fi
  done
  printf '%s|%s\n' "$count" "$roles"
}

isolated_app_darwin_webkit_temp_shells_are_valid() {
  isolated_app_darwin_webkit_temp_shell_snapshot \
    "${1:-}" "${2:-}" >/dev/null
}

isolated_app_darwin_webkit_temp_shell_count() {
  local snapshot
  snapshot="$(isolated_app_darwin_webkit_temp_shell_snapshot \
    "${1:-}" "${2:-}")" || return 1
  printf '%s\n' "${snapshot%%|*}"
}

isolated_app_darwin_webkit_temp_shell_roles() {
  local snapshot
  snapshot="$(isolated_app_darwin_webkit_temp_shell_snapshot \
    "${1:-}" "${2:-}")" || return 1
  printf '%s\n' "${snapshot#*|}"
}

isolated_app_report_retained_darwin_webkit_temp_shells() {
  local bundle_id="${1:-}"
  local root="${2:-}"
  local count="${3:-}"
  local roles="${4:-}"
  isolated_app_assert_owned_id "$bundle_id" || return 1
  isolated_app_assert_canonical_directory "$root" "Darwin WebKit temp root" || return 1
  [[ "$count" =~ ^[1-3]$ && -n "$roles" ]] || return 1
  # Cleanup authority is retired only after the facts above have already been
  # validated. This final notice is operator information, not another mutable
  # state transition: a closed/broken stderr must not turn completed cleanup
  # into an unretryable failure after its manifest has gone away.
  isolated_app_error \
    "retired all removable state for $bundle_id; retained $count empty OS-managed WebKit temp shell(s) ($roles) under $root" \
    || true
  return 0
}

isolated_app_http_storages_path() {
  local bundle_id="${1:-}"
  isolated_app_assert_owned_id "$bundle_id" || return 1
  printf '%s/Library/HTTPStorages/%s\n' "$HOME" "$bundle_id"
}

isolated_app_http_cookies_path() {
  local bundle_id="${1:-}"
  isolated_app_assert_owned_id "$bundle_id" || return 1
  printf '%s/Library/HTTPStorages/%s.binarycookies\n' "$HOME" "$bundle_id"
}

isolated_app_cookies_path() {
  local bundle_id="${1:-}"
  isolated_app_assert_owned_id "$bundle_id" || return 1
  printf '%s/Library/Cookies/%s.binarycookies\n' "$HOME" "$bundle_id"
}

isolated_app_container_path() {
  local bundle_id="${1:-}"
  isolated_app_assert_owned_id "$bundle_id" || return 1
  printf '%s/Library/Containers/%s\n' "$HOME" "$bundle_id"
}

isolated_app_application_scripts_path() {
  local bundle_id="${1:-}"
  isolated_app_assert_owned_id "$bundle_id" || return 1
  printf '%s/Library/Application Scripts/%s\n' "$HOME" "$bundle_id"
}

isolated_app_byhost_preferences_directory() {
  local bundle_id="${1:-}"
  isolated_app_assert_owned_id "$bundle_id" || return 1
  printf '%s/Library/Preferences/ByHost\n' "$HOME"
}

isolated_app_byhost_preferences_stem() {
  local bundle_id="${1:-}"
  isolated_app_assert_owned_id "$bundle_id" || return 1
  printf '%s.\n' "$bundle_id"
}

isolated_app_byhost_preferences_exist() {
  local bundle_id="${1:-}"
  local directory match
  isolated_app_assert_owned_id "$bundle_id" || return 2
  directory="$(isolated_app_byhost_preferences_directory "$bundle_id")" || return 2
  [[ -d "$directory" ]] || return 1
  match="$(/usr/bin/find "$directory" -mindepth 1 -maxdepth 1 \
    -name "$bundle_id.*.plist" -print -quit 2>/dev/null)" || return 2
  [[ -n "$match" ]]
}

isolated_app_remove_byhost_preferences() {
  local bundle_id="${1:-}"
  local directory path
  isolated_app_assert_owned_id "$bundle_id" || return 1
  directory="$(isolated_app_byhost_preferences_directory "$bundle_id")" || return 1
  [[ -d "$directory" ]] || return 0
  while IFS= read -r -d '' path; do
    isolated_app_remove_exact_path "$path" "isolated ByHost preference" || return 1
  done < <(/usr/bin/find "$directory" -mindepth 1 -maxdepth 1 \
    -name "$bundle_id.*.plist" -print0 2>/dev/null)
  if isolated_app_byhost_preferences_exist "$bundle_id"; then
    isolated_app_error "could not retire isolated ByHost preferences for $bundle_id"
    return 1
  else
    local status=$?
    [[ "$status" -eq 1 ]] || return 1
  fi
  return 0
}

isolated_app_remove_exact_path() {
  local path="${1:-}"
  local purpose="${2:-owned path}"
  isolated_app_assert_absolute_path "$path" "$purpose" || return 1
  if [[ -L "$path" || -f "$path" ]]; then
    /bin/rm -f -- "$path" || return 1
  elif [[ -d "$path" ]]; then
    # `ditto` preserves the read-only modes carried by immutable release
    # snapshots. Plain `rm -R` then fails, or prompts when the harness owns a
    # TTY. This exact directory is already bounded by the caller; walk it
    # physically and unlock only non-symlink entries before removing it.
    /usr/bin/find -P "$path" ! -type l -exec /bin/chmod u+w {} + || return 1
    /bin/rm -R -- "$path" || return 1
  elif [[ -e "$path" ]]; then
    /bin/rm -f -- "$path" || return 1
  fi
  if [[ -e "$path" || -L "$path" ]]; then
    isolated_app_error "could not remove $purpose: $path"
    return 1
  fi
  return 0
}

# Verify that an isolated owner capsule contains no direct child outside the
# exact paths named by its cleanup authority. This check deliberately runs
# before authority retirement: an unexpected child keeps the manifest intact
# so the operator can inspect the capsule and retry safely.
isolated_app_owner_contains_only_direct_paths() {
  local owner_root="${1:-}"
  shift || return 1
  isolated_app_assert_canonical_directory \
    "$owner_root" "isolated owner root" || return 1
  (
    local observed allowed is_allowed
    local children
    /bin/test -r "$owner_root" -a -x "$owner_root" || return 1
    shopt -s dotglob nullglob
    children=("$owner_root"/*)
    for observed in "${children[@]}"; do
      is_allowed=0
      for allowed in "$@"; do
        if [[ "$observed" == "$allowed" ]]; then
          is_allowed=1
          break
        fi
      done
      if [[ "$is_allowed" -ne 1 ]]; then
        isolated_app_error \
          "isolated owner capsule contains an unknown child: $observed"
        return 1
      fi
    done
    return 0
  )
}

isolated_app_sign_bundle() {
  local staged="${1:-}"
  local identity="${ISOLATED_APP_SIGNING_IDENTITY:-}"
  local identity_file="${ISOLATED_APP_SIGNING_IDENTITY_FILE:-$HOME/.keys/signing-identity.txt}"
  local preserve_metadata
  isolated_app_assert_bundle_path "$staged" || return 1
  preserve_metadata="entitlements,flags,runtime,launch-constraints,library-constraints"

  if [[ -z "$identity" && -f "$identity_file" ]]; then
    identity="$(/usr/bin/head -n 1 "$identity_file" | /usr/bin/sed -e 's/[[:space:]]*$//')"
    if [[ -n "$identity" ]] \
      && ! /usr/bin/security find-identity -v -p codesigning 2>/dev/null \
        | /usr/bin/grep -qF -- "$identity"; then
      identity=""
    fi
  fi
  [[ -n "$identity" ]] || identity="-"

  # The source signature is still embedded in the copied main executable even
  # after Info.plist changes invalidate the bundle seal. Preserve its runtime
  # profile while allowing codesign to derive the NEW identifier from the
  # rewritten plist. Deliberately omit --deep: nested code is unchanged and
  # must retain its own signature/entitlements rather than inheriting the app's.
  if ! /usr/bin/codesign --force --sign "$identity" \
    --preserve-metadata="$preserve_metadata" "$staged" >/dev/null 2>&1; then
    if [[ "$identity" == "-" ]]; then
      isolated_app_error "could not ad-hoc sign $staged"
      return 1
    fi
    isolated_app_error "signing with configured identity failed; retrying ad-hoc"
    if ! /usr/bin/codesign --force --sign - \
      --preserve-metadata="$preserve_metadata" "$staged" >/dev/null 2>&1; then
      isolated_app_error "could not sign $staged"
      return 1
    fi
    identity="-"
  fi

  if ! /usr/bin/codesign --verify --deep --strict "$staged" >/dev/null 2>&1; then
    isolated_app_error "staged bundle failed strict codesign verification: $staged"
    return 1
  fi
  if [[ "$identity" == "-" ]]; then
    ISOLATED_APP_SIGNING_MODE="ad-hoc"
  else
    ISOLATED_APP_SIGNING_MODE="Developer ID ($identity)"
  fi
  return 0
}

# isolated_app_stage_bundle <source.app> <staged.app> <executable-name>
#   <bundle-id> <bundle-name> <display-name> <support-dir> <keychain-service>
#   <repo-root> [allow-historical] [allow-dirty-runtime-inputs]
isolated_app_stage_bundle() {
  local source="${1:-}"
  local staged="${2:-}"
  local executable_name="${3:-}"
  local bundle_id="${4:-}"
  local bundle_name="${5:-}"
  local display_name="${6:-}"
  local support_dir="${7:-}"
  local keychain_service="${8:-}"
  local repo_root="${9:-}"
  local allow_historical="${10:-0}"
  local allow_dirty="${11:-0}"
  local contents plist source_executable source_binary partial_staged stage_status

  isolated_app_assert_owned_id "$bundle_id" || return 1
  isolated_app_assert_keychain_service "$bundle_id" "$keychain_service" || return 1
  isolated_app_assert_bundle_path "$source" || return 1
  isolated_app_assert_bundle_path "$staged" || return 1
  isolated_app_assert_support_path "$support_dir" || return 1
  isolated_app_assert_shared_owner_parent "$staged" "$support_dir" || return 1
  if [[ -z "$executable_name" || "$executable_name" == */* ]]; then
    isolated_app_error "invalid isolated executable name: ${executable_name:-<empty>}"
    return 1
  fi
  [[ -n "$bundle_name" && -n "$display_name" ]] || {
    isolated_app_error "bundle and display names must be non-empty"
    return 1
  }
  [[ -d "$source" ]] || {
    isolated_app_error "source bundle does not exist: $source"
    return 1
  }
  isolated_app_assert_source_provenance \
    "$repo_root" "$source" "$allow_historical" "$allow_dirty" >/dev/null || return 1
  if [[ -e "$staged" || -L "$staged" ]]; then
    isolated_app_error "staged bundle already exists; cleanup must be explicit: $staged"
    return 1
  fi

  partial_staged="${staged%.app}.partial.app"
  if [[ -e "$partial_staged" || -L "$partial_staged" ]]; then
    isolated_app_error "partial staged bundle already exists; manifested cleanup is required: $partial_staged"
    return 1
  fi
  if ! /usr/bin/ditto "$source" "$partial_staged"; then
    isolated_app_error "could not copy source bundle $source"
    isolated_app_remove_exact_path "$partial_staged" "partial staged bundle" >/dev/null 2>&1 \
      || true
    return 1
  fi

  # Authenticate the copied object before changing its identity. This closes a
  # source/copy race and proves ditto preserved the exact sealed provenance,
  # trusted TeamIdentifier and payload bytes that were checked above.
  if ! isolated_app_assert_source_provenance \
    "$repo_root" "$partial_staged" "$allow_historical" "$allow_dirty" >/dev/null; then
    isolated_app_error "partial copy no longer matches the authenticated source provenance"
    isolated_app_remove_exact_path "$partial_staged" "partial staged bundle" || return 1
    return 1
  fi

  contents="$partial_staged/Contents"
  plist="$contents/Info.plist"
  stage_status=1
  while :; do
    if [[ ! -f "$plist" ]]; then
      isolated_app_error "staged bundle has no Info.plist: $plist"
      break
    fi
    if ! source_executable="$(isolated_app_plist_value "$plist" CFBundleExecutable)"; then
      isolated_app_error "source bundle declares no CFBundleExecutable: $source"
      break
    fi
    source_binary="$contents/MacOS/$source_executable"
    if [[ ! -f "$source_binary" ]]; then
      isolated_app_error "source executable is missing: $source_binary"
      break
    fi
    if [[ "$source_executable" != "$executable_name" ]] \
      && ! /bin/mv "$source_binary" "$contents/MacOS/$executable_name"; then
      isolated_app_error "could not rename executable to $executable_name"
      break
    fi

    isolated_app_plist_set_string "$plist" CFBundleExecutable "$executable_name" || break
    isolated_app_plist_set_string "$plist" CFBundleIdentifier "$bundle_id" || break
    isolated_app_plist_set_string "$plist" CFBundleName "$bundle_name" || break
    isolated_app_plist_set_string "$plist" CFBundleDisplayName "$display_name" || break
    /usr/bin/plutil -remove LSEnvironment -- "$plist" >/dev/null 2>&1 || true
    /usr/bin/plutil -insert LSEnvironment -dictionary -- "$plist" >/dev/null 2>&1 || break
    /usr/bin/plutil -insert LSEnvironment.PENSIEVE_SUPPORT_DIR -string "$support_dir" \
      -- "$plist" >/dev/null 2>&1 || break
    /usr/bin/plutil -insert LSEnvironment.PENSIEVE_KEYCHAIN_SERVICE \
      -string "$keychain_service" -- "$plist" >/dev/null 2>&1 || break

    # Keep the copied signature in place until re-signing so codesign can
    # preserve entitlements and hardened-runtime metadata from it.
    isolated_app_sign_bundle "$partial_staged" || break
    isolated_app_verify_embedded_provenance "$partial_staged" staged || break
    stage_status=0
    break
  done

  if [[ "$stage_status" -ne 0 ]]; then
    isolated_app_remove_exact_path "$partial_staged" "partial staged bundle" || return 1
    return 1
  fi
  if ! /bin/mv "$partial_staged" "$staged"; then
    isolated_app_error "could not publish the fully rewritten staged bundle: $staged"
    isolated_app_remove_exact_path "$partial_staged" "partial staged bundle" || true
    return 1
  fi
  return 0
}

isolated_app_defaults_domain_is_empty() {
  local bundle_id="${1:-}"
  local exported json compact command_status
  isolated_app_assert_owned_id "$bundle_id" || return 1
  if exported="$(/usr/bin/defaults export "$bundle_id" - 2>&1)"; then
    :
  else
    command_status=$?
    isolated_app_error "defaults export failed for $bundle_id status=$command_status"
    return 1
  fi
  if json="$(printf '%s' "$exported" \
    | /usr/bin/plutil -convert json -o - -- - 2>/dev/null)"; then
    :
  else
    isolated_app_error "defaults export returned an unreadable plist for $bundle_id"
    return 1
  fi
  compact="$(printf '%s' "$json" | /usr/bin/tr -d '[:space:]')" || return 1
  [[ "$compact" == "{}" ]]
}

isolated_app_reset_defaults_domain() {
  local bundle_id="${1:-}"
  local preferences_path attempt=0 quiet_checks=0
  local required_quiet_checks=30
  local maximum_checks=100
  isolated_app_assert_owned_id "$bundle_id" || return 1
  preferences_path="$(isolated_app_preferences_path "$bundle_id")" || return 1
  # cfprefsd can publish a delayed write after an apparently successful
  # delete/read-back. Keep retiring this exact UUID-owned domain until BOTH the
  # logical domain and its plist have remained absent/empty for three seconds.
  # A bounded quiet period is cleanup evidence; cross-scenario safety comes
  # from minting a different UUID for every independent scenario.
  while [[ "$attempt" -lt "$maximum_checks" ]]; do
    /usr/bin/defaults delete "$bundle_id" >/dev/null 2>&1 || true
    isolated_app_remove_exact_path "$preferences_path" "isolated preferences" || return 1
    /bin/sleep 0.1
    if isolated_app_defaults_domain_is_empty "$bundle_id" \
      && [[ ! -e "$preferences_path" && ! -L "$preferences_path" ]]; then
      quiet_checks=$((quiet_checks + 1))
      if [[ "$quiet_checks" -ge "$required_quiet_checks" ]]; then
        return 0
      fi
    else
      quiet_checks=0
    fi
    attempt=$((attempt + 1))
  done
  isolated_app_error \
    "defaults domain did not remain retired for $bundle_id"
  return 1
}

isolated_app_keychain_item_exists() {
  local service="${1:-}"
  local account="${2:-$ISOLATED_APP_KEYCHAIN_ACCOUNT}"
  local status
  if /usr/bin/security find-generic-password -s "$service" -a "$account" >/dev/null 2>&1; then
    return 0
  else
    status=$?
  fi
  if [[ "$status" -eq 44 ]]; then
    return 1
  fi
  isolated_app_error \
    "Keychain query failed service=$service account=$account status=$status"
  return 2
}

isolated_app_reset_keychain_item() {
  local bundle_id="${1:-}"
  local service="${2:-}"
  local account="${3:-$ISOLATED_APP_KEYCHAIN_ACCOUNT}"
  local query_status
  isolated_app_assert_keychain_service "$bundle_id" "$service" || return 1
  if isolated_app_keychain_item_exists "$service" "$account"; then
    /usr/bin/security delete-generic-password -s "$service" -a "$account" >/dev/null 2>&1 \
      || true
  else
    query_status=$?
    [[ "$query_status" -eq 1 ]] || return 1
  fi
  if isolated_app_keychain_item_exists "$service" "$account"; then
    isolated_app_error "could not retire isolated Keychain item service=$service account=$account"
    return 1
  else
    query_status=$?
    [[ "$query_status" -eq 1 ]] || return 1
  fi
  return 0
}

isolated_app_known_profile_namespace_is_empty() {
  local bundle_id="${1:-}"
  local support_dir="${2:-}"
  local keychain_service="${3:-}"
  local account="${4:-$ISOLATED_APP_KEYCHAIN_ACCOUNT}"
  local allow_empty_support="${5:-0}"
  local darwin_cache_root="${6:-}"
  local preferences recent saved container application_scripts cache webkit
  local http_storages http_cookies cookies path status

  isolated_app_assert_owned_id "$bundle_id" || return 2
  isolated_app_assert_support_path "$support_dir" || return 2
  isolated_app_assert_keychain_service "$bundle_id" "$keychain_service" || return 2
  [[ "$allow_empty_support" == "0" || "$allow_empty_support" == "1" ]] || return 2
  [[ -n "$darwin_cache_root" ]] \
    || darwin_cache_root="$(isolated_app_darwin_user_directory cache)" || return 2
  isolated_app_assert_canonical_directory \
    "$darwin_cache_root" "Darwin WebKit cache root" || return 2

  isolated_app_defaults_domain_is_empty "$bundle_id" || return 1
  if isolated_app_keychain_item_exists "$keychain_service" "$account"; then
    return 1
  else
    status=$?
    [[ "$status" -eq 1 ]] || return 2
  fi

  preferences="$(isolated_app_preferences_path "$bundle_id")" || return 2
  recent="$(isolated_app_recent_documents_path "$bundle_id")" || return 2
  saved="$(isolated_app_saved_state_path "$bundle_id")" || return 2
  container="$(isolated_app_container_path "$bundle_id")" || return 2
  application_scripts="$(isolated_app_application_scripts_path "$bundle_id")" || return 2
  cache="$(isolated_app_cache_path "$bundle_id")" || return 2
  webkit="$(isolated_app_webkit_path "$bundle_id")" || return 2
  http_storages="$(isolated_app_http_storages_path "$bundle_id")" || return 2
  http_cookies="$(isolated_app_http_cookies_path "$bundle_id")" || return 2
  cookies="$(isolated_app_cookies_path "$bundle_id")" || return 2
  for path in \
    "$preferences" "$recent" "$saved" "$container" "$application_scripts" \
    "$cache" "$webkit" "$http_storages" "$http_cookies" "$cookies"
  do
    [[ ! -e "$path" && ! -L "$path" ]] || return 1
  done
  isolated_app_darwin_webkit_cache_is_empty \
    "$bundle_id" "$darwin_cache_root" || return $?
  if [[ "$allow_empty_support" == "1" && -d "$support_dir" && ! -L "$support_dir" ]]; then
    [[ -z "$(/usr/bin/find "$support_dir" -mindepth 1 -print -quit 2>/dev/null)" ]] \
      || return 1
  else
    [[ ! -e "$support_dir" && ! -L "$support_dir" ]] || return 1
  fi
  if isolated_app_byhost_preferences_exist "$bundle_id"; then
    return 1
  else
    status=$?
    [[ "$status" -eq 1 ]] || return 2
  fi
  return 0
}

isolated_app_remove_known_profile_state_once() {
  local bundle_id="${1:-}"
  local support_dir="${2:-}"
  local keychain_service="${3:-}"
  local account="${4:-$ISOLATED_APP_KEYCHAIN_ACCOUNT}"
  local darwin_cache_root="${5:-}"
  local darwin_temp_root="${6:-}"
  local preferences recent saved container application_scripts cache webkit
  local http_storages http_cookies cookies path role cleanup_status=0

  isolated_app_assert_owned_id "$bundle_id" || return 1
  isolated_app_assert_support_path "$support_dir" || return 1
  isolated_app_assert_keychain_service "$bundle_id" "$keychain_service" || return 1
  [[ -n "$darwin_cache_root" ]] \
    || darwin_cache_root="$(isolated_app_darwin_user_directory cache)" || return 1
  [[ -n "$darwin_temp_root" ]] \
    || darwin_temp_root="$(isolated_app_darwin_user_directory temp)" || return 1
  isolated_app_assert_canonical_directory \
    "$darwin_cache_root" "Darwin WebKit cache root" || return 1
  isolated_app_assert_canonical_directory \
    "$darwin_temp_root" "Darwin WebKit temp root" || return 1
  isolated_app_darwin_webkit_temp_shells_are_valid \
    "$bundle_id" "$darwin_temp_root" || return 1

  /usr/bin/defaults delete "$bundle_id" >/dev/null 2>&1 || true
  if ! isolated_app_reset_keychain_item \
    "$bundle_id" "$keychain_service" "$account"; then cleanup_status=1; fi
  if ! isolated_app_remove_byhost_preferences "$bundle_id"; then cleanup_status=1; fi

  preferences="$(isolated_app_preferences_path "$bundle_id")" || return 1
  recent="$(isolated_app_recent_documents_path "$bundle_id")" || return 1
  saved="$(isolated_app_saved_state_path "$bundle_id")" || return 1
  container="$(isolated_app_container_path "$bundle_id")" || return 1
  application_scripts="$(isolated_app_application_scripts_path "$bundle_id")" || return 1
  cache="$(isolated_app_cache_path "$bundle_id")" || return 1
  webkit="$(isolated_app_webkit_path "$bundle_id")" || return 1
  http_storages="$(isolated_app_http_storages_path "$bundle_id")" || return 1
  http_cookies="$(isolated_app_http_cookies_path "$bundle_id")" || return 1
  cookies="$(isolated_app_cookies_path "$bundle_id")" || return 1
  for path in \
    "$preferences" "$recent" "$saved" "$container" "$application_scripts" \
    "$cache" "$webkit" "$http_storages" "$http_cookies" "$cookies" "$support_dir"
  do
    if ! isolated_app_remove_exact_path "$path" "isolated profile state"; then
      cleanup_status=1
    fi
  done
  for role in GPU Networking WebContent; do
    path="$(isolated_app_darwin_webkit_path \
      "$bundle_id" "$darwin_cache_root" "$role")" || return 1
    if ! isolated_app_remove_exact_path "$path" "isolated Darwin WebKit cache"; then
      cleanup_status=1
    fi
  done
  return "$cleanup_status"
}

# A process-exit barrier is necessary but not sufficient: cfprefsd,
# sharedfilelistd and framework helpers can publish queued UUID-owned state just
# after the process disappears. Repeatedly retire the bounded, explicit
# namespace and require three continuous seconds with no known state. This is a
# census of exact run-owned names, never a broad Library cleanup.
isolated_app_retire_known_profile_namespace() {
  local bundle_id="${1:-}"
  local support_dir="${2:-}"
  local keychain_service="${3:-}"
  local account="${4:-$ISOLATED_APP_KEYCHAIN_ACCOUNT}"
  local darwin_cache_root="${5:-}"
  local darwin_temp_root="${6:-}"
  local attempt=0 quiet_checks=0 status
  local required_quiet_checks=30
  local maximum_checks=100

  [[ -n "$darwin_cache_root" ]] \
    || darwin_cache_root="$(isolated_app_darwin_user_directory cache)" || return 1
  [[ -n "$darwin_temp_root" ]] \
    || darwin_temp_root="$(isolated_app_darwin_user_directory temp)" || return 1

  while [[ "$attempt" -lt "$maximum_checks" ]]; do
    isolated_app_remove_known_profile_state_once \
      "$bundle_id" "$support_dir" "$keychain_service" "$account" \
      "$darwin_cache_root" "$darwin_temp_root" || return 1
    /bin/sleep 0.1
    if isolated_app_known_profile_namespace_is_empty \
      "$bundle_id" "$support_dir" "$keychain_service" "$account" 0 \
      "$darwin_cache_root" \
      && isolated_app_darwin_webkit_temp_shells_are_valid \
        "$bundle_id" "$darwin_temp_root"; then
      quiet_checks=$((quiet_checks + 1))
      if [[ "$quiet_checks" -ge "$required_quiet_checks" ]]; then
        return 0
      fi
    else
      status=$?
      [[ "$status" -eq 1 ]] || return 1
      quiet_checks=0
    fi
    attempt=$((attempt + 1))
  done

  isolated_app_error "known profile namespace did not remain empty for $bundle_id"
  return 1
}

isolated_app_identity_is_running() {
  local bundle_id="${1:-}"
  local status
  isolated_app_assert_owned_id "$bundle_id" || return 2
  if EXPECTED_ISOLATED_BUNDLE_ID="$bundle_id" /usr/bin/swift - <<'EOF' >/dev/null
import AppKit
import Foundation

let identifier = ProcessInfo.processInfo.environment["EXPECTED_ISOLATED_BUNDLE_ID"] ?? ""
let applications = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
exit(applications.isEmpty ? 3 : 0)
EOF
  then
    return 0
  else
    status=$?
  fi
  [[ "$status" -eq 3 ]] && return 1
  return 2
}

isolated_app_assert_not_running() {
  local bundle_id="${1:-}"
  isolated_app_assert_owned_id "$bundle_id" || return 1
  EXPECTED_ISOLATED_BUNDLE_ID="$bundle_id" /usr/bin/swift - <<'EOF'
import AppKit
import Foundation

let identifier = ProcessInfo.processInfo.environment["EXPECTED_ISOLATED_BUNDLE_ID"] ?? ""
let applications = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
guard applications.isEmpty else {
  let details = applications.map { app in
    "pid=\(app.processIdentifier) bundle=\(app.bundleURL?.path ?? "?") executable=\(app.executableURL?.path ?? "?")"
  }.joined(separator: "; ")
  fputs("isolated identity is still running: \(details)\n", stderr)
  exit(1)
}
EOF
}

isolated_app_control_helper_path() {
  local lib_dir repo_root source cache_root toolchain_fingerprint cache_key
  local helper partial
  lib_dir="$(cd "$(/usr/bin/dirname "${BASH_SOURCE[0]}")" && pwd)" || return 1
  repo_root="$(cd "$lib_dir/../.." && pwd)" || return 1
  source="$lib_dir/isolated-app-control.swift"
  cache_root="$repo_root/Pensieve/.build/pensieve-runtime-tools"
  [[ -f "$source" ]] || {
    isolated_app_error "tracked process-control helper is missing: $source"
    return 1
  }
  toolchain_fingerprint="$(
    /usr/bin/shasum -a 256 "$source"
    /usr/bin/xcrun --sdk macosx swiftc --version
    /usr/bin/xcrun --sdk macosx --show-sdk-path
  )" || return 1
  cache_key="$(printf '%s' "$toolchain_fingerprint" | /usr/bin/shasum -a 256 \
    | /usr/bin/awk '{ print $1 }')" || return 1
  [[ "$cache_key" =~ ^[0-9a-f]{64}$ ]] || return 1
  helper="$cache_root/isolated-app-control-$cache_key"
  if [[ ! -x "$helper" ]]; then
    /bin/mkdir -p "$cache_root" || return 1
    partial="$helper.partial.$$"
    if ! /usr/bin/xcrun --sdk macosx swiftc -O "$source" -o "$partial"; then
      /bin/rm -f -- "$partial"
      isolated_app_error "could not compile exact-identity process-control helper"
      return 1
    fi
    /bin/chmod 700 "$partial" || {
      /bin/rm -f -- "$partial"
      return 1
    }
    /bin/mv -f "$partial" "$helper" || {
      /bin/rm -f -- "$partial"
      return 1
    }
  fi
  printf '%s\n' "$helper"
}

# isolated_app_control_identity <status|graceful|force|terminate> <bundle-id>
#   <bundle-path> <executable-path> <expected-pid> <timeout-seconds>
#
# Identity authentication and process control happen inside one Swift process
# on one retained NSRunningApplication object. Never split this back into a
# shell-side PID check followed by kill(2): Darwin can reuse the PID in that
# gap. Exit statuses are owned by the Swift helper: 3 absent, 4 identity
# mismatch/ambiguity, 5 rejected action or timeout.
isolated_app_control_identity() {
  local action="${1:-}"
  local bundle_id="${2:-}"
  local bundle_path="${3:-}"
  local executable_path="${4:-}"
  local expected_pid="${5:-}"
  local timeout_seconds="${6:-}"
  local helper
  case "$action" in status | graceful | force | terminate) ;; *) return 2 ;; esac
  isolated_app_assert_owned_id "$bundle_id" || return 4
  isolated_app_assert_bundle_path "$bundle_path" || return 4
  isolated_app_assert_absolute_path "$executable_path" "executable path" || return 4
  [[ "$expected_pid" =~ ^[1-9][0-9]*$ ]] || return 2
  [[ "$timeout_seconds" =~ ^[0-9]+([.][0-9]+)?$ ]] || return 2
  helper="$(isolated_app_control_helper_path)" || return 5
  "$helper" "$action" "$bundle_id" "$bundle_path" "$executable_path" \
    "$expected_pid" "$timeout_seconds"
}

isolated_app_launchservices_registration_exists() {
  local bundle_id="${1:-}"
  local registry_dump
  local lsregister_path
  lsregister_path="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

  isolated_app_assert_owned_id "$bundle_id" || return 2
  if [[ ! -x "$lsregister_path" ]]; then
    isolated_app_error "LaunchServices registry tool is unavailable: $lsregister_path"
    return 2
  fi
  if ! registry_dump="$("$lsregister_path" -dump 2>/dev/null)"; then
    isolated_app_error "could not read LaunchServices registry state"
    return 2
  fi
  if printf '%s\n' "$registry_dump" | /usr/bin/awk -v expected="$bundle_id" '
    $1 == "identifier:" && $2 == expected { found = 1 }
    END { exit(found ? 0 : 1) }
  '
  then
    return 0
  fi
  return 1
}

# Unregister only the exact staged bundle and judge success by the registry's
# final state. On current macOS, `lsregister -u` can return -10814/exit 1 when
# Spotlight cannot scan a bundle which is already absent from the registry.
# Treating that raw exit code as failure leaves a false-positive residue; the
# exact UUID registry query below distinguishes "already gone" from a real
# unregister failure.
isolated_app_unregister_launchservices_identity() {
  local bundle_id="${1:-}"
  local bundle_path="${2:-}"
  local registration_status attempt=0 quiet_checks=0
  local required_quiet_checks=30
  local maximum_checks=100
  local lsregister_path
  lsregister_path="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

  isolated_app_assert_owned_id "$bundle_id" || return 1
  isolated_app_assert_bundle_path "$bundle_path" || return 1
  [[ -d "$bundle_path" ]] || {
    isolated_app_error "cannot unregister a missing staged bundle: $bundle_path"
    return 1
  }
  if [[ ! -x "$lsregister_path" ]]; then
    isolated_app_error "LaunchServices registry tool is unavailable: $lsregister_path"
    return 1
  fi

  # LaunchServices can publish queued registration work after one successful
  # unregister. Keep the exact staged bundle as the unregister handle until the
  # UUID has remained absent for three continuous seconds.
  while [[ "$attempt" -lt "$maximum_checks" ]]; do
    if isolated_app_launchservices_registration_exists "$bundle_id"; then
      "$lsregister_path" -u "$bundle_path" >/dev/null 2>&1 || true
      quiet_checks=0
    else
      registration_status=$?
      [[ "$registration_status" -eq 1 ]] || return 1
      quiet_checks=$((quiet_checks + 1))
      if [[ "$quiet_checks" -ge "$required_quiet_checks" ]]; then
        return 0
      fi
    fi
    /bin/sleep 0.1
    attempt=$((attempt + 1))
  done

  isolated_app_error \
    "LaunchServices registration did not remain retired for $bundle_id"
  return 1
}

# Prints the single matching process id on success.
isolated_app_verify_running_identity() {
  local bundle_id="${1:-}"
  local bundle_path="${2:-}"
  local executable_path="${3:-}"
  isolated_app_assert_owned_id "$bundle_id" || return 1
  isolated_app_assert_bundle_path "$bundle_path" || return 1
  isolated_app_assert_absolute_path "$executable_path" "executable path" || return 1
  EXPECTED_ISOLATED_BUNDLE_ID="$bundle_id" \
    EXPECTED_ISOLATED_BUNDLE_PATH="$bundle_path" \
    EXPECTED_ISOLATED_EXECUTABLE="$executable_path" \
    /usr/bin/swift - <<'EOF'
import AppKit
import Foundation

let environment = ProcessInfo.processInfo.environment
guard
  let identifier = environment["EXPECTED_ISOLATED_BUNDLE_ID"],
  let expectedBundlePath = environment["EXPECTED_ISOLATED_BUNDLE_PATH"],
  let expectedExecutable = environment["EXPECTED_ISOLATED_EXECUTABLE"]
else {
  fputs("missing expected isolated identity environment\n", stderr)
  exit(2)
}

let applications = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
guard applications.count == 1, let application = applications.first else {
  fputs("expected exactly one process for \(identifier), got \(applications.count)\n", stderr)
  exit(1)
}

func canonical(_ path: String) -> String {
  URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
}

guard let bundleURL = application.bundleURL,
      canonical(bundleURL.path) == canonical(expectedBundlePath)
else {
  fputs("running bundle path does not match staged isolated bundle\n", stderr)
  exit(1)
}
guard let executableURL = application.executableURL,
      canonical(executableURL.path) == canonical(expectedExecutable)
else {
  fputs("running executable path does not match staged isolated executable\n", stderr)
  exit(1)
}
print(application.processIdentifier)
EOF
}

isolated_app_wait_for_running_identity() {
  local bundle_id="${1:-}"
  local bundle_path="${2:-}"
  local executable_path="${3:-}"
  local attempts="${4:-120}"
  local attempt=0 pid
  while [[ "$attempt" -lt "$attempts" ]]; do
    if pid="$(isolated_app_verify_running_identity \
      "$bundle_id" "$bundle_path" "$executable_path" 2>/dev/null)"; then
      printf '%s\n' "$pid"
      return 0
    fi
    /bin/sleep 0.1
    attempt=$((attempt + 1))
  done
  isolated_app_verify_running_identity "$bundle_id" "$bundle_path" "$executable_path"
}

# isolated_app_assert_profile_fresh <bundle-id> <support-dir>
#   <keychain-service> [keychain-account]
isolated_app_assert_profile_fresh() {
  local bundle_id="${1:-}"
  local support_dir="${2:-}"
  local keychain_service="${3:-}"
  local account="${4:-$ISOLATED_APP_KEYCHAIN_ACCOUNT}"
  local namespace_status query_status
  isolated_app_assert_owned_id "$bundle_id" || return 1
  isolated_app_assert_support_path "$support_dir" || return 1
  isolated_app_assert_keychain_service "$bundle_id" "$keychain_service" || return 1
  isolated_app_assert_not_running "$bundle_id" || return 1
  if isolated_app_known_profile_namespace_is_empty \
    "$bundle_id" "$support_dir" "$keychain_service" "$account" 1; then
    if ! isolated_app_darwin_webkit_temp_shells_are_valid \
      "$bundle_id" "$(isolated_app_darwin_user_directory temp)"; then
      isolated_app_error \
        "fresh profile has an unexpected Darwin WebKit temp-shell shape: $bundle_id"
      return 1
    fi
  else
    namespace_status=$?
    isolated_app_error \
      "fresh profile has residual or unreadable UUID-owned state: $bundle_id (status=$namespace_status)"
    return 1
  fi
  if isolated_app_launchservices_registration_exists "$bundle_id"; then
    isolated_app_error \
      "fresh profile already has a LaunchServices registration: $bundle_id"
    return 1
  else
    query_status=$?
    [[ "$query_status" -eq 1 ]] || return 1
  fi
  return 0
}

# isolated_app_cleanup_identity <bundle-id> <bundle-path> <support-dir>
#   <keychain-service> <expected-owner-root> [keychain-account]
#   [darwin-cache-root] [darwin-temp-root]
isolated_app_cleanup_identity() {
  local bundle_id="${1:-}"
  local bundle_path="${2:-}"
  local support_dir="${3:-}"
  local keychain_service="${4:-}"
  local expected_owner_root="${5:-}"
  local account="${6:-$ISOLATED_APP_KEYCHAIN_ACCOUNT}"
  local darwin_cache_root="${7:-}"
  local darwin_temp_root="${8:-}"
  local bundle_parent support_parent partial_bundle_path
  local cleanup_status=0
  local registration_status

  isolated_app_assert_owned_id "$bundle_id" || return 1
  isolated_app_assert_bundle_path "$bundle_path" || return 1
  isolated_app_assert_support_path "$support_dir" || return 1
  isolated_app_assert_shared_owner_parent "$bundle_path" "$support_dir" || return 1
  isolated_app_assert_canonical_directory \
    "$expected_owner_root" "expected owner root" || return 1
  isolated_app_assert_direct_owned_path \
    "$expected_owner_root" "$bundle_path" "isolated application bundle" || return 1
  isolated_app_assert_direct_owned_path \
    "$expected_owner_root" "$support_dir" "isolated Application Support" || return 1
  bundle_parent="$(/usr/bin/dirname "$bundle_path")" || return 1
  support_parent="$(/usr/bin/dirname "$support_dir")" || return 1
  if [[ "$bundle_parent" != "$expected_owner_root" \
    || "$support_parent" != "$expected_owner_root" ]]; then
    isolated_app_error \
      "cleanup paths are not direct children of the expected owner root: $expected_owner_root"
    return 1
  fi
  isolated_app_assert_keychain_service "$bundle_id" "$keychain_service" || return 1
  [[ -n "$darwin_cache_root" ]] \
    || darwin_cache_root="$(isolated_app_darwin_user_directory cache)" || return 1
  [[ -n "$darwin_temp_root" ]] \
    || darwin_temp_root="$(isolated_app_darwin_user_directory temp)" || return 1
  isolated_app_assert_canonical_directory \
    "$darwin_cache_root" "Darwin WebKit cache root" || return 1
  isolated_app_assert_canonical_directory \
    "$darwin_temp_root" "Darwin WebKit temp root" || return 1
  isolated_app_assert_not_running "$bundle_id" || return 1
  partial_bundle_path="${bundle_path%.app}.partial.app"
  if ! isolated_app_remove_exact_path "$partial_bundle_path" "partial staged bundle"; then
    return 1
  fi

  if [[ -d "$bundle_path" ]]; then
    local actual_bundle_id
    actual_bundle_id="$(isolated_app_plist_value "$bundle_path/Contents/Info.plist" CFBundleIdentifier)" \
      || actual_bundle_id=""
    if [[ "$actual_bundle_id" != "$bundle_id" ]]; then
      isolated_app_error \
        "refusing to remove bundle whose identity differs from the cleanup identity: $bundle_path"
      return 1
    fi
    if ! isolated_app_unregister_launchservices_identity "$bundle_id" "$bundle_path"; then
      # The staged bundle is the exact handle for retrying a real unregister
      # failure. Keep it and the manifest rather than hiding registry residue.
      return 1
    fi
  fi

  if ! isolated_app_reset_defaults_domain "$bundle_id"; then cleanup_status=1; fi
  if ! isolated_app_retire_recent_documents "$bundle_id"; then cleanup_status=1; fi
  if ! isolated_app_remove_exact_path "$bundle_path" "isolated application bundle"; then
    cleanup_status=1
  fi
  if ! isolated_app_retire_known_profile_namespace \
    "$bundle_id" "$support_dir" "$keychain_service" "$account" \
    "$darwin_cache_root" "$darwin_temp_root"; then
    cleanup_status=1
  fi
  if isolated_app_launchservices_registration_exists "$bundle_id"; then
    isolated_app_error \
      "LaunchServices re-registered isolated identity after bundle cleanup: $bundle_id"
    cleanup_status=1
  else
    registration_status=$?
    if [[ "$registration_status" -ne 1 ]]; then cleanup_status=1; fi
  fi
  return "$cleanup_status"
}

isolated_app_plist_insert_string() {
  local plist="${1:-}"
  local key="${2:-}"
  local value="${3:-}"
  /usr/bin/plutil -insert "$key" -string "$value" -- "$plist" >/dev/null 2>&1
}

isolated_app_manifest_partial_path() {
  local manifest="${1:-}"
  local phase="${2:-}"
  case "$phase" in
    reservation | final) ;;
    *) return 1 ;;
  esac
  printf '%s.%s.partial\n' "$manifest" "$phase"
}

isolated_app_insert_manifest_coordinates() {
  local plist="${1:-}"
  local owner_root="${2:-}"
  local source_bundle="${3:-}"
  local source_commit="${4:-}"
  local bundle_path="${5:-}"
  local executable_name="${6:-}"
  local bundle_id="${7:-}"
  local display_name="${8:-}"
  local support_dir="${9:-}"
  local keychain_service="${10:-}"
  local nonce="${11:-}"
  local executable_path partial_bundle_path
  local preferences recent saved sandbox_saved cache webkit http_storages http_cookies cookies
  local container application_scripts byhost_directory byhost_stem
  local darwin_cache_root darwin_temp_root role darwin_path manifest_role

  [[ -f "$plist" && ! -L "$plist" ]] || return 1
  executable_path="$bundle_path/Contents/MacOS/$executable_name"
  partial_bundle_path="${bundle_path%.app}.partial.app"
  preferences="$(isolated_app_preferences_path "$bundle_id")" || return 1
  recent="$(isolated_app_recent_documents_path "$bundle_id")" || return 1
  saved="$(isolated_app_saved_state_path "$bundle_id")" || return 1
  sandbox_saved="$(isolated_app_sandbox_saved_state_path "$bundle_id")" || return 1
  cache="$(isolated_app_cache_path "$bundle_id")" || return 1
  webkit="$(isolated_app_webkit_path "$bundle_id")" || return 1
  http_storages="$(isolated_app_http_storages_path "$bundle_id")" || return 1
  http_cookies="$(isolated_app_http_cookies_path "$bundle_id")" || return 1
  cookies="$(isolated_app_cookies_path "$bundle_id")" || return 1
  container="$(isolated_app_container_path "$bundle_id")" || return 1
  application_scripts="$(isolated_app_application_scripts_path "$bundle_id")" || return 1
  byhost_directory="$(isolated_app_byhost_preferences_directory "$bundle_id")" || return 1
  byhost_stem="$(isolated_app_byhost_preferences_stem "$bundle_id")" || return 1
  darwin_cache_root="$(isolated_app_darwin_user_directory cache)" || return 1
  darwin_temp_root="$(isolated_app_darwin_user_directory temp)" || return 1

  isolated_app_plist_insert_string "$plist" reservationNonce "$nonce" || return 1
  isolated_app_plist_insert_string "$plist" ownerRoot "$owner_root" || return 1
  isolated_app_plist_insert_string "$plist" sourceBundlePath "$source_bundle" || return 1
  isolated_app_plist_insert_string "$plist" sourceCommit "$source_commit" || return 1
  isolated_app_plist_insert_string "$plist" bundlePath "$bundle_path" || return 1
  isolated_app_plist_insert_string "$plist" partialBundlePath "$partial_bundle_path" || return 1
  isolated_app_plist_insert_string "$plist" executableName "$executable_name" || return 1
  isolated_app_plist_insert_string "$plist" executablePath "$executable_path" || return 1
  isolated_app_plist_insert_string "$plist" bundleID "$bundle_id" || return 1
  isolated_app_plist_insert_string "$plist" bundleName "$executable_name" || return 1
  isolated_app_plist_insert_string "$plist" displayName "$display_name" || return 1
  isolated_app_plist_insert_string "$plist" supportPath "$support_dir" || return 1
  isolated_app_plist_insert_string "$plist" keychainService "$keychain_service" || return 1
  isolated_app_plist_insert_string "$plist" keychainAccount "$ISOLATED_APP_KEYCHAIN_ACCOUNT" \
    || return 1
  isolated_app_plist_insert_string "$plist" preferencesPath "$preferences" || return 1
  isolated_app_plist_insert_string "$plist" recentDocumentsPath "$recent" || return 1
  isolated_app_plist_insert_string "$plist" savedStatePath "$saved" || return 1
  isolated_app_plist_insert_string "$plist" sandboxSavedStatePath "$sandbox_saved" || return 1
  isolated_app_plist_insert_string "$plist" cachePath "$cache" || return 1
  isolated_app_plist_insert_string "$plist" webKitPath "$webkit" || return 1
  isolated_app_plist_insert_string "$plist" httpStoragesPath "$http_storages" || return 1
  isolated_app_plist_insert_string "$plist" httpCookiesPath "$http_cookies" || return 1
  isolated_app_plist_insert_string "$plist" cookiesPath "$cookies" || return 1
  isolated_app_plist_insert_string "$plist" containerPath "$container" || return 1
  isolated_app_plist_insert_string "$plist" applicationScriptsPath "$application_scripts" \
    || return 1
  isolated_app_plist_insert_string "$plist" byHostPreferencesDirectory "$byhost_directory" \
    || return 1
  isolated_app_plist_insert_string "$plist" byHostPreferencesStem "$byhost_stem" || return 1
  isolated_app_plist_insert_string \
    "$plist" darwinUserCacheDirectory "$darwin_cache_root" || return 1
  isolated_app_plist_insert_string \
    "$plist" darwinUserTempDirectory "$darwin_temp_root" || return 1
  for role in GPU Networking WebContent; do
    manifest_role="$role"
    darwin_path="$(isolated_app_darwin_webkit_path \
      "$bundle_id" "$darwin_cache_root" "$role")" || return 1
    isolated_app_plist_insert_string \
      "$plist" "darwinWebKitCache${manifest_role}Path" "$darwin_path" || return 1
    darwin_path="$(isolated_app_darwin_webkit_path \
      "$bundle_id" "$darwin_temp_root" "$role")" || return 1
    isolated_app_plist_insert_string \
      "$plist" "darwinWebKitTemp${manifest_role}Path" "$darwin_path" || return 1
  done
}

isolated_app_assert_manifest_request() {
  local manifest="${1:-}"
  local owner_root="${2:-}"
  local source_bundle="${3:-}"
  local bundle_path="${4:-}"
  local executable_name="${5:-}"
  local bundle_id="${6:-}"
  local display_name="${7:-}"
  local support_dir="${8:-}"
  local keychain_service="${9:-}"
  local source_commit="${10:-}"

  isolated_app_assert_canonical_directory "$owner_root" "owner root" || return 1
  isolated_app_assert_bundle_path "$source_bundle" || return 1
  isolated_app_assert_bundle_path "$bundle_path" || return 1
  isolated_app_assert_support_path "$support_dir" || return 1
  isolated_app_assert_shared_owner_parent "$bundle_path" "$support_dir" || return 1
  isolated_app_assert_direct_owned_path \
    "$owner_root" "$bundle_path" "manifest bundle path" || return 1
  isolated_app_assert_direct_owned_path \
    "$owner_root" "$support_dir" "manifest support path" || return 1
  isolated_app_assert_direct_owned_path \
    "$owner_root" "$manifest" "identity manifest" || return 1
  isolated_app_assert_owned_id "$bundle_id" || return 1
  isolated_app_assert_keychain_service "$bundle_id" "$keychain_service" || return 1
  case "$bundle_path" in "$owner_root"/*) ;; *) return 1 ;; esac
  case "$support_dir" in "$owner_root"/*) ;; *) return 1 ;; esac
  case "$manifest" in "$owner_root"/*) ;; *) return 1 ;; esac
  [[ -n "$executable_name" && "$executable_name" != */* ]] || return 1
  [[ -n "$display_name" && "$source_commit" =~ ^[0-9a-f]{40}$ ]] || return 1
}

# Reserve cleanup authority before staging mutates any bundle path. The
# reservation intentionally contains no payload provenance: those facts do not
# exist until the final rewritten bundle has been authenticated. Publication
# uses a same-directory hard link so an existing authority can never be
# overwritten by a racing invocation.
#
# isolated_app_reserve_manifest <manifest> <owner-root> <source-bundle>
#   <bundle-path> <executable-name> <bundle-id> <display-name> <support-dir>
#   <keychain-service> <source-commit>
isolated_app_reserve_manifest() {
  local manifest="${1:-}"
  local owner_root="${2:-}"
  local source_bundle="${3:-}"
  local bundle_path="${4:-}"
  local executable_name="${5:-}"
  local bundle_id="${6:-}"
  local display_name="${7:-}"
  local support_dir="${8:-}"
  local keychain_service="${9:-}"
  local source_commit="${10:-}"
  local partial nonce status=1

  isolated_app_assert_manifest_request "$@" || return 1
  if [[ -e "$manifest" || -L "$manifest" ]]; then
    isolated_app_error "refusing to replace existing cleanup authority: $manifest"
    return 1
  fi
  partial="$(isolated_app_manifest_partial_path "$manifest" reservation)" || return 1
  isolated_app_assert_direct_owned_path \
    "$owner_root" "$partial" "reservation manifest partial" || return 1
  if [[ -e "$partial" || -L "$partial" ]]; then
    isolated_app_error "reservation partial already exists; explicit cleanup is required: $partial"
    return 1
  fi
  nonce="$(/usr/bin/uuidgen 2>/dev/null | /usr/bin/tr '[:upper:]' '[:lower:]' \
    | /usr/bin/tr -d '-')" || return 1
  [[ "$nonce" =~ ^[0-9a-f]{32}$ ]] || return 1

  while :; do
    /usr/bin/plutil -create xml1 -- "$partial" >/dev/null 2>&1 || break
    /usr/bin/plutil -insert schemaVersion -integer 5 -- "$partial" >/dev/null 2>&1 || break
    isolated_app_plist_insert_string "$partial" manifestState reservation || break
    isolated_app_insert_manifest_coordinates \
      "$partial" "$owner_root" "$source_bundle" "$source_commit" "$bundle_path" \
      "$executable_name" "$bundle_id" "$display_name" "$support_dir" \
      "$keychain_service" "$nonce" || break
    isolated_app_plist_insert_string "$partial" createdAt \
      "$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')" || break
    /usr/bin/plutil -lint -- "$partial" >/dev/null 2>&1 || break
    isolated_app_validate_reservation "$partial" "$owner_root" || break
    # `ln` is an atomic no-clobber publish because both paths share a directory.
    /bin/ln -- "$partial" "$manifest" >/dev/null 2>&1 || break
    /bin/rm -f -- "$partial" || break
    isolated_app_validate_reservation "$manifest" "$owner_root" || break
    status=0
    break
  done
  if [[ "$status" -ne 0 ]]; then
    isolated_app_remove_exact_path "$partial" "reservation manifest partial" || true
  fi
  return "$status"
}

# Finalize the existing reservation from the final staged bundle only. The
# reservation remains authoritative until an already-validated full manifest
# atomically replaces it.
isolated_app_finalize_manifest() {
  local manifest="${1:-}"
  local expected_owner_root="${2:-}"
  local reservation_digest current_digest final_partial
  local source_commit bundle_path executable_name bundle_id bundle_name display_name
  local support_dir service plist embedded_manifest embedded_commit
  local source_input source_main source_ffi source_team status=1

  isolated_app_validate_reservation "$manifest" "$expected_owner_root" || return 1
  reservation_digest="$(build_provenance_sha256_file "$manifest")" || return 1
  bundle_path="$(isolated_app_manifest_value "$manifest" bundlePath)" || return 1
  executable_name="$(isolated_app_manifest_value "$manifest" executableName)" || return 1
  bundle_id="$(isolated_app_manifest_value "$manifest" bundleID)" || return 1
  bundle_name="$(isolated_app_manifest_value "$manifest" bundleName)" || return 1
  display_name="$(isolated_app_manifest_value "$manifest" displayName)" || return 1
  support_dir="$(isolated_app_manifest_value "$manifest" supportPath)" || return 1
  service="$(isolated_app_manifest_value "$manifest" keychainService)" || return 1
  source_commit="$(isolated_app_manifest_value "$manifest" sourceCommit)" || return 1
  plist="$bundle_path/Contents/Info.plist"

  [[ -d "$bundle_path" && -f "$plist" && -f "$bundle_path/Contents/MacOS/$executable_name" ]] \
    || {
      isolated_app_error "reservation cannot be finalized before the staged bundle exists"
      return 1
    }
  [[ "$(isolated_app_plist_value "$plist" CFBundleIdentifier)" == "$bundle_id" \
    && "$(isolated_app_plist_value "$plist" CFBundleExecutable)" == "$executable_name" \
    && "$(isolated_app_plist_value "$plist" CFBundleName)" == "$bundle_name" \
    && "$(isolated_app_plist_value "$plist" CFBundleDisplayName)" == "$display_name" \
    && "$(isolated_app_plist_value "$plist" LSEnvironment.PENSIEVE_SUPPORT_DIR)" \
      == "$support_dir" \
    && "$(isolated_app_plist_value "$plist" LSEnvironment.PENSIEVE_KEYCHAIN_SERVICE)" \
      == "$service" ]] || {
      isolated_app_error "staged bundle coordinates do not match their cleanup reservation"
      return 1
    }
  [[ "$(isolated_app_plist_value "$plist" PensieveBuildCommit)" == "$source_commit" ]] \
    || {
      isolated_app_error "staged bundle commit does not match its cleanup reservation"
      return 1
    }
  isolated_app_assert_strict_signature "$bundle_path" || return 1
  isolated_app_verify_embedded_provenance "$bundle_path" staged || return 1
  embedded_manifest="$(build_provenance_bundle_manifest_path "$bundle_path")"
  embedded_commit="$(build_provenance_read_manifest_value \
    "$embedded_manifest" Commit)" || return 1
  [[ "$source_commit" == "$embedded_commit" ]] || return 1
  source_input="$(build_provenance_read_manifest_value \
    "$embedded_manifest" RuntimeInputSHA256)" || return 1
  source_main="$(build_provenance_read_manifest_value \
    "$embedded_manifest" MainExecutableNormalizedSHA256)" || return 1
  source_ffi="$(build_provenance_read_manifest_value \
    "$embedded_manifest" FFILibraryNormalizedSHA256)" || return 1
  source_team="$(build_provenance_read_manifest_value \
    "$embedded_manifest" SigningTeamIdentifier)" || return 1
  [[ "$source_team" == "$ISOLATED_APP_TRUSTED_TEAM_IDENTIFIER" ]] || return 1

  final_partial="$(isolated_app_manifest_partial_path "$manifest" final)" || return 1
  isolated_app_assert_direct_owned_path \
    "$expected_owner_root" "$final_partial" "final manifest partial" || return 1
  if [[ -e "$final_partial" || -L "$final_partial" ]]; then
    isolated_app_error "final manifest partial already exists; explicit cleanup is required: $final_partial"
    return 1
  fi

  while :; do
    /bin/cp -p -- "$manifest" "$final_partial" || break
    /usr/bin/plutil -replace manifestState -string finalized -- "$final_partial" \
      >/dev/null 2>&1 || break
    isolated_app_plist_insert_string \
      "$final_partial" sourceRuntimeInputSHA256 "$source_input" || break
    isolated_app_plist_insert_string \
      "$final_partial" sourceMainExecutableNormalizedSHA256 "$source_main" || break
    isolated_app_plist_insert_string \
      "$final_partial" sourceFFILibraryNormalizedSHA256 "$source_ffi" || break
    isolated_app_plist_insert_string \
      "$final_partial" sourceTeamIdentifier "$source_team" || break
    isolated_app_plist_insert_string "$final_partial" finalizedAt \
      "$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')" || break
    /usr/bin/plutil -lint -- "$final_partial" >/dev/null 2>&1 || break
    isolated_app_validate_manifest "$final_partial" "$expected_owner_root" || break

    # Refuse to finalize over changed authority. The final `mv` is one atomic
    # same-filesystem publication; no half-full manifest is ever observable.
    isolated_app_validate_reservation "$manifest" "$expected_owner_root" || break
    current_digest="$(build_provenance_sha256_file "$manifest")" || break
    [[ "$current_digest" == "$reservation_digest" ]] || {
      isolated_app_error "cleanup reservation changed during finalization"
      break
    }
    /bin/mv -f -- "$final_partial" "$manifest" || break
    isolated_app_validate_manifest "$manifest" "$expected_owner_root" || break
    status=0
    break
  done
  if [[ "$status" -ne 0 ]]; then
    isolated_app_remove_exact_path "$final_partial" "final manifest partial" || true
  fi
  return "$status"
}

# Deliberately fail old single-phase callers. Creating a full cleanup manifest
# before a staged bundle exists was the integration bug this API replaces.
isolated_app_write_manifest() {
  isolated_app_error \
    "single-phase manifest creation is disabled; reserve, stage, finalize, then verify"
  return 1
}

isolated_app_validate_manifest_coordinates() {
  local manifest="${1:-}"
  local expected_owner_root="${2:-}"
  local expected_state="${3:-}"
  local expected_schema="${4:-5}"
  local schema state owner source_bundle source_commit nonce
  local bundle_path partial_bundle_path executable_name executable_path bundle_id
  local bundle_name display_name support_dir service account
  local preferences recent saved sandbox_saved cache webkit http_storages http_cookies cookies
  local container application_scripts byhost_directory byhost_stem
  local darwin_cache_root darwin_temp_root role darwin_path manifest_role

  [[ -f "$manifest" && ! -L "$manifest" ]] || {
    isolated_app_error "identity manifest is missing: $manifest"
    return 1
  }
  isolated_app_assert_canonical_directory \
    "$expected_owner_root" "expected owner root" || return 1
  isolated_app_assert_direct_owned_path \
    "$expected_owner_root" "$manifest" "identity manifest" || return 1
  schema="$(isolated_app_manifest_value "$manifest" schemaVersion)" || return 1
  state="$(isolated_app_manifest_value "$manifest" manifestState 2>/dev/null)" || state=""
  [[ "$expected_schema" == "4" || "$expected_schema" == "5" ]] || return 1
  [[ "$schema" == "$expected_schema" && "$state" == "$expected_state" ]] \
    || {
      isolated_app_error "identity manifest schema or state does not match $expected_state"
      return 1
    }
  owner="$(isolated_app_manifest_value "$manifest" ownerRoot)" || return 1
  source_bundle="$(isolated_app_manifest_value "$manifest" sourceBundlePath)" || return 1
  source_commit="$(isolated_app_manifest_value "$manifest" sourceCommit)" || return 1
  bundle_path="$(isolated_app_manifest_value "$manifest" bundlePath)" || return 1
  executable_name="$(isolated_app_manifest_value "$manifest" executableName)" || return 1
  executable_path="$(isolated_app_manifest_value "$manifest" executablePath)" || return 1
  bundle_id="$(isolated_app_manifest_value "$manifest" bundleID)" || return 1
  bundle_name="$(isolated_app_manifest_value "$manifest" bundleName)" || return 1
  display_name="$(isolated_app_manifest_value "$manifest" displayName)" || return 1
  support_dir="$(isolated_app_manifest_value "$manifest" supportPath)" || return 1
  service="$(isolated_app_manifest_value "$manifest" keychainService)" || return 1
  account="$(isolated_app_manifest_value "$manifest" keychainAccount)" || return 1
  nonce="$(isolated_app_manifest_value "$manifest" reservationNonce 2>/dev/null)" || nonce=""
  [[ "$owner" == "$expected_owner_root" && "$source_commit" =~ ^[0-9a-f]{40}$ ]] || return 1
  isolated_app_assert_bundle_path "$source_bundle" || return 1
  isolated_app_assert_owned_id "$bundle_id" || return 1
  isolated_app_assert_keychain_service "$bundle_id" "$service" || return 1
  isolated_app_assert_bundle_path "$bundle_path" || return 1
  isolated_app_assert_support_path "$support_dir" || return 1
  isolated_app_assert_shared_owner_parent "$bundle_path" "$support_dir" || return 1
  isolated_app_assert_direct_owned_path \
    "$expected_owner_root" "$bundle_path" "manifest bundle path" || return 1
  isolated_app_assert_direct_owned_path \
    "$expected_owner_root" "$support_dir" "manifest support path" || return 1
  [[ -n "$executable_name" && "$executable_name" != */* \
    && "$bundle_name" == "$executable_name" && -n "$display_name" \
    && "$executable_path" == "$bundle_path/Contents/MacOS/$executable_name" \
    && "$account" == "$ISOLATED_APP_KEYCHAIN_ACCOUNT" ]] || return 1
  [[ "$nonce" =~ ^[0-9a-f]{32}$ ]] || return 1
  partial_bundle_path="$(isolated_app_manifest_value "$manifest" partialBundlePath)" || return 1
  [[ "$partial_bundle_path" == "${bundle_path%.app}.partial.app" ]] || return 1

  preferences="$(isolated_app_preferences_path "$bundle_id")" || return 1
  recent="$(isolated_app_recent_documents_path "$bundle_id")" || return 1
  saved="$(isolated_app_saved_state_path "$bundle_id")" || return 1
  sandbox_saved="$(isolated_app_sandbox_saved_state_path "$bundle_id")" || return 1
  cache="$(isolated_app_cache_path "$bundle_id")" || return 1
  webkit="$(isolated_app_webkit_path "$bundle_id")" || return 1
  http_storages="$(isolated_app_http_storages_path "$bundle_id")" || return 1
  http_cookies="$(isolated_app_http_cookies_path "$bundle_id")" || return 1
  cookies="$(isolated_app_cookies_path "$bundle_id")" || return 1
  container="$(isolated_app_container_path "$bundle_id")" || return 1
  application_scripts="$(isolated_app_application_scripts_path "$bundle_id")" || return 1
  byhost_directory="$(isolated_app_byhost_preferences_directory "$bundle_id")" || return 1
  byhost_stem="$(isolated_app_byhost_preferences_stem "$bundle_id")" || return 1
  [[ "$(isolated_app_manifest_value "$manifest" preferencesPath)" == "$preferences" \
    && "$(isolated_app_manifest_value "$manifest" recentDocumentsPath)" == "$recent" \
    && "$(isolated_app_manifest_value "$manifest" savedStatePath)" == "$saved" \
    && "$(isolated_app_manifest_value "$manifest" sandboxSavedStatePath)" == "$sandbox_saved" \
    && "$(isolated_app_manifest_value "$manifest" cachePath)" == "$cache" \
    && "$(isolated_app_manifest_value "$manifest" webKitPath)" == "$webkit" \
    && "$(isolated_app_manifest_value "$manifest" httpStoragesPath)" == "$http_storages" \
    && "$(isolated_app_manifest_value "$manifest" httpCookiesPath)" == "$http_cookies" \
    && "$(isolated_app_manifest_value "$manifest" cookiesPath)" == "$cookies" \
    && "$(isolated_app_manifest_value "$manifest" containerPath)" == "$container" \
    && "$(isolated_app_manifest_value "$manifest" applicationScriptsPath)" \
      == "$application_scripts" \
    && "$(isolated_app_manifest_value "$manifest" byHostPreferencesDirectory)" \
      == "$byhost_directory" \
    && "$(isolated_app_manifest_value "$manifest" byHostPreferencesStem)" == "$byhost_stem" ]] \
    || return 1

  # Schema 4 already had authenticated two-phase cleanup authority, but it
  # predates the Darwin C/T coordinates. Keep it usable for cleanup only. New
  # reservation, finalization, launch, and verification remain schema 5.
  if [[ "$expected_schema" == "5" ]]; then
    darwin_cache_root="$(isolated_app_darwin_user_directory cache)" || return 1
    darwin_temp_root="$(isolated_app_darwin_user_directory temp)" || return 1
    [[ "$(isolated_app_manifest_value "$manifest" darwinUserCacheDirectory)" \
      == "$darwin_cache_root" \
      && "$(isolated_app_manifest_value "$manifest" darwinUserTempDirectory)" \
        == "$darwin_temp_root" ]] || return 1
    for role in GPU Networking WebContent; do
      manifest_role="$role"
      darwin_path="$(isolated_app_darwin_webkit_path \
        "$bundle_id" "$darwin_cache_root" "$role")" || return 1
      [[ "$(isolated_app_manifest_value \
        "$manifest" "darwinWebKitCache${manifest_role}Path")" == "$darwin_path" ]] \
        || return 1
      darwin_path="$(isolated_app_darwin_webkit_path \
        "$bundle_id" "$darwin_temp_root" "$role")" || return 1
      [[ "$(isolated_app_manifest_value \
        "$manifest" "darwinWebKitTemp${manifest_role}Path")" == "$darwin_path" ]] \
        || return 1
    done
  fi
  return 0
}

isolated_app_validate_reservation() {
  isolated_app_validate_manifest_coordinates "${1:-}" "${2:-}" reservation
}

isolated_app_validate_cleanup_manifest() {
  local manifest="${1:-}"
  local expected_owner_root="${2:-}"
  local state schema
  schema="$(isolated_app_manifest_value "$manifest" schemaVersion)" || return 1
  state="$(isolated_app_manifest_value "$manifest" manifestState 2>/dev/null)" || state=""
  case "$schema/$state" in
    5/reservation)
      isolated_app_validate_reservation "$manifest" "$expected_owner_root"
      ;;
    5/finalized)
      isolated_app_validate_manifest "$manifest" "$expected_owner_root"
      ;;
    4/reservation)
      isolated_app_validate_manifest_coordinates \
        "$manifest" "$expected_owner_root" reservation 4
      ;;
    4/finalized)
      isolated_app_validate_manifest_coordinates \
        "$manifest" "$expected_owner_root" finalized 4 \
        && isolated_app_validate_manifest_payload "$manifest"
      ;;
    *)
      isolated_app_error \
        "identity manifest schema or state cannot authorize cleanup: $schema/$state"
      return 1
      ;;
  esac
}

isolated_app_validate_manifest_payload() {
  local manifest="${1:-}"
  local source_input source_main source_ffi source_team digest
  source_input="$(isolated_app_manifest_value "$manifest" sourceRuntimeInputSHA256)" || return 1
  source_main="$(isolated_app_manifest_value \
    "$manifest" sourceMainExecutableNormalizedSHA256)" || return 1
  source_ffi="$(isolated_app_manifest_value \
    "$manifest" sourceFFILibraryNormalizedSHA256)" || return 1
  source_team="$(isolated_app_manifest_value "$manifest" sourceTeamIdentifier)" || return 1
  for digest in "$source_input" "$source_main" "$source_ffi"; do
    build_provenance_is_sha256 "$digest" || return 1
  done
  [[ "$source_team" == "$ISOLATED_APP_TRUSTED_TEAM_IDENTIFIER" ]] || {
    isolated_app_error "identity manifest does not name the trusted source TeamIdentifier"
    return 1
  }
}

isolated_app_validate_manifest() {
  local manifest="${1:-}"
  local expected_owner_root="${2:-}"
  isolated_app_validate_manifest_coordinates \
    "$manifest" "$expected_owner_root" finalized 5 || return 1
  isolated_app_validate_manifest_payload "$manifest"
}

isolated_app_verify_bundle_from_manifest() {
  local manifest="${1:-}"
  local expected_owner_root="${2:-}"
  local bundle_path executable_name bundle_id bundle_name display_name support_dir service plist
  local source_commit source_input source_main source_ffi source_team embedded_manifest
  isolated_app_validate_manifest "$manifest" "$expected_owner_root" || return 1
  bundle_path="$(isolated_app_manifest_value "$manifest" bundlePath)" || return 1
  executable_name="$(isolated_app_manifest_value "$manifest" executableName)" || return 1
  bundle_id="$(isolated_app_manifest_value "$manifest" bundleID)" || return 1
  bundle_name="$(isolated_app_manifest_value "$manifest" bundleName)" || return 1
  display_name="$(isolated_app_manifest_value "$manifest" displayName)" || return 1
  support_dir="$(isolated_app_manifest_value "$manifest" supportPath)" || return 1
  service="$(isolated_app_manifest_value "$manifest" keychainService)" || return 1
  source_commit="$(isolated_app_manifest_value "$manifest" sourceCommit)" || return 1
  source_input="$(isolated_app_manifest_value "$manifest" sourceRuntimeInputSHA256)" || return 1
  source_main="$(isolated_app_manifest_value \
    "$manifest" sourceMainExecutableNormalizedSHA256)" || return 1
  source_ffi="$(isolated_app_manifest_value \
    "$manifest" sourceFFILibraryNormalizedSHA256)" || return 1
  source_team="$(isolated_app_manifest_value "$manifest" sourceTeamIdentifier)" || return 1
  plist="$bundle_path/Contents/Info.plist"
  [[ -d "$bundle_path" && -f "$plist" && -f "$bundle_path/Contents/MacOS/$executable_name" ]] \
    || return 1
  [[ "$(isolated_app_plist_value "$plist" CFBundleIdentifier)" == "$bundle_id" ]] || return 1
  [[ "$(isolated_app_plist_value "$plist" CFBundleExecutable)" == "$executable_name" ]] || return 1
  [[ "$(isolated_app_plist_value "$plist" CFBundleName)" == "$bundle_name" ]] || return 1
  [[ "$(isolated_app_plist_value "$plist" CFBundleDisplayName)" == "$display_name" ]] || return 1
  [[ "$(isolated_app_plist_value "$plist" LSEnvironment.PENSIEVE_SUPPORT_DIR)" \
    == "$support_dir" ]] || return 1
  [[ "$(isolated_app_plist_value "$plist" LSEnvironment.PENSIEVE_KEYCHAIN_SERVICE)" \
    == "$service" ]] || return 1
  [[ "$(isolated_app_plist_value "$plist" PensieveBuildCommit)" == "$source_commit" ]] || return 1
  isolated_app_assert_strict_signature "$bundle_path" || return 1
  isolated_app_verify_embedded_provenance "$bundle_path" staged || return 1
  embedded_manifest="$(build_provenance_bundle_manifest_path "$bundle_path")"
  [[ "$(build_provenance_read_manifest_value \
    "$embedded_manifest" Commit)" == "$source_commit" ]] || return 1
  [[ "$(build_provenance_read_manifest_value \
    "$embedded_manifest" RuntimeInputSHA256)" == "$source_input" ]] || return 1
  [[ "$(build_provenance_read_manifest_value \
    "$embedded_manifest" MainExecutableNormalizedSHA256)" == "$source_main" ]] || return 1
  [[ "$(build_provenance_read_manifest_value \
    "$embedded_manifest" FFILibraryNormalizedSHA256)" == "$source_ffi" ]] || return 1
  [[ "$(build_provenance_read_manifest_value \
    "$embedded_manifest" SigningTeamIdentifier)" == "$source_team" ]] || return 1
  [[ "$source_team" == "$ISOLATED_APP_TRUSTED_TEAM_IDENTIFIER" ]]
}

isolated_app_cleanup_manifest() {
  local manifest="${1:-}"
  local expected_owner_root="${2:-}"
  local bundle_id bundle_path support_dir service account reservation_partial final_partial
  local schema darwin_cache_root darwin_temp_root retained_snapshot retained_count retained_roles
  isolated_app_assert_canonical_directory \
    "$expected_owner_root" "expected owner root" || return 1
  isolated_app_assert_direct_owned_path \
    "$expected_owner_root" "$manifest" "identity manifest" || return 1
  reservation_partial="$(isolated_app_manifest_partial_path "$manifest" reservation)" || return 1
  final_partial="$(isolated_app_manifest_partial_path "$manifest" final)" || return 1
  isolated_app_assert_direct_owned_path \
    "$expected_owner_root" "$reservation_partial" "reservation manifest partial" || return 1
  isolated_app_assert_direct_owned_path \
    "$expected_owner_root" "$final_partial" "final manifest partial" || return 1

  # An interrupted atomic reservation can leave only its temporary plist. No
  # bundle mutation is permitted before reservation publication, so remove the
  # two exact manifest temporaries only when they are the owner's sole children.
  if [[ ! -e "$manifest" && ! -L "$manifest" ]]; then
    isolated_app_owner_contains_only_direct_paths \
      "$expected_owner_root" "$reservation_partial" "$final_partial" || return 1
    isolated_app_remove_exact_path \
      "$reservation_partial" "reservation manifest partial" || return 1
    isolated_app_remove_exact_path "$final_partial" "final manifest partial" || return 1
    if ! /bin/rmdir "$expected_owner_root"; then
      isolated_app_error "could not retire empty isolated owner root: $expected_owner_root"
      return 1
    fi
    return 0
  fi

  isolated_app_validate_cleanup_manifest "$manifest" "$expected_owner_root" || return 1
  schema="$(isolated_app_manifest_value "$manifest" schemaVersion)" || return 1
  bundle_id="$(isolated_app_manifest_value "$manifest" bundleID)" || return 1
  bundle_path="$(isolated_app_manifest_value "$manifest" bundlePath)" || return 1
  support_dir="$(isolated_app_manifest_value "$manifest" supportPath)" || return 1
  service="$(isolated_app_manifest_value "$manifest" keychainService)" || return 1
  account="$(isolated_app_manifest_value "$manifest" keychainAccount)" || return 1
  if [[ "$schema" == "5" ]]; then
    darwin_cache_root="$(isolated_app_manifest_value \
      "$manifest" darwinUserCacheDirectory)" || return 1
    darwin_temp_root="$(isolated_app_manifest_value \
      "$manifest" darwinUserTempDirectory)" || return 1
  else
    # Schema 4 could not pin Darwin coordinates. Its already-authenticated
    # bundle ID bounds the exact role names; getconf supplies today's canonical
    # per-user roots without trusting data added to the legacy plist.
    darwin_cache_root="$(isolated_app_darwin_user_directory cache)" || return 1
    darwin_temp_root="$(isolated_app_darwin_user_directory temp)" || return 1
  fi
  isolated_app_cleanup_identity \
    "$bundle_id" "$bundle_path" "$support_dir" "$service" "$expected_owner_root" "$account" \
    "$darwin_cache_root" "$darwin_temp_root" \
    || return 1
  # Re-census the explicit manifest coordinates immediately before retiring
  # cleanup authority. A recreated C payload or malformed T shell keeps the
  # manifest intact for a safe retry.
  isolated_app_known_profile_namespace_is_empty \
    "$bundle_id" "$support_dir" "$service" "$account" 0 \
    "$darwin_cache_root" || return 1
  retained_snapshot="$(isolated_app_darwin_webkit_temp_shell_snapshot \
    "$bundle_id" "$darwin_temp_root")" || return 1
  retained_count="${retained_snapshot%%|*}"
  retained_roles="${retained_snapshot#*|}"
  isolated_app_owner_contains_only_direct_paths \
    "$expected_owner_root" "$manifest" "$reservation_partial" "$final_partial" \
    || return 1
  isolated_app_remove_exact_path \
    "$reservation_partial" "reservation manifest partial" || return 1
  isolated_app_remove_exact_path "$final_partial" "final manifest partial" || return 1
  isolated_app_remove_exact_path "$manifest" "isolated identity manifest" || return 1
  if ! /bin/rmdir "$expected_owner_root"; then
    isolated_app_error "could not retire empty isolated owner root: $expected_owner_root"
    return 1
  fi
  if [[ "$retained_count" -gt 0 ]]; then
    # Informational only. All authoritative cleanup and manifest retirement is
    # already complete; reporting cannot retroactively make it fail.
    isolated_app_report_retained_darwin_webkit_temp_shells \
      "$bundle_id" "$darwin_temp_root" "$retained_count" "$retained_roles" \
      || true
  fi
  return 0
}

# isolated_app_open_new <bundle-id> <bundle-path> <support-dir>
#   <keychain-service> [document-or-url ...]
isolated_app_open_new() {
  local bundle_id="${1:-}"
  local bundle_path="${2:-}"
  local support_dir="${3:-}"
  local service="${4:-}"
  shift 4 || return 1
  isolated_app_assert_owned_id "$bundle_id" || return 1
  isolated_app_assert_bundle_path "$bundle_path" || return 1
  isolated_app_assert_support_path "$support_dir" || return 1
  isolated_app_assert_keychain_service "$bundle_id" "$service" || return 1
  [[ -d "$bundle_path" ]] || return 1
  /bin/mkdir -p "$support_dir" || return 1
  /usr/bin/open \
    --env "PENSIEVE_SUPPORT_DIR=$support_dir" \
    --env "PENSIEVE_KEYCHAIN_SERVICE=$service" \
    -n -a "$bundle_path" "$@"
}

isolated_app_reopen() {
  local bundle_id="${1:-}"
  local bundle_path="${2:-}"
  local support_dir="${3:-}"
  local service="${4:-}"
  local running_status
  isolated_app_assert_owned_id "$bundle_id" || return 1
  isolated_app_assert_bundle_path "$bundle_path" || return 1
  isolated_app_assert_support_path "$support_dir" || return 1
  isolated_app_assert_keychain_service "$bundle_id" "$service" || return 1
  if isolated_app_identity_is_running "$bundle_id"; then
    /usr/bin/open -a "$bundle_path"
  else
    running_status=$?
    [[ "$running_status" -eq 1 ]] || return 1
    isolated_app_open_new "$bundle_id" "$bundle_path" "$support_dir" "$service"
  fi
}
