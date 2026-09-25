#!/usr/bin/env bash
# Rebuild libcodescribe_ffi.dylib from the sibling codescribe checkout and
# vendor it into Pensieve, stamping Vendor/codescribe-ffi/PROVENANCE.txt so
# `make ffi-check` can compare the blob against CODESCRIBE_ROOT HEAD.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PENSIEVE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VETCODERS_ROOT="$(cd "$PENSIEVE_ROOT/../.." && pwd)"
DEFAULT_CODESCRIBE_ROOT="$VETCODERS_ROOT/codescribe"
CODESCRIBE_ROOT="${CODESCRIBE_ROOT:-$DEFAULT_CODESCRIBE_ROOT}"
FFI_PROFILE="${FFI_PROFILE:-debug}"

case "$FFI_PROFILE" in
  debug|release) ;;
  *)
    echo "error: FFI_PROFILE must be debug or release, got: $FFI_PROFILE" >&2
    exit 2
    ;;
esac

if [[ ! -f "$CODESCRIBE_ROOT/bridge/Cargo.toml" ]]; then
  echo "error: CODESCRIBE_ROOT does not point at codescribe: $CODESCRIBE_ROOT" >&2
  echo "Set CODESCRIBE_ROOT=/path/to/codescribe and rerun." >&2
  exit 1
fi

TARGET_ROOT="${CARGO_TARGET_DIR:-$CODESCRIBE_ROOT/target}"
LIB_DIR="$TARGET_ROOT/$FFI_PROFILE"
VENDOR_DIR="$PENSIEVE_ROOT/Vendor/codescribe-ffi/$FFI_PROFILE"
GENERATED_SWIFT="$PENSIEVE_ROOT/Sources/CodescribeBridge/codescribe_ffi.swift"
GENERATED_HEADER="$PENSIEVE_ROOT/Sources/codescribe_ffiFFI/codescribe_ffiFFI.h"
PROVENANCE="$PENSIEVE_ROOT/Vendor/codescribe-ffi/PROVENANCE.txt"
GEN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/pensieve-codescribe-ffi.XXXXXX")"
cleanup() {
  if [[ -n "${GEN_DIR:-}" && -d "$GEN_DIR" ]]; then
    rm -rf "$GEN_DIR"
  fi
  return 0
}
trap cleanup EXIT

echo "Building codescribe-ffi from $CODESCRIBE_ROOT ($FFI_PROFILE)"
(
  cd "$CODESCRIBE_ROOT"
  export RUSTFLAGS="${RUSTFLAGS:-} --remap-path-prefix=$HOME=/build --remap-path-prefix=$HOME/.cargo=/cargo --remap-path-prefix=$CODESCRIBE_ROOT=/codescribe"
  if [[ "$FFI_PROFILE" == "release" ]]; then
    cargo build -p codescribe-ffi --release
  else
    cargo build -p codescribe-ffi
  fi
  BINDGEN="$LIB_DIR/uniffi-bindgen"
  if [[ -x "$BINDGEN" ]]; then
    "$BINDGEN" generate \
      --library "$LIB_DIR/libcodescribe_ffi.dylib" \
      --language swift \
      --out-dir "$GEN_DIR"
  else
    cargo run -p codescribe-ffi --bin uniffi-bindgen -- generate \
      --library "$LIB_DIR/libcodescribe_ffi.dylib" \
      --language swift \
      --out-dir "$GEN_DIR"
  fi
)

if [[ ! -f "$LIB_DIR/libcodescribe_ffi.dylib" ]]; then
  echo "error: cargo did not emit $LIB_DIR/libcodescribe_ffi.dylib" >&2
  exit 1
fi
if [[ ! -f "$GEN_DIR/codescribe_ffi.swift" || ! -f "$GEN_DIR/codescribe_ffiFFI.h" ]]; then
  echo "error: uniffi-bindgen did not emit codescribe_ffi.swift / codescribe_ffiFFI.h in $GEN_DIR" >&2
  ls -la "$GEN_DIR" >&2 || true
  exit 1
fi

mkdir -p \
  "$PENSIEVE_ROOT/Sources/CodescribeBridge" \
  "$PENSIEVE_ROOT/Sources/codescribe_ffiFFI" \
  "$VENDOR_DIR"

cp "$GEN_DIR/codescribe_ffi.swift" "$GENERATED_SWIFT"
cp "$GEN_DIR/codescribe_ffiFFI.h" "$GENERATED_HEADER"
cp "$LIB_DIR/libcodescribe_ffi.dylib" "$VENDOR_DIR/libcodescribe_ffi.dylib"
install_name_tool -id "@rpath/libcodescribe_ffi.dylib" \
  "$VENDOR_DIR/libcodescribe_ffi.dylib"
codesign -f -s - "$VENDOR_DIR/libcodescribe_ffi.dylib"

if [[ ! -f "$PENSIEVE_ROOT/Sources/codescribe_ffiFFI/module.modulemap" ]]; then
  cat >"$PENSIEVE_ROOT/Sources/codescribe_ffiFFI/module.modulemap" <<'MODULEMAP'
module codescribe_ffiFFI {
  header "codescribe_ffiFFI.h"
  export *
  use "Darwin"
  use "_Builtin_stdbool"
  use "_Builtin_stdint"
}
MODULEMAP
fi

DYLIB_SHA="$(shasum -a 256 "$VENDOR_DIR/libcodescribe_ffi.dylib" | awk '{print $1}')"
cat >"$PROVENANCE" <<PROVENANCE
codescribe-root=$CODESCRIBE_ROOT
codescribe-head=$(git -C "$CODESCRIBE_ROOT" rev-parse HEAD)
codescribe-describe=$(git -C "$CODESCRIBE_ROOT" describe --always --dirty --tags)
ffi-profile=$FFI_PROFILE
dylib-sha256=$DYLIB_SHA
built-at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
host=$(hostname)
PROVENANCE

echo "Synced codescribe-ffi bindings and $FFI_PROFILE dylib into Pensieve."
echo "Wrote provenance to $PROVENANCE."
