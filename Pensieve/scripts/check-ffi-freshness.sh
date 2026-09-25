#!/usr/bin/env bash
# Donor freshness for the vendored FFI dylibs.
#
# Primary: libcodescribe_ffi.dylib vs sibling ../codescribe (CODESCRIBE_ROOT).
# Optional: libqube_ffi.dylib vs vista-kernel, only when that checkout exists
# or VISTA_KERNEL_ROOT is set. A missing vista-kernel is not a warning —
# codescribe is the Ask/STT donor; qube-ffi is the leftover Vista bridge.
#
# Warn-only by default (exit 0) so CI without a sibling checkout still runs.
# FFI_CHECK_STRICT=1 fails closed on any warning (local pin enforcement).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PENSIEVE_ROOT="${PENSIEVE_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FFI_PROFILE="${FFI_PROFILE:-debug}"
FFI_CHECK_STRICT="${FFI_CHECK_STRICT:-0}"

VETCODERS_ROOT=""
VETCODERS_ROOT="$(cd "$PENSIEVE_ROOT/../.." 2>/dev/null && pwd)" || VETCODERS_ROOT=""
DEFAULT_CODESCRIBE_ROOT="${VETCODERS_ROOT:+$VETCODERS_ROOT/codescribe}"
DEFAULT_VISTA_ROOT="${VETCODERS_ROOT:+$VETCODERS_ROOT/vista-kernel}"

CODESCRIBE_ROOT="${CODESCRIBE_ROOT:-$DEFAULT_CODESCRIBE_ROOT}"

VISTA_EXPLICIT=0
if [[ -n "${VISTA_KERNEL_ROOT+x}" ]]; then
    VISTA_EXPLICIT=1
fi
VISTA_KERNEL_ROOT="${VISTA_KERNEL_ROOT:-$DEFAULT_VISTA_ROOT}"

CODESCRIBE_PROVENANCE="${CODESCRIBE_PROVENANCE:-$PENSIEVE_ROOT/Vendor/codescribe-ffi/PROVENANCE.txt}"
QUBE_PROVENANCE="${QUBE_PROVENANCE:-$PENSIEVE_ROOT/Vendor/qube-ffi/PROVENANCE.txt}"
CODESCRIBE_DYLIB="$PENSIEVE_ROOT/Vendor/codescribe-ffi/$FFI_PROFILE/libcodescribe_ffi.dylib"

WARNED=0

warn() {
    WARNED=1
    printf "\033[33m[ffi-check]\033[0m %s\n" "$*" >&2
}

ok() {
    printf "\033[32m[ffi-check]\033[0m %s\n" "$*"
}

provenance_field() {
    local file="$1" key="$2"
    awk -F= -v k="$key" '
        $1 == k {
            print substr($0, index($0, "=") + 1)
            found = 1
        }
        END { exit found ? 0 : 1 }
    ' "$file" 2>/dev/null || true
}

file_sha256() {
    local path="$1"
    if [[ ! -f "$path" ]]; then
        printf ''
        return 0
    fi
    shasum -a 256 "$path" | awk '{print $1}'
}

