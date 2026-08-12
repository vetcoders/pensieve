#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
rule="$repo_root/.semgrep/native-test-window-presentation.yml"
fixture="$repo_root/scripts/fixtures/semgrep/native-test-window-presentation"
scratch="$(mktemp -d -t pensieve-semgrep-native-window.XXXXXX)"
report="$scratch/report.json"
source_report="$scratch/source-report.json"
trap 'rm -rf "$scratch"' EXIT

if ! command -v semgrep >/dev/null 2>&1; then
  printf '[fail] semgrep is required to test the native-window presentation contract.\n' >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  printf '[fail] jq is required to test the native-window presentation contract.\n' >&2
  exit 1
fi

cp -R "$fixture/." "$scratch/"
(
  cd "$scratch"
  semgrep scan --config "$rule" --quiet --json . >"$report"
)

error_count="$(jq -r '.errors | length' "$report")"
if [[ "$error_count" -ne 0 ]]; then
  jq -r '.errors[] | "\(.path // "<unknown>"): \(.message // .type // "Semgrep error")"' "$report" >&2
  printf '[fail] Native-window contract fixture produced %s Semgrep error(s).\n' "$error_count" >&2
  exit 1
fi

expected_count=30
actual_count="$(jq -r '.results | length' "$report")"
if [[ "$actual_count" -ne "$expected_count" ]]; then
  jq -r '.results[] | "\(.path):\(.start.line): \(.check_id)"' "$report" >&2
  printf '[fail] Expected %s forbidden native-window publications/calls, found %s.\n' \
    "$expected_count" "$actual_count" >&2
  exit 1
fi

unexpected_result="$(jq -r '
  .results[]
  | select(
      (
        .check_id
        | endswith("pensieve.tests.native-window-presentation")
          or endswith("pensieve.tests.tafla-panel-requires-injected-factory")
        | not
      )
      or .path != "Pensieve/Tests/PensieveTests/ForbiddenNativePresentation.swift"
    )
  | "\(.path):\(.start.line): \(.check_id)"
' "$report")"
if [[ -n "$unexpected_result" ]]; then
  printf '%s\n' "$unexpected_result" >&2
  printf '[fail] Native-window contract matched an allowed fixture or the wrong rule.\n' >&2
  exit 1
fi

native_count="$(jq -r '[.results[] | select(.check_id | endswith("pensieve.tests.native-window-presentation"))] | length' "$report")"
tafla_count="$(jq -r '[.results[] | select(.check_id | endswith("pensieve.tests.tafla-panel-requires-injected-factory"))] | length' "$report")"
if [[ "$native_count" -ne 26 || "$tafla_count" -ne 4 ]]; then
  jq -r '.results[] | "\(.path):\(.start.line): \(.check_id)"' "$report" >&2
  printf '[fail] Expected 26 presentation findings and 4 unsafe-Tafla findings; got %s and %s.\n' \
    "$native_count" "$tafla_count" >&2
  exit 1
fi

(
  cd "$repo_root"
  semgrep scan --config "$rule" --quiet --json \
    Pensieve/Tests/PensieveTests/TranscriptionTaflaPanelTests.swift >"$source_report"
)

source_error_count="$(jq -r '.errors | length' "$source_report")"
if [[ "$source_error_count" -ne 0 ]]; then
  jq -r '.errors[] | "\(.path // "<unknown>"): \(.message // .type // "Semgrep error")"' \
    "$source_report" >&2
  printf '[fail] The real Tafla test produced %s native-window contract Semgrep error(s).\n' \
    "$source_error_count" >&2
  exit 1
fi

source_result_count="$(jq -r '.results | length' "$source_report")"
if [[ "$source_result_count" -ne 0 ]]; then
  jq -r '.results[] | "\(.path):\(.start.line): \(.check_id)"' "$source_report" >&2
  printf '[fail] The real Tafla test contains %s forbidden native-window contract violation(s).\n' \
    "$source_result_count" >&2
  exit 1
fi

source_violation="$(
  rg -n \
    --glob '*.swift' \
    --glob '!**/.build/**' \
    --glob '!**/DerivedData/**' \
    'defer:[[:space:]]*false|NS(Window|Panel)[[:space:]]*\([[:space:]]*\)|makeKeyAndOrderFront[[:space:]]*\(|orderFront[[:space:]]*\(|orderFrontRegardless[[:space:]]*\(|\.order[[:space:]]*\(|showWindow[[:space:]]*\(|beginSheet[[:space:]]*\(|beginCriticalSheet[[:space:]]*\(|beginSheetModal[[:space:]]*\(|presentAsSheet[[:space:]]*\(|presentAsModalWindow[[:space:]]*\(|presentViewControllerAsSheet[[:space:]]*\(|presentViewControllerAsModalWindow[[:space:]]*\(|presentViewControllerAsPopover[[:space:]]*\(|presentAsPopover[[:space:]]*\(|addChildWindow[[:space:]]*\(|addTabbedWindow[[:space:]]*\(|setIsVisible[[:space:]]*\([[:space:]]*true[[:space:]]*\)|isVisible[[:space:]]*=[[:space:]]*true|runModal[[:space:]]*\(|NSApplication\.shared\.activate[[:space:]]*\(|NSApp\.activate[[:space:]]*\(' \
    "$repo_root/Pensieve/Tests" \
    || true
)"
if [[ -n "$source_violation" ]]; then
  printf '%s\n' "$source_violation" >&2
  printf '[fail] Tests contain a forbidden native-window publication token.\n' >&2
  exit 1
fi

printf '[ok] Native-window Semgrep contract caught %s forbidden publications/calls and ignored allowed fixtures.\n' \
  "$actual_count"
printf '[ok] The real Tafla test passed the complete injected-lifecycle Semgrep contract.\n'
printf '[ok] Source census found no forbidden native-window publication tokens in Pensieve/Tests.\n'
