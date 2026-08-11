#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "$0")" && pwd -P)"

# Git exports repository-local variables such as GIT_DIR to hooks. Without
# scrubbing them, `git -C "$FIXTURE_ROOT/..." init` still targets the caller's
# real repository and a pre-push test can commit fixture files onto the branch
# it is supposed to validate. Clear every local-repository override before any
# helper or fixture Git command runs; `-C` can then provide the only repository
# context.
while IFS= read -r git_local_environment_name; do
  [[ -n "$git_local_environment_name" ]] \
    && unset "$git_local_environment_name"
done < <(/usr/bin/git rev-parse --local-env-vars 2>/dev/null)
unset git_local_environment_name

HOST_REPO_ROOT="$(cd -P "$SCRIPT_DIR/.." && pwd -P)"
HOST_HEAD_BEFORE="$(/usr/bin/git -C "$HOST_REPO_ROOT" rev-parse HEAD)"
HOST_STATUS_BEFORE="$(
  /usr/bin/git -C "$HOST_REPO_ROOT" status --porcelain=v1 --untracked-files=all
)"

# shellcheck source=scripts/lib/isolated-app.sh
source "$SCRIPT_DIR/lib/isolated-app.sh"

FIXTURE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/pensieve-isolated-app-test.XXXXXX")"
FIXTURE_ROOT="$(cd -P "$FIXTURE_ROOT" && pwd -P)"
SOURCE_APP="$FIXTURE_ROOT/source/Pensieve.app"
OWNER_ROOT="$FIXTURE_ROOT/owner"
STAGED_APP="$OWNER_ROOT/PensieveManual.app"
SUPPORT_DIR="$OWNER_ROOT/state"
MANIFEST="$OWNER_ROOT/identity.plist"
EXECUTABLE_NAME="PensieveManual"
SOURCE_COMMIT=""
SOURCE_ENTITLEMENTS="$FIXTURE_ROOT/source-entitlements.plist"
PROVENANCE_REPO="$FIXTURE_ROOT/provenance-repo"
TRUSTED_SIGNING_IDENTITY=""
LSREGISTER_PATH="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
BUNDLE_ID=""
KEYCHAIN_SERVICE=""
RECENTS_RACE_ID=""
RECENTS_RACE_PATH=""
CLEANUP_BUNDLE_ID=""
CLEANUP_APP=""
CLEANUP_SUPPORT=""
DEFAULTS_RACE_ID=""
NAMESPACE_RACE_ID=""
NAMESPACE_RACE_SUPPORT=""
NAMESPACE_RACE_KEYCHAIN_SERVICE=""
RECENTS_WRITER_PID=""
DEFAULTS_WRITER_PID=""
NAMESPACE_WRITER_PID=""
LAUNCHSERVICES_WRITER_PID=""

