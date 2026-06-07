#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PENSIEVE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DEFAULT_VISTA_ROOT="$(cd "$PENSIEVE_ROOT/../.." && pwd)/LibraxisAI/vista-kernel"
VISTA_KERNEL_ROOT="${VISTA_KERNEL_ROOT:-$DEFAULT_VISTA_ROOT}"

if [[ ! -d "$VISTA_KERNEL_ROOT/crates/qube-ffi" ]]; then
  echo "error: VISTA_KERNEL_ROOT does not point at vista-kernel: $VISTA_KERNEL_ROOT" >&2
  echo "Set VISTA_KERNEL_ROOT=/path/to/vista-kernel and rerun." >&2
  exit 1
fi

echo "Building qube-ffi from $VISTA_KERNEL_ROOT"
(
  cd "$VISTA_KERNEL_ROOT"
  cargo build -p qube-ffi
  cargo run -p uniffi-bindgen -- generate \
    --library target/debug/libqube_ffi.dylib \
    --language swift \
    --out-dir app/CodeScribe/Bridge
)

mkdir -p \
  "$PENSIEVE_ROOT/Sources/Pensieve/VistaBridge" \
  "$PENSIEVE_ROOT/Sources/qube_ffiFFI" \
  "$PENSIEVE_ROOT/Vendor/qube-ffi/debug"

cp "$VISTA_KERNEL_ROOT/app/CodeScribe/Bridge/qube_ffi.swift" \
  "$PENSIEVE_ROOT/Sources/Pensieve/VistaBridge/qube_ffi.swift"
cp "$VISTA_KERNEL_ROOT/app/CodeScribe/Bridge/qube_ffiFFI.h" \
  "$PENSIEVE_ROOT/Sources/qube_ffiFFI/qube_ffiFFI.h"
cp "$VISTA_KERNEL_ROOT/target/debug/libqube_ffi.dylib" \
  "$PENSIEVE_ROOT/Vendor/qube-ffi/debug/libqube_ffi.dylib"
cat >"$PENSIEVE_ROOT/Sources/qube_ffiFFI/module.modulemap" <<'MODULEMAP'
module qube_ffiFFI {
  header "qube_ffiFFI.h"
  export *
  use "Darwin"
  use "_Builtin_stdbool"
  use "_Builtin_stdint"
}
MODULEMAP

echo "Synced qube-ffi bridge and dylib into Pensieve."
