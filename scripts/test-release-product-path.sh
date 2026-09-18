#!/usr/bin/env bash
# Execute the release's product selection against synthetic compiler responses.
# No Swift compiler, signing, network, or production artifacts are touched.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/pensieve-product-path.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT
sed -n '/^# BEGIN selected SwiftPM products$/,/^# END selected SwiftPM products$/p' \
    "$SCRIPT_DIR/build-release.sh" > "$fixture/select.sh"
[[ -s "$fixture/select.sh" ]]
APP_NAME=Pensieve
BUILD_LOG="$fixture/build.log"
export FFI_PROFILE=release
ok() { :; }
die() { printf '%s\n' "$*" >&2; exit 1; }
swift() {
    [[ "$*" == 'build -c release --arch arm64 --show-bin-path' && "$FFI_PROFILE" == release ]] || return 1
    [[ "$stub_failure" == false ]] || return 1
    printf '%s\n' "$selected"
}
make_products() {
    mkdir -p "$1/Pensieve_Pensieve.bundle"
    touch "$1/Pensieve"
    chmod +x "$1/Pensieve"
}
stub_failure=false
for layout in '.build/arm64-apple-macosx/release' '.build/out/Products/Release with spaces'; do
    selected="$fixture/$layout"
    make_products "$selected"
    source "$fixture/select.sh"
    [[ "$EXECUTABLE" == "$selected/Pensieve" ]]
    [[ "$SPM_BUNDLE_DIR" == "$selected/Pensieve_Pensieve.bundle" ]]
done
# A stale native-backend executable exists above; the selected swiftbuild
# output must still fail closed when its own executable/resources are missing.
rm "$selected/Pensieve"
if (source "$fixture/select.sh"); then exit 1; fi
touch "$selected/Pensieve"
chmod +x "$selected/Pensieve"
rmdir "$selected/Pensieve_Pensieve.bundle"
if (source "$fixture/select.sh"); then exit 1; fi
selected=relative/path
if (source "$fixture/select.sh"); then exit 1; fi
stub_failure=true
if (source "$fixture/select.sh"); then exit 1; fi
printf 'PASS: backend-selected products, spaces, and four fail-closed cases\n'