cleanup() {
  local original_status="$?"
  trap - EXIT INT TERM
  set +e
  for writer_pid in \
    "$RECENTS_WRITER_PID" "$DEFAULTS_WRITER_PID" \
    "$NAMESPACE_WRITER_PID" "$LAUNCHSERVICES_WRITER_PID"
  do
    if [[ "$writer_pid" =~ ^[1-9][0-9]*$ ]]; then
      /bin/kill "$writer_pid" >/dev/null 2>&1 || true
      wait "$writer_pid" >/dev/null 2>&1 || true
    fi
  done
  if [[ -n "$BUNDLE_ID" && -d "$STAGED_APP" ]] \
    && [[ "$(type -t isolated_app_unregister_launchservices_identity 2>/dev/null)" \
      == "function" ]]; then
    isolated_app_unregister_launchservices_identity "$BUNDLE_ID" "$STAGED_APP" \
      >/dev/null 2>&1 || true
  fi
  if [[ -n "$CLEANUP_BUNDLE_ID" && -d "$CLEANUP_APP" ]]; then
    isolated_app_unregister_launchservices_identity \
      "$CLEANUP_BUNDLE_ID" "$CLEANUP_APP" >/dev/null 2>&1 || true
  fi
  if [[ -n "$RECENTS_RACE_PATH" ]]; then
    /bin/rm -f -- "$RECENTS_RACE_PATH"
  fi
  if [[ -n "$DEFAULTS_RACE_ID" ]]; then
    isolated_app_reset_defaults_domain "$DEFAULTS_RACE_ID" >/dev/null 2>&1 || true
  fi
  if [[ -n "$NAMESPACE_RACE_ID" && -n "$NAMESPACE_RACE_SUPPORT" \
    && -n "$NAMESPACE_RACE_KEYCHAIN_SERVICE" ]]; then
    isolated_app_remove_known_profile_state_once \
      "$NAMESPACE_RACE_ID" "$NAMESPACE_RACE_SUPPORT" \
      "$NAMESPACE_RACE_KEYCHAIN_SERVICE" >/dev/null 2>&1 || true
  fi
  if [[ -d "$FIXTURE_ROOT" ]]; then
    /bin/rm -R -- "$FIXTURE_ROOT"
  fi
  exit "$original_status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

fail() {
  printf '[isolated-app test FAIL] %s\n' "$*" >&2
  exit 1
}

pass() {
  printf '[isolated-app test PASS] %s\n' "$*"
}

assert_plist_value() {
  local plist="$1"
  local key="$2"
  local expected="$3"
  local actual
  actual="$(isolated_app_plist_value "$plist" "$key")" \
    || fail "could not read $key from $plist"
  [[ "$actual" == "$expected" ]] \
    || fail "$key expected [$expected], got [$actual]"
}

make_source_fixture() {
  local plist="$SOURCE_APP/Contents/Info.plist"
  /bin/mkdir -p \
    "$SOURCE_APP/Contents/MacOS" \
    "$SOURCE_APP/Contents/Frameworks" \
    "$SOURCE_APP/Contents/Resources"
  printf '%s\n' 'int main(void) { return 0; }' \
    | /usr/bin/clang -x c -o "$SOURCE_APP/Contents/MacOS/Pensieve" - \
    || fail "could not compile the synthetic Mach-O fixture"
  printf '%s\n' 'int qube_fixture(void) { return 1; }' \
    | /usr/bin/clang -dynamiclib -x c \
      -o "$SOURCE_APP/Contents/Frameworks/libqube_ffi.dylib" - \
    || fail "could not compile the synthetic FFI fixture"
  /usr/bin/plutil -create xml1 -- "$plist"
  /usr/bin/plutil -insert CFBundlePackageType -string APPL -- "$plist"
  /usr/bin/plutil -insert CFBundleExecutable -string Pensieve -- "$plist"
  /usr/bin/plutil -insert CFBundleIdentifier -string io.vetcoders.pensieve -- "$plist"
  /usr/bin/plutil -insert CFBundleName -string Pensieve -- "$plist"
  /usr/bin/plutil -insert CFBundleDisplayName -string Pensieve -- "$plist"
  /usr/bin/plutil -insert CFBundleShortVersionString -string 0.0.0 -- "$plist"
  /usr/bin/plutil -insert CFBundleVersion -string 1 -- "$plist"
  /usr/bin/plutil -insert PensieveBuildCommit -string "$SOURCE_COMMIT" -- "$plist"
  /usr/bin/plutil -create xml1 -- "$SOURCE_ENTITLEMENTS"
  /usr/libexec/PlistBuddy \
    -c 'Add :com.apple.security.device.audio-input bool true' "$SOURCE_ENTITLEMENTS" \
    >/dev/null
  sign_source_fixture -
}

sign_source_fixture() {
  local identity="$1"
  local input_digest main_digest ffi_digest embedded_manifest
  /usr/bin/codesign --force --sign "$identity" --timestamp=none --options runtime \
    --entitlements "$SOURCE_ENTITLEMENTS" \
    "$SOURCE_APP/Contents/MacOS/Pensieve" >/dev/null 2>&1 \
    || fail "could not sign the main source fixture"
  /usr/bin/codesign --force --sign "$identity" --timestamp=none --options runtime \
    "$SOURCE_APP/Contents/Frameworks/libqube_ffi.dylib" >/dev/null 2>&1 \
    || fail "could not sign the source FFI fixture"
  input_digest="$(build_provenance_runtime_input_digest "$PROVENANCE_REPO" release)" \
    || fail "could not refresh the synthetic runtime digest"
  main_digest="$(build_provenance_normalized_macho_digest \
    "$SOURCE_APP/Contents/MacOS/Pensieve")" || fail "could not rehash the main fixture"
  ffi_digest="$(build_provenance_normalized_macho_digest \
    "$SOURCE_APP/Contents/Frameworks/libqube_ffi.dylib")" \
    || fail "could not rehash the FFI fixture"
  embedded_manifest="$(build_provenance_bundle_manifest_path "$SOURCE_APP")"
  build_provenance_write_manifest \
    "$embedded_manifest" "$SOURCE_COMMIT" "$input_digest" release release arm64 \
    "$main_digest" "$ffi_digest" '2026-08-11T00:00:00Z' \
    || fail "could not refresh the synthetic embedded provenance"
  /usr/bin/codesign --force --sign "$identity" --timestamp=none --options runtime \
    --entitlements "$SOURCE_ENTITLEMENTS" "$SOURCE_APP" >/dev/null 2>&1 \
    || fail "could not sign the source fixture"
  /usr/bin/codesign --verify --deep --strict "$SOURCE_APP" >/dev/null 2>&1 \
    || fail "source fixture signature is invalid"
}

refresh_source_provenance() {
  local source_version source_build
  source_version="$(/usr/bin/git -C "$PROVENANCE_REPO" \
    show "$SOURCE_COMMIT:VERSION" | /usr/bin/tr -d '[:space:]')" \
    || fail "could not read the synthetic source version"
  source_build="$(/usr/bin/git -C "$PROVENANCE_REPO" \
    rev-list --count "$SOURCE_COMMIT")" \
    || fail "could not read the synthetic source build number"
  isolated_app_plist_set_string \
    "$SOURCE_APP/Contents/Info.plist" PensieveBuildCommit "$SOURCE_COMMIT" \
    || fail "could not refresh the synthetic source commit"
  isolated_app_plist_set_string \
    "$SOURCE_APP/Contents/Info.plist" CFBundleShortVersionString "$source_version" \
    || fail "could not refresh the synthetic source version"
  isolated_app_plist_set_string \
    "$SOURCE_APP/Contents/Info.plist" CFBundleVersion "$source_build" \
    || fail "could not refresh the synthetic source build number"
  sign_source_fixture "${TRUSTED_SIGNING_IDENTITY:--}"
}

codesign_entitlements_json() {
  local bundle="$1"
  /usr/bin/codesign -d --entitlements :- "$bundle" 2>/dev/null \
    | /usr/bin/plutil -convert json -o - -- - 2>/dev/null
}

assert_hardened_runtime() {
  local bundle="$1"
  /usr/bin/codesign -d --verbose=4 "$bundle" 2>&1 \
    | /usr/bin/grep -E 'flags=.*runtime' >/dev/null
}

run_certless_cleanup_tests() {
  local cleanup_owner byhost_dir byhost_path container_path scripts_path
  local owner_real owner_alias outside_support support_link manifest_target manifest_link
  local reservation_owner reservation_app reservation_support reservation_manifest
  local reservation_id reservation_service reservation_preferences
  local reservation_partial final_partial interrupted_owner interrupted_manifest
  local interrupted_partial orphan_owner orphan_manifest orphan_partial

  owner_real="$FIXTURE_ROOT/path-guards-owner"
  owner_alias="$FIXTURE_ROOT/path-guards-owner-alias"
  outside_support="$FIXTURE_ROOT/path-guards-outside-support"
  support_link="$owner_real/support"
  manifest_target="$owner_real/manifest-target.plist"
  manifest_link="$owner_real/identity.plist"
  /bin/mkdir "$owner_real" "$outside_support"
  /bin/ln -s "$owner_real" "$owner_alias"
  /bin/ln -s "$outside_support" "$support_link"
  printf 'fixture\n' >"$manifest_target"
  /bin/ln -s "$manifest_target" "$manifest_link"
  if isolated_app_assert_canonical_directory "$owner_alias" "owner alias" >/dev/null 2>&1; then
    fail "a symlinked owner root passed the canonical owner guard"
  fi
  if isolated_app_assert_canonical_directory /private/tmp "foreign owner root" \
    >/dev/null 2>&1; then
    fail "a directory owned by another uid passed the owner-root guard"
  fi
  if isolated_app_assert_support_path "$support_link" >/dev/null 2>&1; then
    fail "a symlinked support root passed the support-path guard"
  fi
  if isolated_app_assert_direct_owned_path \
    "$owner_real" "$manifest_link" "manifest alias" >/dev/null 2>&1; then
    fail "a symlinked manifest passed the direct-owned-path guard"
  fi
  pass "owner, support and manifest symlink escapes are rejected before mutation"

  if isolated_app_write_manifest >/dev/null 2>&1; then
    fail "the retired single-phase manifest API became usable again"
  fi
  pass "single-phase manifest publication remains a hard failure"

  CLEANUP_BUNDLE_ID="$(isolated_app_generate_bundle_id smoke)" \
    || fail "could not generate a certless cleanup identity"
  cleanup_owner="$FIXTURE_ROOT/certless-cleanup-owner"
  CLEANUP_APP="$cleanup_owner/PensieveCleanup.app"
  CLEANUP_SUPPORT="$cleanup_owner/support"
  /bin/mkdir "$cleanup_owner" "$CLEANUP_SUPPORT"
  /usr/bin/ditto "$SOURCE_APP" "$CLEANUP_APP"
  isolated_app_plist_set_string \
    "$CLEANUP_APP/Contents/Info.plist" CFBundleIdentifier "$CLEANUP_BUNDLE_ID"
  /usr/bin/codesign --force --sign - --timestamp=none --options runtime \
    "$CLEANUP_APP" >/dev/null 2>&1 \
    || fail "could not sign the certless LaunchServices fixture"

  RECENTS_RACE_ID="$(isolated_app_generate_bundle_id smoke)" \
    || fail "could not generate a recent-documents race identity"
  RECENTS_RACE_PATH="$(isolated_app_recent_documents_path "$RECENTS_RACE_ID")" \
    || fail "could not derive the recent-documents race path"
  /bin/mkdir -p "$(/usr/bin/dirname "$RECENTS_RACE_PATH")"
  printf 'initial daemon write\n' >"$RECENTS_RACE_PATH"
  (
    /bin/sleep 0.25
    printf 'late daemon write\n' >"$RECENTS_RACE_PATH"
  ) &
  RECENTS_WRITER_PID=$!
  isolated_app_retire_recent_documents "$RECENTS_RACE_ID" \
    || fail "recent-documents retirement did not survive a late daemon write"
  wait "$RECENTS_WRITER_PID"
  RECENTS_WRITER_PID=""
  [[ ! -e "$RECENTS_RACE_PATH" ]] \
    || fail "late recent-documents write survived the quiet-period cleanup"
  pass "recent-documents cleanup survives an exact late writer"

  DEFAULTS_RACE_ID="$(isolated_app_generate_bundle_id smoke)" \
    || fail "could not generate a defaults race identity"
  (
    /bin/sleep 0.25
    /usr/bin/defaults write "$DEFAULTS_RACE_ID" Pensieve.workspace.rootBookmarks \
      -string 'late-writer'
  ) &
  DEFAULTS_WRITER_PID=$!
  isolated_app_reset_defaults_domain "$DEFAULTS_RACE_ID" \
    || fail "defaults retirement did not survive a late cfprefsd write"
  wait "$DEFAULTS_WRITER_PID"
  DEFAULTS_WRITER_PID=""
  isolated_app_defaults_domain_is_empty "$DEFAULTS_RACE_ID" \
    || fail "late defaults write survived the quiet-period cleanup"
  pass "defaults cleanup survives an exact late writer"

  NAMESPACE_RACE_ID="$(isolated_app_generate_bundle_id smoke)" \
    || fail "could not generate a namespace race identity"
  NAMESPACE_RACE_KEYCHAIN_SERVICE="$NAMESPACE_RACE_ID.completion-provider"
  NAMESPACE_RACE_SUPPORT="$FIXTURE_ROOT/namespace-race-support"
  byhost_dir="$(isolated_app_byhost_preferences_directory "$NAMESPACE_RACE_ID")"
  byhost_path="$byhost_dir/$NAMESPACE_RACE_ID.fixture.plist"
  container_path="$(isolated_app_container_path "$NAMESPACE_RACE_ID")"
  scripts_path="$(isolated_app_application_scripts_path "$NAMESPACE_RACE_ID")"
  /bin/mkdir -p "$NAMESPACE_RACE_SUPPORT" "$byhost_dir" "$container_path" "$scripts_path"
  printf 'state\n' >"$NAMESPACE_RACE_SUPPORT/state"
  printf 'state\n' >"$byhost_path"
  printf 'state\n' >"$container_path/state"
  printf 'state\n' >"$scripts_path/state"
  (
    /bin/sleep 0.25
    /bin/mkdir -p "$container_path"
    printf 'late state\n' >"$container_path/late-state"
  ) &
  NAMESPACE_WRITER_PID=$!
  isolated_app_retire_known_profile_namespace \
    "$NAMESPACE_RACE_ID" "$NAMESPACE_RACE_SUPPORT" \
    "$NAMESPACE_RACE_KEYCHAIN_SERVICE" \
    || fail "bounded namespace retirement did not survive a late helper write"
  wait "$NAMESPACE_WRITER_PID"
  NAMESPACE_WRITER_PID=""
  isolated_app_known_profile_namespace_is_empty \
    "$NAMESPACE_RACE_ID" "$NAMESPACE_RACE_SUPPORT" \
    "$NAMESPACE_RACE_KEYCHAIN_SERVICE" \
    || fail "known UUID namespace was not empty after its quiet-period census"
  pass "bounded namespace cleanup covers ByHost, Containers and Application Scripts"

  "$LSREGISTER_PATH" -f "$CLEANUP_APP" >/dev/null 2>&1 \
    || fail "could not register the certless cleanup bundle"
  (
    /bin/sleep 0.25
    "$LSREGISTER_PATH" -f "$CLEANUP_APP" >/dev/null 2>&1
  ) &
  LAUNCHSERVICES_WRITER_PID=$!
  isolated_app_unregister_launchservices_identity \
    "$CLEANUP_BUNDLE_ID" "$CLEANUP_APP" \
    || fail "LaunchServices retirement did not survive a late registration"
  wait "$LAUNCHSERVICES_WRITER_PID"
  LAUNCHSERVICES_WRITER_PID=""
  if isolated_app_launchservices_registration_exists "$CLEANUP_BUNDLE_ID"; then
    fail "late LaunchServices registration survived the quiet-period cleanup"
  fi
  /bin/rm -R -- "$CLEANUP_APP"
  CLEANUP_APP=""
  CLEANUP_BUNDLE_ID=""
  pass "LaunchServices cleanup survives an exact late registration"

  reservation_owner="$FIXTURE_ROOT/reservation-cleanup-owner"
  reservation_app="$reservation_owner/PensieveReservation.app"
  reservation_support="$reservation_owner/support"
  reservation_manifest="$reservation_owner/identity.plist"
  reservation_id="$(isolated_app_generate_bundle_id smoke)" \
    || fail "could not generate a reservation cleanup identity"
  reservation_service="$reservation_id.completion-provider"
  /bin/mkdir "$reservation_owner"
  isolated_app_reserve_manifest \
    "$reservation_manifest" "$reservation_owner" "$SOURCE_APP" \
    "$reservation_app" PensieveReservation "$reservation_id" \
    "Pensieve Reservation" "$reservation_support" "$reservation_service" \
    "$SOURCE_COMMIT" \
    || fail "could not publish a cleanup reservation before staging"
  isolated_app_validate_reservation "$reservation_manifest" "$reservation_owner" \
    || fail "a freshly published reservation did not validate"
  if isolated_app_verify_bundle_from_manifest \
    "$reservation_manifest" "$reservation_owner" >/dev/null 2>&1; then
    fail "bundle verification accepted an unfinalized cleanup reservation"
  fi
  pass "an unfinalized reservation grants cleanup authority but never launch authority"

  /bin/mkdir "$reservation_support" "${reservation_app%.app}.partial.app"
  final_partial="$(isolated_app_manifest_partial_path "$reservation_manifest" final)"
  printf 'interrupted finalization\n' >"$final_partial"
  reservation_preferences="$(isolated_app_manifest_value \
    "$reservation_manifest" preferencesPath)"
  /usr/bin/plutil -replace preferencesPath \
    -string "$FIXTURE_ROOT/tampered-preferences.plist" -- "$reservation_manifest"
  if isolated_app_validate_cleanup_manifest \
    "$reservation_manifest" "$reservation_owner" >/dev/null 2>&1; then
    fail "cleanup validation accepted a reservation with tampered derived coordinates"
  fi
  if isolated_app_cleanup_manifest \
    "$reservation_manifest" "$reservation_owner" >/dev/null 2>&1; then
    fail "cleanup mutated state under a tampered reservation"
  fi
  [[ -e "$reservation_manifest" && -d "$reservation_support" \
    && -d "${reservation_app%.app}.partial.app" && -e "$final_partial" ]] \
    || fail "tamper rejection changed reservation-owned state"
  /usr/bin/plutil -replace preferencesPath -string "$reservation_preferences" \
    -- "$reservation_manifest"
  isolated_app_cleanup_manifest "$reservation_manifest" "$reservation_owner" \
    || fail "valid reservation cleanup failed"
  reservation_partial="$(isolated_app_manifest_partial_path \
    "$reservation_manifest" reservation)"
  [[ ! -e "$reservation_owner" && ! -e "$reservation_manifest" \
    && ! -e "$reservation_support" && ! -e "${reservation_app%.app}.partial.app" \
    && ! -e "$reservation_partial" && ! -e "$final_partial" ]] \
    || fail "reservation cleanup left partial or profile residue"
  pass "reservation cleanup rejects tampering and retires only its exact partial capsule"

  interrupted_owner="$FIXTURE_ROOT/interrupted-reservation-owner"
  interrupted_manifest="$interrupted_owner/identity.plist"
  interrupted_partial="$(isolated_app_manifest_partial_path \
    "$interrupted_manifest" reservation)"
  /bin/mkdir "$interrupted_owner"
  printf 'interrupted reservation publication\n' >"$interrupted_partial"
  isolated_app_cleanup_manifest "$interrupted_manifest" "$interrupted_owner" \
    || fail "cleanup could not retire a lone interrupted reservation temporary"
  [[ ! -e "$interrupted_owner" && ! -e "$interrupted_partial" ]] \
    || fail "interrupted reservation cleanup left a partial manifest"

  orphan_owner="$FIXTURE_ROOT/missing-authority-owner"
  orphan_manifest="$orphan_owner/identity.plist"
  orphan_partial="$orphan_owner/PensieveOrphan.partial.app"
  /bin/mkdir -p "$orphan_partial"
  if isolated_app_cleanup_manifest "$orphan_manifest" "$orphan_owner" \
    >/dev/null 2>&1; then
    fail "cleanup accepted staged residue without cleanup authority"
  fi
  [[ -d "$orphan_partial" ]] \
    || fail "missing-authority cleanup mutated an unauthenticated partial bundle"
  /bin/rm -R -- "$orphan_owner"
  pass "interrupted publication is bounded while missing cleanup authority fails closed"
}

# Source provenance is exercised in a disposable repository with the complete
# runtime-input shape consumed by build-provenance.sh. Smoke-harness edits are
# deliberately outside that shape.
/bin/mkdir -p \
  "$PROVENANCE_REPO/scripts/lib" \
  "$PROVENANCE_REPO/Pensieve/Sources" \
  "$PROVENANCE_REPO/Pensieve/Resources" \
  "$PROVENANCE_REPO/Pensieve/scripts" \
  "$PROVENANCE_REPO/Pensieve/Vendor/qube-ffi/release"
printf '%s\n' '0.0.0' >"$PROVENANCE_REPO/VERSION"
cat >"$PROVENANCE_REPO/Pensieve/Package.swift" <<'SWIFT'
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "Fixture",
  targets: [.target(name: "Fixture", path: "Sources")]
)
SWIFT
printf '%s\n' '{"pins":[],"version":2}' >"$PROVENANCE_REPO/Pensieve/Package.resolved"
printf '%s\n' '// committed product source' >"$PROVENANCE_REPO/Pensieve/Sources/Fixture.swift"
printf '%s\n' 'resource' >"$PROVENANCE_REPO/Pensieve/Resources/Fixture.txt"
/usr/bin/plutil -create xml1 -- \
  "$PROVENANCE_REPO/Pensieve/Resources/Pensieve.entitlements"
