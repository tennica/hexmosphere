#!/bin/bash
# Build h3o-ffi for the Mac and the iPad and package it as CH3O.xcframework.
# Needs a rustup toolchain with aarch64-apple-ios (Homebrew's rust can't add iOS).
set -euo pipefail
cd "$(dirname "$0")"
TOOLCHAIN=${TOOLCHAIN:-stable}
# Use the rustup toolchain's own cargo and rustc, even when Homebrew's rust is
# earlier on PATH (Homebrew's rustc has no iOS standard library).
CARGO=$(rustup which --toolchain "$TOOLCHAIN" cargo)
export RUSTC=$(rustup which --toolchain "$TOOLCHAIN" rustc)
for target in aarch64-apple-darwin aarch64-apple-ios; do
  "$CARGO" build --release --target "$target"
done
rm -rf CH3O.xcframework
xcodebuild -create-xcframework \
  -library target/aarch64-apple-darwin/release/libh3o_ffi.a -headers include \
  -library target/aarch64-apple-ios/release/libh3o_ffi.a -headers include \
  -output CH3O.xcframework
echo "built $(pwd)/CH3O.xcframework"
