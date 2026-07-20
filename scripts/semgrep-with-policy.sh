#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
policy="$repo_root/.semgrep-policy.json"
report="$(mktemp -t pensieve-semgrep.XXXXXX)"
trap 'rm -f "$report"' EXIT

cd "$repo_root"

if git grep -n -E 'nosemgrep|nosem' -- Pensieve docs ':!Pensieve/Sources/Pensieve/Resources/*.min.js'; then
  printf '[fail] Inline Semgrep suppressions are forbidden; record reviewed exceptions in %s.\n' "$policy" >&2
  exit 1
fi

semgrep scan --config auto --quiet --json "$@" >"$report"

allowed="$(jq -c '.accepted_findings' "$policy")"
invalid_policy="$(jq -r '
  .accepted_findings[]
  | select(
      (.rule_id | type) != "string"
      or (.path | type) != "string"
      or (.max_count | type) != "number"
      or .max_count < 1
      or (.max_count | floor) != .max_count
    )
  | "\(.path // "<missing path>"): \(.rule_id // "<missing rule>") has invalid max_count"
' "$policy")"
if [[ -n "$invalid_policy" ]]; then
  printf '%s\n' "$invalid_policy" >&2
  printf '[fail] Semgrep reviewed policy is invalid.\n' >&2
  exit 1
fi

unexpected="$({
  jq -r --argjson allowed "$allowed" '
    .results[] as $result
    | select(any($allowed[]; .rule_id == $result.check_id and .path == $result.path) | not)
    | "\($result.path):\($result.start.line): \($result.check_id)"
  ' "$report"
})"

if [[ -n "$unexpected" ]]; then
  printf '%s\n' "$unexpected" >&2
  printf '[fail] Semgrep found issues outside the reviewed policy.\n' >&2
  exit 1
fi

accepted_count="$(jq -r --argjson allowed "$allowed" '
  [.results[] as $result
    | select(any($allowed[]; .rule_id == $result.check_id and .path == $result.path))]
  | length
' "$report")"
excess_policy="$(jq -r --argjson allowed "$allowed" '
  $allowed[] as $entry
  | ([.results[] | select(.check_id == $entry.rule_id and .path == $entry.path)] | length) as $count
  | select($count > $entry.max_count)
  | "\($entry.path): \($entry.rule_id) allows at most \($entry.max_count), found \($count)"
' "$report")"
if [[ -n "$excess_policy" ]]; then
  printf '%s\n' "$excess_policy" >&2
  printf '[fail] Semgrep reviewed policy exceeded its accepted finding bound.\n' >&2
  exit 1
fi
engine_warning_count="$(jq -r '.errors | length' "$report")"
printf '[ok] Semgrep passed (%s reviewed policy finding(s), %s parser warning(s)).\n' \
  "$accepted_count" "$engine_warning_count"