/usr/libexec/PlistBuddy \
  -c 'Add :com.apple.security.device.audio-input bool true' \
  "$PROVENANCE_REPO/Pensieve/Resources/Pensieve.entitlements" >/dev/null
printf '%s\n' '# package script fixture' >"$PROVENANCE_REPO/Pensieve/scripts/fixture.sh"
printf '%s\n' '# release recipe fixture' >"$PROVENANCE_REPO/scripts/build-release.sh"
/bin/cp "$SCRIPT_DIR/lib/build-provenance.sh" \
  "$PROVENANCE_REPO/scripts/lib/build-provenance.sh"
printf '%s\n' '# bundle identity recipe fixture' \
  >"$PROVENANCE_REPO/scripts/lib/bundle-identity.sh"
printf '%s\n' '# rpath recipe fixture' >"$PROVENANCE_REPO/scripts/lib/rpath-hygiene.sh"
printf '%s\n' 'int ffi_input(void) { return 1; }' \
  | /usr/bin/clang -dynamiclib -x c \
    -o "$PROVENANCE_REPO/Pensieve/Vendor/qube-ffi/release/libqube_ffi.dylib" - \
  || fail "could not compile the runtime-input FFI fixture"
/usr/bin/git -C "$PROVENANCE_REPO" init -q
/usr/bin/git -C "$PROVENANCE_REPO" add .
/usr/bin/git -C "$PROVENANCE_REPO" \
  -c user.name='Pensieve Fixture' \
  -c user.email='fixture@invalid.example' \
  -c commit.gpgsign=false \
  commit -q -m 'fixture source'
