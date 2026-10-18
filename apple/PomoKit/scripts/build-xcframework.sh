#!/usr/bin/env bash
# Builds PomoFFI.xcframework (iOS device, iOS simulator, macOS; all arm64) from the `pomo-ffi` crate and
# regenerates the UniFFI Swift bindings into Sources/PomoCoreFFI.
#
#   apple/PomoKit/scripts/build-xcframework.sh [--debug]
#
# Environment: CARGO_TARGET_DIR (default ~/.cache/pomo-target/ios).
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../../.." && pwd)"
kit="$here/.."
profile=release
cargo_profile=(--release)
if [[ "${1:-}" == "--debug" ]]; then profile=debug; cargo_profile=(); fi
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$HOME/.cache/pomo-target/ios}"
targets=(aarch64-apple-ios aarch64-apple-ios-sim aarch64-apple-darwin)

cd "$root"
for t in "${targets[@]}"; do
  rustup target list --installed | grep -qx "$t" || rustup target add "$t"
  cargo build ${cargo_profile[@]+"${cargo_profile[@]}"} -p pomo-ffi --target "$t"
done

lib="libpomo_ffi.a"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# Library-mode generation reads the UniFFI metadata embedded in the library.
cargo run ${cargo_profile[@]+"${cargo_profile[@]}"} -q -p pomo-ffi --features bindgen --bin uniffi-bindgen -- \
  generate --library "$CARGO_TARGET_DIR/aarch64-apple-darwin/$profile/$lib" \
  --language swift --out-dir "$work/gen"

mkdir -p "$work/headers"
cp "$work/gen/pomo_ffiFFI.h" "$work/headers/"
cp "$work/gen/pomo_ffiFFI.modulemap" "$work/headers/module.modulemap"

out="$kit/PomoFFI.xcframework"
rm -rf "$out"
args=()
for t in "${targets[@]}"; do
  args+=(-library "$CARGO_TARGET_DIR/$t/$profile/$lib" -headers "$work/headers")
done
xcodebuild -create-xcframework "${args[@]}" -output "$out"

mkdir -p "$kit/Sources/PomoCoreFFI"
cp "$work/gen/pomo_ffi.swift" "$kit/Sources/PomoCoreFFI/pomo_ffi.swift"
echo "built $out"
