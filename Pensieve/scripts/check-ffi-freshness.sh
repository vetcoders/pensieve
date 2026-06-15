#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PENSIEVE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DEFAULT_VISTA_ROOT="$HOME/vc-workspace/LibraxisAI/vista-kernel"
VISTA_KERNEL_ROOT="${VISTA_KERNEL_ROOT:-$DEFAULT_VISTA_ROOT}"
PROVENANCE="$PENSIEVE_ROOT/Vendor/qube-ffi/PROVENANCE.txt"

warn() {
  printf "\033[33m[ffi-check]\033[0m %s\n" "$*" >&2
}

if [[ ! -d "$VISTA_KERNEL_ROOT/.git" ]]; then
  warn "vista-kernel checkout not found at $VISTA_KERNEL_ROOT; set VISTA_KERNEL_ROOT to enable freshness checks"
  exit 0
fi

if [[ ! -f "$PROVENANCE" ]]; then
  warn "missing $PROVENANCE; run Pensieve/scripts/build-ffi.sh to stamp vendored qube-ffi"
  exit 0
fi

current_head="$(git -C "$VISTA_KERNEL_ROOT" rev-parse HEAD)"
vendored_head="$(
  awk -F= '$1 == "vista-kernel-head" { print $2; found = 1 } END { exit found ? 0 : 1 }' "$PROVENANCE" 2>/dev/null || true
)"

if [[ -z "$vendored_head" ]]; then
  warn "$PROVENANCE does not contain vista-kernel-head; rebuild qube-ffi"
  exit 0
fi

if [[ "$vendored_head" != "$current_head" ]]; then
  warn "vendored qube-ffi is stale: provenance $vendored_head != vista-kernel HEAD $current_head"
  warn "run: FFI_PROFILE=debug Pensieve/scripts/build-ffi.sh"
  exit 0
fi

printf "\033[32m[ffi-check]\033[0m qube-ffi provenance matches vista-kernel HEAD %s\n" "$current_head"