SOURCE_COMMIT="$(/usr/bin/git -C "$PROVENANCE_REPO" rev-parse HEAD)"
make_source_fixture
/bin/mkdir -p "$OWNER_ROOT"

# Pin the dependency-checkout boundary itself. Git status is intentionally
# blind to assume-unchanged entries; the provenance helper must still compare
# compiler-visible bytes and symlink targets with the exact tree objects.
DEPENDENCY_CHECKOUT="$FIXTURE_ROOT/dependency-checkout"
/bin/mkdir -p "$DEPENDENCY_CHECKOUT"
printf '%s\n' 'committed dependency bytes' >"$DEPENDENCY_CHECKOUT/source.swift"
/bin/ln -s source.swift "$DEPENDENCY_CHECKOUT/current.swift"
/usr/bin/git -C "$DEPENDENCY_CHECKOUT" init -q
/usr/bin/git -C "$DEPENDENCY_CHECKOUT" add .
/usr/bin/git -C "$DEPENDENCY_CHECKOUT" \
  -c user.name='Pensieve Fixture' \
  -c user.email='fixture@invalid.example' \
  -c commit.gpgsign=false \
  commit -q -m 'dependency fixture'
build_provenance_git_checkout_digest "$DEPENDENCY_CHECKOUT" >/dev/null \
  || fail "a clean dependency checkout failed exact-byte provenance"