check_codescribe() {
    local current_head vendored_head vendored_describe vendored_sha actual_sha

    if [[ -z "$CODESCRIBE_ROOT" || ! -d "$CODESCRIBE_ROOT/.git" ]]; then
        if [[ -z "$CODESCRIBE_ROOT" ]]; then
            warn "codescribe checkout not found; set CODESCRIBE_ROOT to enable freshness checks"
        else
            warn "codescribe checkout not found at $CODESCRIBE_ROOT; set CODESCRIBE_ROOT to enable freshness checks"
        fi
        return 0
    fi

    if [[ ! -f "$CODESCRIBE_PROVENANCE" ]]; then
        warn "missing $CODESCRIBE_PROVENANCE; run Pensieve/scripts/build-codescribe-ffi.sh to stamp vendored codescribe-ffi"
        return 0
    fi

    current_head="$(git -C "$CODESCRIBE_ROOT" rev-parse HEAD)"
    vendored_head="$(provenance_field "$CODESCRIBE_PROVENANCE" "codescribe-head")"
    vendored_describe="$(provenance_field "$CODESCRIBE_PROVENANCE" "codescribe-describe")"
    vendored_sha="$(provenance_field "$CODESCRIBE_PROVENANCE" "dylib-sha256")"

    if [[ -z "$vendored_head" || "$vendored_head" == "UNSTAMPED" ]]; then
        warn "vendored codescribe-ffi is unpinned (no donor commit); run: FFI_PROFILE=$FFI_PROFILE Pensieve/scripts/build-codescribe-ffi.sh"
    elif [[ "$vendored_head" != "$current_head" ]]; then
        warn "vendored codescribe-ffi is stale: provenance $vendored_head != codescribe HEAD $current_head"
        warn "run: FFI_PROFILE=$FFI_PROFILE Pensieve/scripts/build-codescribe-ffi.sh"
    fi

    if [[ "$vendored_describe" == *-dirty ]]; then
        warn "Vendored codescribe-ffi was built from a DIRTY codescribe tree ($vendored_describe) — rebuild from a clean checkout before submitting."
    fi

    if [[ ! -f "$CODESCRIBE_DYLIB" ]]; then
        warn "missing $CODESCRIBE_DYLIB"
    elif [[ -n "$vendored_sha" ]]; then
        actual_sha="$(file_sha256 "$CODESCRIBE_DYLIB")"
        if [[ "$actual_sha" != "$vendored_sha" ]]; then
            warn "vendored codescribe-ffi dylib sha256 $actual_sha != provenance $vendored_sha"
        fi
    fi

    if [[ "$WARNED" -eq 0 ]]; then
        ok "codescribe-ffi provenance matches codescribe HEAD $current_head"
    fi
}

check_qube() {
    local current_head vendored_head vendored_describe
    local saved_warned="$WARNED"

    if [[ -z "$VISTA_KERNEL_ROOT" || ! -d "$VISTA_KERNEL_ROOT/.git" ]]; then
        if [[ "$VISTA_EXPLICIT" -eq 1 ]]; then
            if [[ -z "$VISTA_KERNEL_ROOT" ]]; then
                warn "vista-kernel checkout not found; set VISTA_KERNEL_ROOT to enable qube-ffi freshness checks"
            else
                warn "vista-kernel checkout not found at $VISTA_KERNEL_ROOT; set VISTA_KERNEL_ROOT to enable freshness checks"
            fi
        fi
        return 0
    fi

    if [[ ! -f "$QUBE_PROVENANCE" ]]; then
        warn "missing $QUBE_PROVENANCE; run Pensieve/scripts/build-ffi.sh to stamp vendored qube-ffi"
        return 0
    fi

    current_head="$(git -C "$VISTA_KERNEL_ROOT" rev-parse HEAD)"
    vendored_head="$(provenance_field "$QUBE_PROVENANCE" "vista-kernel-head")"
    vendored_describe="$(provenance_field "$QUBE_PROVENANCE" "vista-kernel-describe")"

    if [[ -z "$vendored_head" ]]; then
        warn "$QUBE_PROVENANCE does not contain vista-kernel-head; rebuild qube-ffi"
        return 0
    fi

    if [[ "$vendored_head" != "$current_head" ]]; then
        warn "vendored qube-ffi is stale: provenance $vendored_head != vista-kernel HEAD $current_head"
        warn "run: FFI_PROFILE=$FFI_PROFILE Pensieve/scripts/build-ffi.sh"
    fi

    if [[ "$vendored_describe" == *-dirty ]]; then
        warn "Vendored qube-ffi was built from a DIRTY vista-kernel tree ($vendored_describe) — its source is untraceable; rebuild from a clean vista-kernel before submitting."
    fi

    if [[ "$WARNED" -eq "$saved_warned" ]]; then
        ok "qube-ffi provenance matches vista-kernel HEAD $current_head"
    fi
}

check_codescribe
check_qube

if [[ "$FFI_CHECK_STRICT" == "1" && "$WARNED" -eq 1 ]]; then
    exit 1
fi
exit 0
