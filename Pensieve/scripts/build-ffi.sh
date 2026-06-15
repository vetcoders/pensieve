#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PENSIEVE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DEFAULT_VISTA_ROOT="$HOME/vc-workspace/LibraxisAI/vista-kernel"
VISTA_KERNEL_ROOT="${VISTA_KERNEL_ROOT:-$DEFAULT_VISTA_ROOT}"
FFI_PROFILE="${FFI_PROFILE:-debug}"

case "$FFI_PROFILE" in
  debug)
    CARGO_PROFILE_ARGS=()
    ;;
  release)
    CARGO_PROFILE_ARGS=(--release)
    ;;
  *)
    echo "error: FFI_PROFILE must be debug or release, got: $FFI_PROFILE" >&2
    exit 2
    ;;
esac

if [[ ! -d "$VISTA_KERNEL_ROOT/crates/qube-ffi" ]]; then
  echo "error: VISTA_KERNEL_ROOT does not point at vista-kernel: $VISTA_KERNEL_ROOT" >&2
  echo "Set VISTA_KERNEL_ROOT=/path/to/vista-kernel and rerun." >&2
  exit 1
fi

LIB_DIR="$VISTA_KERNEL_ROOT/target/$FFI_PROFILE"
BRIDGE_DIR="$VISTA_KERNEL_ROOT/app/CodeScribe/Bridge"
VENDOR_DIR="$PENSIEVE_ROOT/Vendor/qube-ffi/$FFI_PROFILE"
GENERATED_SWIFT="$PENSIEVE_ROOT/Sources/Pensieve/VistaBridge/qube_ffi.swift"
PROVENANCE="$PENSIEVE_ROOT/Vendor/qube-ffi/PROVENANCE.txt"

patch_completion_protocol() {
  local swift_file="$1"

  if awk '
    /public protocol VistaEngineProtocol: AnyObject, Sendable \{/ { in_protocol = 1 }
    in_protocol && /func complete\(prefix: String, maxTokens: UInt32\)/ { found = 1 }
    in_protocol && /^}/ { in_protocol = 0 }
    END { exit found ? 0 : 1 }
  ' "$swift_file"; then
    return
  fi

  perl -0pi -e 's/(public protocol VistaEngineProtocol: AnyObject, Sendable \{\n)/$1\n    func complete(prefix: String, maxTokens: UInt32) async throws -> String\n/' "$swift_file"

  if ! awk '
    /public protocol VistaEngineProtocol: AnyObject, Sendable \{/ { in_protocol = 1 }
    in_protocol && /func complete\(prefix: String, maxTokens: UInt32\)/ { found = 1 }
    in_protocol && /^}/ { in_protocol = 0 }
    END { exit found ? 0 : 1 }
  ' "$swift_file"; then
    echo "error: failed to patch VistaEngineProtocol.complete into $swift_file" >&2
    exit 1
  fi
}

echo "Building qube-ffi from $VISTA_KERNEL_ROOT ($FFI_PROFILE)"
(
  cd "$VISTA_KERNEL_ROOT"
  cargo build -p qube-ffi "${CARGO_PROFILE_ARGS[@]}"
  cargo run -p uniffi-bindgen -- generate \
    --library "$LIB_DIR/libqube_ffi.dylib" \
    --language swift \
    --out-dir "$BRIDGE_DIR"
)

mkdir -p \
  "$PENSIEVE_ROOT/Sources/Pensieve/VistaBridge" \
  "$PENSIEVE_ROOT/Sources/qube_ffiFFI" \
  "$VENDOR_DIR"

cp "$BRIDGE_DIR/qube_ffi.swift" \
  "$GENERATED_SWIFT"
patch_completion_protocol "$GENERATED_SWIFT"
cp "$BRIDGE_DIR/qube_ffiFFI.h" \
  "$PENSIEVE_ROOT/Sources/qube_ffiFFI/qube_ffiFFI.h"
cp "$LIB_DIR/libqube_ffi.dylib" \
  "$VENDOR_DIR/libqube_ffi.dylib"
# Cargo bakes an absolute install_name (builder's checkout path) into the dylib,
# so binaries linked against it dlopen-fail on every other machine, including CI.
# Repoint to @rpath — Package.swift already adds the matching -rpath — and ad-hoc
# re-sign (install_name_tool invalidates the signature; release re-signs properly).
install_name_tool -id "@rpath/libqube_ffi.dylib" \
  "$VENDOR_DIR/libqube_ffi.dylib"
codesign -f -s - "$VENDOR_DIR/libqube_ffi.dylib"
cat >"$PENSIEVE_ROOT/Sources/qube_ffiFFI/module.modulemap" <<'MODULEMAP'
module qube_ffiFFI {
  header "qube_ffiFFI.h"
  export *
  use "Darwin"
  use "_Builtin_stdbool"
  use "_Builtin_stdint"
}
MODULEMAP

cat >"$PROVENANCE" <<PROVENANCE
vista-kernel-root=$VISTA_KERNEL_ROOT
vista-kernel-head=$(git -C "$VISTA_KERNEL_ROOT" rev-parse HEAD)
vista-kernel-describe=$(git -C "$VISTA_KERNEL_ROOT" describe --always --dirty --tags)
ffi-profile=$FFI_PROFILE
built-at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
host=$(hostname)
PROVENANCE

echo "Synced qube-ffi bridge and $FFI_PROFILE dylib into Pensieve."
echo "Wrote provenance to $PROVENANCE."