/usr/bin/git -C "$DEPENDENCY_CHECKOUT" update-index --assume-unchanged source.swift
printf '%s\n' 'hidden replacement bytes' >"$DEPENDENCY_CHECKOUT/source.swift"
if build_provenance_git_checkout_digest "$DEPENDENCY_CHECKOUT" >/dev/null 2>&1; then
  fail "dependency bytes hidden by assume-unchanged passed exact checkout provenance"
fi
/usr/bin/git -C "$DEPENDENCY_CHECKOUT" update-index --no-assume-unchanged source.swift
/usr/bin/git -C "$DEPENDENCY_CHECKOUT" checkout -q -- source.swift
/usr/bin/git -C "$DEPENDENCY_CHECKOUT" update-index --assume-unchanged current.swift
/bin/rm "$DEPENDENCY_CHECKOUT/current.swift"
/bin/ln -s missing.swift "$DEPENDENCY_CHECKOUT/current.swift"
if build_provenance_git_checkout_digest "$DEPENDENCY_CHECKOUT" >/dev/null 2>&1; then
  fail "dependency symlink hidden by assume-unchanged passed exact checkout provenance"
fi
/usr/bin/git -C "$DEPENDENCY_CHECKOUT" update-index --no-assume-unchanged current.swift
/usr/bin/git -C "$DEPENDENCY_CHECKOUT" checkout -q -- current.swift
pass "dependency checkout provenance ignores Git clean bits and seals real bytes and symlinks"

isolated_app_assert_supported_source_bundle "$SOURCE_APP" \
  || fail "the canonical non-sandboxed source shape was rejected"

WRONG_SOURCE_ID_APP="$FIXTURE_ROOT/wrong-source-id.app"
/usr/bin/ditto "$SOURCE_APP" "$WRONG_SOURCE_ID_APP"
isolated_app_plist_set_string \
  "$WRONG_SOURCE_ID_APP/Contents/Info.plist" CFBundleIdentifier \
  io.vetcoders.pensieve.manual.r00000000000000000000000000000000
/usr/bin/codesign --force --sign - --timestamp=none --options runtime \
  "$WRONG_SOURCE_ID_APP" >/dev/null 2>&1
if isolated_app_assert_supported_source_bundle "$WRONG_SOURCE_ID_APP" \
  >/dev/null 2>&1; then
  fail "an already rewritten smoke identity was accepted as a source bundle"
fi

SANDBOX_SOURCE_APP="$FIXTURE_ROOT/sandbox-source.app"
SANDBOX_ENTITLEMENTS="$FIXTURE_ROOT/sandbox-entitlements.plist"
/usr/bin/ditto "$SOURCE_APP" "$SANDBOX_SOURCE_APP"
/usr/bin/plutil -create xml1 -- "$SANDBOX_ENTITLEMENTS"
/usr/libexec/PlistBuddy -c 'Add :com.apple.security.app-sandbox bool true' \
  "$SANDBOX_ENTITLEMENTS" >/dev/null
/usr/bin/codesign --force --sign - --timestamp=none --options runtime \
  --entitlements "$SANDBOX_ENTITLEMENTS" \
  "$SANDBOX_SOURCE_APP/Contents/MacOS/Pensieve" >/dev/null 2>&1
/usr/bin/codesign --force --sign - --timestamp=none --options runtime \
  --entitlements "$SANDBOX_ENTITLEMENTS" "$SANDBOX_SOURCE_APP" >/dev/null 2>&1
SANDBOX_ACTUAL_ENTITLEMENTS="$FIXTURE_ROOT/sandbox-actual-entitlements.plist"
/usr/bin/codesign -d --entitlements :- \
  "$SANDBOX_SOURCE_APP/Contents/MacOS/Pensieve" \
  >"$SANDBOX_ACTUAL_ENTITLEMENTS" 2>/dev/null \
  || fail "could not read the sandbox fixture's actual main-executable entitlements"
[[ "$(/usr/libexec/PlistBuddy \
  -c 'Print :com.apple.security.app-sandbox' "$SANDBOX_ACTUAL_ENTITLEMENTS")" == "true" ]] \
  || fail "the sandbox fixture main executable was not actually sandboxed"
if isolated_app_assert_supported_source_bundle "$SANDBOX_SOURCE_APP" \
  >/dev/null 2>&1; then
  fail "a sandboxed App Store source was accepted by the Developer ID cleanup lane"
fi
pass "source staging accepts only canonical non-sandboxed Pensieve product bundles"

# An ad-hoc or foreign source is rejected before any historical/dirty override
# can be considered. Self-integrity is tested independently so CI does not need
# access to the operator's Developer ID key.
isolated_app_verify_embedded_provenance "$SOURCE_APP" \
  || fail "self-consistent embedded provenance was rejected"
if isolated_app_assert_source_provenance \
  "$PROVENANCE_REPO" "$SOURCE_APP" 1 1 >/dev/null 2>&1; then
  fail "an ad-hoc source passed the fixed TeamIdentifier gate"
fi
pass "source provenance rejects ad-hoc/foreign signing before all overrides"

MISSING_MANIFEST_APP="$FIXTURE_ROOT/missing-manifest.app"
/usr/bin/ditto "$SOURCE_APP" "$MISSING_MANIFEST_APP"
/bin/rm -f "$(build_provenance_bundle_manifest_path "$MISSING_MANIFEST_APP")"
if isolated_app_verify_embedded_provenance "$MISSING_MANIFEST_APP" >/dev/null 2>&1; then
  fail "a source without embedded provenance passed self-integrity"
fi
pass "missing embedded provenance is never accepted"

WRONG_PAYLOAD_APP="$FIXTURE_ROOT/wrong-payload.app"
/usr/bin/ditto "$SOURCE_APP" "$WRONG_PAYLOAD_APP"
printf '%s\n' 'int main(void) { return 9; }' \
  | /usr/bin/clang -x c -o "$WRONG_PAYLOAD_APP/Contents/MacOS/Pensieve" - \
  || fail "could not replace the copied executable fixture"
if isolated_app_verify_embedded_provenance "$WRONG_PAYLOAD_APP" >/dev/null 2>&1; then
  fail "copied provenance accepted different executable bytes"
fi
pass "copied provenance cannot authenticate a different executable"

NORMALIZED_BEFORE="$(build_provenance_normalized_macho_digest \
  "$SOURCE_APP/Contents/MacOS/Pensieve")"
NORMALIZED_APP="$FIXTURE_ROOT/normalized-rename.app"
/usr/bin/ditto "$SOURCE_APP" "$NORMALIZED_APP"
/bin/mv "$NORMALIZED_APP/Contents/MacOS/Pensieve" \
  "$NORMALIZED_APP/Contents/MacOS/PensieveRenamed"
isolated_app_plist_set_string \
  "$NORMALIZED_APP/Contents/Info.plist" CFBundleExecutable PensieveRenamed
