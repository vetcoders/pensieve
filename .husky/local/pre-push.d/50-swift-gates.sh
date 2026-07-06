#!/usr/bin/env bash
# pensieve :: pre-push local extension — Swift gates
#
# The hooks-template auto-detection classified this repo as "Languages: shell"
# (see config.env header), so no template toggle covers Swift and pushes were
# gated only by secrets + semgrep + loct cycles. This extension runs the
# repo's canonical quality gate (`make gates` = swift test + swift-format
# lint) on every push. WARN/STRICT demotion stays with husky_run_step in
# .husky/pre-push, so feature branches keep WARN semantics.
#
# Bypass (emergencies only): HUSKY_SKIP_PREPUSH=1 skips the whole pre-push.

set -euo pipefail

command -v swift >/dev/null 2>&1 || {
  echo "swift toolchain not found — cannot run 'make gates'" >&2
  exit 1
}

make gates