/usr/bin/codesign --force --sign - --timestamp=none --options runtime \
  --entitlements "$SOURCE_ENTITLEMENTS" \
  "$NORMALIZED_APP/Contents/MacOS/PensieveRenamed" >/dev/null 2>&1
/usr/bin/codesign --force --sign - --timestamp=none --options runtime \
  --entitlements "$SOURCE_ENTITLEMENTS" "$NORMALIZED_APP" >/dev/null 2>&1
NORMALIZED_AFTER="$(build_provenance_normalized_macho_digest \
  "$NORMALIZED_APP/Contents/MacOS/PensieveRenamed")"
[[ "$NORMALIZED_BEFORE" == "$NORMALIZED_AFTER" ]] \
  || fail "identity rename/re-sign changed the normalized payload digest"
isolated_app_verify_embedded_provenance "$NORMALIZED_APP" \
  || fail "embedded provenance did not survive identity rename/re-sign"
pass "normalized payload provenance survives executable rename and re-signing"

TRUSTED_SIGNING_IDENTITY="$(/usr/bin/security find-identity -v -p codesigning 2>/dev/null \
  | /usr/bin/awk -F'"' -v team="($ISOLATED_APP_TRUSTED_TEAM_IDENTIFIER)" \
    'index($0, team) && /Developer ID Application:/ { print $2; exit }')"
if [[ "${PENSIEVE_TEST_FORCE_CERTLESS:-0}" == "1" ]]; then
  # The cleanup/profile assertions deliberately have no certificate dependency.
  # This test-only lane keeps them runnable on a developer machine that happens
  # to have a Developer ID identity while provenance/staging is reviewed apart.
  TRUSTED_SIGNING_IDENTITY=""
fi
if [[ -n "$TRUSTED_SIGNING_IDENTITY" ]]; then
  sign_source_fixture "$TRUSTED_SIGNING_IDENTITY"
  [[ "$(isolated_app_assert_source_provenance \
    "$PROVENANCE_REPO" "$SOURCE_APP")" == "$SOURCE_COMMIT" ]] \
    || fail "current clean trusted source provenance was rejected"
  pass "source provenance accepts the current clean trusted runtime input set"

  DEVELOPER_TO_ADHOC_APP="$FIXTURE_ROOT/normalized-developer-to-adhoc.app"
  DEVELOPER_NORMALIZED_BEFORE="$(build_provenance_normalized_macho_digest \
    "$SOURCE_APP/Contents/MacOS/Pensieve")"
  /usr/bin/ditto "$SOURCE_APP" "$DEVELOPER_TO_ADHOC_APP"
  /bin/mv "$DEVELOPER_TO_ADHOC_APP/Contents/MacOS/Pensieve" \
    "$DEVELOPER_TO_ADHOC_APP/Contents/MacOS/PensieveIsolated"
  isolated_app_plist_set_string \
    "$DEVELOPER_TO_ADHOC_APP/Contents/Info.plist" \
    CFBundleExecutable PensieveIsolated
  isolated_app_plist_set_string \
    "$DEVELOPER_TO_ADHOC_APP/Contents/Info.plist" \
    CFBundleIdentifier io.vetcoders.pensieve.manual.normalization
  /usr/bin/codesign --force --sign - --preserve-metadata=entitlements,flags,runtime \
    "$DEVELOPER_TO_ADHOC_APP" >/dev/null 2>&1 \
    || fail "could not ad-hoc re-sign the Developer ID normalization fixture"
  DEVELOPER_NORMALIZED_AFTER="$(build_provenance_normalized_macho_digest \
    "$DEVELOPER_TO_ADHOC_APP/Contents/MacOS/PensieveIsolated")"
  [[ "$DEVELOPER_NORMALIZED_BEFORE" == "$DEVELOPER_NORMALIZED_AFTER" ]] \
    || fail "Developer ID to ad-hoc re-signing changed the normalized payload digest"
  isolated_app_verify_embedded_provenance "$DEVELOPER_TO_ADHOC_APP" staged \
    || fail "embedded provenance did not survive Developer ID to ad-hoc re-signing"
  pass "normalized payload provenance survives Developer ID to ad-hoc re-signing"

  printf '%s\n' '// harness-only change' >"$PROVENANCE_REPO/scripts/ui-smoke.sh"
  [[ "$(isolated_app_assert_source_provenance \
    "$PROVENANCE_REPO" "$SOURCE_APP")" == "$SOURCE_COMMIT" ]] \
    || fail "harness-only dirt incorrectly invalidated runtime provenance"
  pass "harness-only dirt is outside the runtime-input freshness boundary"

  printf '%s\n' '// exact dirty runtime bytes' \
    >>"$PROVENANCE_REPO/Pensieve/Sources/Fixture.swift"
  refresh_source_provenance
  if isolated_app_assert_source_provenance \
    "$PROVENANCE_REPO" "$SOURCE_APP" >/dev/null 2>&1; then
    fail "dirty exact runtime bytes passed without the dirty override"
  fi
  [[ "$(isolated_app_assert_source_provenance \
    "$PROVENANCE_REPO" "$SOURCE_APP" 0 1 2>/dev/null)" == "$SOURCE_COMMIT" ]] \
    || fail "dirty override rejected the exact bytes sealed in the app"
  pass "dirty current bytes require an override and still match the sealed digest"

  /usr/bin/git -C "$PROVENANCE_REPO" checkout -q -- Pensieve/Sources/Fixture.swift
  if isolated_app_assert_source_provenance \
    "$PROVENANCE_REPO" "$SOURCE_APP" 0 1 >/dev/null 2>&1; then
    fail "a dirty-built artifact passed after the worktree returned to clean bytes"
  fi
  pass "dirty-build to clean-tree drift is rejected even with dirty override"

  refresh_source_provenance

  /usr/bin/git -C "$PROVENANCE_REPO" update-index \
    --assume-unchanged Pensieve/Sources/Fixture.swift
  printf '%s\n' '// mutation hidden from git status' \
    >>"$PROVENANCE_REPO/Pensieve/Sources/Fixture.swift"
  refresh_source_provenance
  if isolated_app_assert_source_provenance \
    "$PROVENANCE_REPO" "$SOURCE_APP" >/dev/null 2>&1; then
    fail "an assume-unchanged runtime mutation passed without the dirty override"
  fi
  [[ "$(isolated_app_assert_source_provenance \
    "$PROVENANCE_REPO" "$SOURCE_APP" 0 1 2>/dev/null)" == "$SOURCE_COMMIT" ]] \
    || fail "dirty override rejected exact runtime bytes hidden by assume-unchanged"
  HISTORICAL_DIRTY_APP="$FIXTURE_ROOT/historical-dirty.app"
  /usr/bin/ditto "$SOURCE_APP" "$HISTORICAL_DIRTY_APP"
  /usr/bin/git -C "$PROVENANCE_REPO" update-index \
    --no-assume-unchanged Pensieve/Sources/Fixture.swift
  /usr/bin/git -C "$PROVENANCE_REPO" checkout -q -- Pensieve/Sources/Fixture.swift
  refresh_source_provenance
  pass "byte-level provenance catches runtime mutations hidden by Git status"

  HISTORICAL_SOURCE_COMMIT="$SOURCE_COMMIT"
  printf '%s\n' '// committed runtime input after the source artifact' \
    >>"$PROVENANCE_REPO/Pensieve/Sources/Fixture.swift"
  /usr/bin/git -C "$PROVENANCE_REPO" add Pensieve/Sources/Fixture.swift
  /usr/bin/git -C "$PROVENANCE_REPO" \
    -c user.name='Pensieve Fixture' \
    -c user.email='fixture@invalid.example' \
    -c commit.gpgsign=false \
    commit -q -m 'newer fixture source'
  if isolated_app_assert_source_provenance \
    "$PROVENANCE_REPO" "$SOURCE_APP" >/dev/null 2>&1; then
    fail "a historical source artifact passed without the historical override"
  fi
  [[ "$(isolated_app_assert_source_provenance \
    "$PROVENANCE_REPO" "$SOURCE_APP" 1 0 2>/dev/null)" \
    == "$HISTORICAL_SOURCE_COMMIT" ]] \
    || fail "historical override rejected a self-consistent older source artifact"
  pass "historical override applies only to a real commit mismatch"
  if isolated_app_assert_source_provenance \
    "$PROVENANCE_REPO" "$HISTORICAL_DIRTY_APP" 1 1 >/dev/null 2>&1; then
    fail "historical override accepted an artifact not exact to its recorded commit"
  fi
  pass "historical dirty artifacts are rejected even with every override"

  SOURCE_COMMIT="$(/usr/bin/git -C "$PROVENANCE_REPO" rev-parse HEAD)"
  isolated_app_plist_set_string \
    "$SOURCE_APP/Contents/Info.plist" PensieveBuildCommit "$SOURCE_COMMIT"
  refresh_source_provenance
else
  pass "trusted-team success lane skipped because CI has no Developer ID identity"
fi

BUNDLE_ID="$(isolated_app_generate_bundle_id manual)" \
  || fail "could not generate a manual identity"
SECOND_BUNDLE_ID="$(isolated_app_generate_bundle_id manual)" \
  || fail "could not generate a second manual identity"
[[ "$BUNDLE_ID" != "$SECOND_BUNDLE_ID" ]] \
  || fail "two isolated runs reused the same bundle identifier"
[[ "$BUNDLE_ID" == io.vetcoders.pensieve.manual.r* \
  && "$SECOND_BUNDLE_ID" == io.vetcoders.pensieve.manual.r* ]] \
  || fail "manual identities do not use the owned lane prefix"
pass "each invocation mints a distinct run-owned bundle identifier"

# Cleanup safety and daemon-race coverage must run on certificate-free CI too.
# Only source-team authentication and full manifest staging need Developer ID.
run_certless_cleanup_tests

KEYCHAIN_SERVICE="$BUNDLE_ID.completion-provider"
DISPLAY_NAME="Pensieve Manual Synthetic"
ISOLATED_APP_SIGNING_IDENTITY="-"

if [[ -z "$TRUSTED_SIGNING_IDENTITY" ]]; then
  printf '[isolated-app test SKIP] trusted source staging lane needs Developer ID\n'
  printf '[isolated-app test] all certificate-free synthetic checks passed\n'
  exit 0
fi

isolated_app_reserve_manifest \
  "$MANIFEST" "$OWNER_ROOT" "$SOURCE_APP" "$STAGED_APP" "$EXECUTABLE_NAME" \
  "$BUNDLE_ID" "$DISPLAY_NAME" "$SUPPORT_DIR" "$KEYCHAIN_SERVICE" "$SOURCE_COMMIT" \
  || fail "could not reserve cleanup authority before synthetic staging"
isolated_app_validate_reservation "$MANIFEST" "$OWNER_ROOT" \
  || fail "synthetic cleanup reservation did not validate"
if isolated_app_verify_bundle_from_manifest "$MANIFEST" "$OWNER_ROOT" \
  >/dev/null 2>&1; then
  fail "pre-staging reservation was accepted as launch authority"
fi
/bin/mkdir "$SUPPORT_DIR"
isolated_app_stage_bundle \
  "$SOURCE_APP" "$STAGED_APP" "$EXECUTABLE_NAME" "$BUNDLE_ID" "$EXECUTABLE_NAME" \
  "$DISPLAY_NAME" "$SUPPORT_DIR" "$KEYCHAIN_SERVICE" "$PROVENANCE_REPO" 0 0 \
  || fail "staging the synthetic fixture failed"

STAGED_PLIST="$STAGED_APP/Contents/Info.plist"
assert_plist_value "$STAGED_PLIST" CFBundleExecutable "$EXECUTABLE_NAME"
assert_plist_value "$STAGED_PLIST" CFBundleIdentifier "$BUNDLE_ID"
assert_plist_value "$STAGED_PLIST" CFBundleName "$EXECUTABLE_NAME"
assert_plist_value "$STAGED_PLIST" CFBundleDisplayName "$DISPLAY_NAME"
assert_plist_value "$STAGED_PLIST" LSEnvironment.PENSIEVE_SUPPORT_DIR "$SUPPORT_DIR"
assert_plist_value \
  "$STAGED_PLIST" LSEnvironment.PENSIEVE_KEYCHAIN_SERVICE "$KEYCHAIN_SERVICE"
[[ -x "$STAGED_APP/Contents/MacOS/$EXECUTABLE_NAME" ]] \
  || fail "renamed executable is missing"
[[ ! -e "$STAGED_APP/Contents/MacOS/Pensieve" ]] \
  || fail "the old executable name survived staging"
/usr/bin/codesign --verify --deep --strict "$STAGED_APP" >/dev/null 2>&1 \
  || fail "the staged fixture did not pass strict signature verification"
[[ "$(codesign_entitlements_json "$STAGED_APP")" \
  == "$(codesign_entitlements_json "$SOURCE_APP")" ]] \
  || fail "staging did not preserve the source entitlements"
assert_hardened_runtime "$SOURCE_APP" || fail "source fixture has no hardened runtime flag"
assert_hardened_runtime "$STAGED_APP" || fail "staging dropped the hardened runtime flag"
pass "identity and environment were rewritten while entitlements and hardened runtime were preserved"

/usr/bin/plutil -replace CFBundleDisplayName -string 'Mismatched Reservation Display' \
  -- "$STAGED_PLIST"
if isolated_app_finalize_manifest "$MANIFEST" "$OWNER_ROOT" >/dev/null 2>&1; then
  fail "finalization accepted a staged bundle whose coordinates differ from its reservation"
fi
isolated_app_validate_reservation "$MANIFEST" "$OWNER_ROOT" \
  || fail "failed finalization damaged the authoritative reservation"
[[ ! -e "$(isolated_app_manifest_partial_path "$MANIFEST" final)" ]] \
  || fail "failed finalization left a partial full manifest"
/usr/bin/plutil -replace CFBundleDisplayName -string "$DISPLAY_NAME" -- "$STAGED_PLIST"
isolated_app_sign_bundle "$STAGED_APP" \
  || fail "could not restore the staged signature after mismatch testing"
isolated_app_finalize_manifest "$MANIFEST" "$OWNER_ROOT" \
  || fail "could not atomically finalize the synthetic identity manifest"
[[ "$(isolated_app_manifest_value "$MANIFEST" manifestState)" == "finalized" ]] \
  || fail "finalized cleanup authority still advertises reservation state"
isolated_app_verify_bundle_from_manifest "$MANIFEST" "$OWNER_ROOT" \
  || fail "manifest verification rejected the correctly staged fixture"
pass "identity.plist finalizes only after the staged bundle matches and authenticates"

LEGACY_MANIFEST="$OWNER_ROOT/legacy-schema-3.plist"
/bin/cp -p -- "$MANIFEST" "$LEGACY_MANIFEST"
/usr/bin/plutil -replace schemaVersion -integer 3 -- "$LEGACY_MANIFEST"
/usr/bin/plutil -remove manifestState -- "$LEGACY_MANIFEST"
if isolated_app_verify_bundle_from_manifest "$LEGACY_MANIFEST" "$OWNER_ROOT" \
  >/dev/null 2>&1; then
  fail "legacy single-phase schema was accepted as launch authority"
fi
/bin/rm -f -- "$LEGACY_MANIFEST"
pass "only the schema-4 finalized state can authorize launch"

MANIFEST_SOURCE_MAIN="$(isolated_app_manifest_value \
  "$MANIFEST" sourceMainExecutableNormalizedSHA256)"
/usr/bin/plutil -replace sourceMainExecutableNormalizedSHA256 \
  -string '0000000000000000000000000000000000000000000000000000000000000000' \
  -- "$MANIFEST"
if isolated_app_verify_bundle_from_manifest "$MANIFEST" "$OWNER_ROOT" \
  >/dev/null 2>&1; then
  fail "finalized manifest accepted a tampered source payload digest"
fi
/usr/bin/plutil -replace sourceMainExecutableNormalizedSHA256 \
  -string "$MANIFEST_SOURCE_MAIN" -- "$MANIFEST"
isolated_app_verify_bundle_from_manifest "$MANIFEST" "$OWNER_ROOT" \
  || fail "restored finalized manifest did not verify"
pass "finalized manifest tampering is rejected before runtime"

if isolated_app_assert_nonproduction_id "$ISOLATED_APP_PRODUCTION_BUNDLE_ID" \
  >/dev/null 2>&1; then
  fail "production bundle identifier passed the hard guard"
fi
if isolated_app_assert_owned_id "io.vetcoders.pensieve.manual.not-a-run-token" \
  >/dev/null 2>&1; then
  fail "an arbitrary non-production prefix lookalike passed the ownership guard"
fi
if isolated_app_assert_keychain_service \
  "$BUNDLE_ID" "$ISOLATED_APP_PRODUCTION_KEYCHAIN_SERVICE" >/dev/null 2>&1; then
  fail "the production Keychain service passed an isolated identity guard"
fi
PRODUCTION_TARGET="$OWNER_ROOT/ProductionTarget.app"
if isolated_app_stage_bundle \
  "$SOURCE_APP" "$PRODUCTION_TARGET" ProductFixture "$ISOLATED_APP_PRODUCTION_BUNDLE_ID" \
  ProductFixture ProductFixture "$SUPPORT_DIR" "$ISOLATED_APP_PRODUCTION_KEYCHAIN_SERVICE" \
  >/dev/null 2>&1; then
  fail "stage_bundle accepted the production identity"
fi
[[ ! -e "$PRODUCTION_TARGET" ]] \
  || fail "production guard ran only after creating a target bundle"
pass "production and unowned identities are rejected before staging mutates the destination"

OUTSIDE_SUPPORT="$FIXTURE_ROOT/outside/state"
OUTSIDE_TARGET="$OWNER_ROOT/OutsideOwner.app"
OUTSIDE_ID="$(isolated_app_generate_bundle_id smoke)"
if isolated_app_stage_bundle \
  "$SOURCE_APP" "$OUTSIDE_TARGET" OutsideOwner \
  "$OUTSIDE_ID" OutsideOwner OutsideOwner \
  "$OUTSIDE_SUPPORT" "$OUTSIDE_ID.completion-provider" \
  >/dev/null 2>&1; then
  fail "stage_bundle accepted a support directory outside the bundle owner"
fi
[[ ! -e "$OUTSIDE_TARGET" ]] \
  || fail "owner-parent guard ran only after creating a target bundle"
pass "bundle and support roots must share one isolated owner directory"

WRONG_OWNER="$FIXTURE_ROOT/wrong-owner"
if isolated_app_cleanup_identity \
  "$BUNDLE_ID" "$STAGED_APP" "$SUPPORT_DIR" "$KEYCHAIN_SERVICE" "$WRONG_OWNER" \
  >/dev/null 2>&1; then
  fail "cleanup_identity accepted paths outside its required owner root"
fi
[[ -d "$STAGED_APP" ]] \
  || fail "owner-root guard ran only after cleanup mutated the staged bundle"
pass "cleanup requires the exact isolated owner root before any mutation"

/bin/mkdir -p "${STAGED_APP%.app}.partial.app"
printf 'interrupted reservation\n' \
  >"$(isolated_app_manifest_partial_path "$MANIFEST" reservation)"
printf 'interrupted finalization\n' \
  >"$(isolated_app_manifest_partial_path "$MANIFEST" final)"
isolated_app_cleanup_manifest "$MANIFEST" "$OWNER_ROOT" \
  || fail "successful manifested cleanup failed"
[[ ! -e "$STAGED_APP" && ! -e "${STAGED_APP%.app}.partial.app" \
  && ! -e "$SUPPORT_DIR" && ! -e "$MANIFEST" \
  && ! -e "$(isolated_app_manifest_partial_path "$MANIFEST" reservation)" \
  && ! -e "$(isolated_app_manifest_partial_path "$MANIFEST" final)" ]] \
  || fail "manifested cleanup left owned bundle/profile artifacts"
pass "manifested cleanup retires its exact owned capsule and partial staging path"

HOST_HEAD_AFTER="$(/usr/bin/git -C "$HOST_REPO_ROOT" rev-parse HEAD)"
HOST_STATUS_AFTER="$(
  /usr/bin/git -C "$HOST_REPO_ROOT" status --porcelain=v1 --untracked-files=all
)"
[[ "$HOST_HEAD_AFTER" == "$HOST_HEAD_BEFORE" ]] \
  || fail "fixture Git commands moved the host repository HEAD"
[[ "$HOST_STATUS_AFTER" == "$HOST_STATUS_BEFORE" ]] \
  || fail "fixture Git commands changed the host repository worktree or index"
pass "fixture Git repositories cannot mutate the host repository"

printf '[isolated-app test] all synthetic checks passed\n'
