#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
profile=${PROFILE:-release}
platforms=${PLATFORMS:-macos ios ios-sim}
flags=(--locked --lib)
directory=debug
if [[ "$profile" == release ]]; then
  flags+=(--release)
  directory=release
fi
rm -rf build/headers
mkdir -p build/headers
cp include/nanocode.h include/module.modulemap build/headers/
arguments=()
for platform in $platforms; do
  case "$platform" in
    macos) targets=(aarch64-apple-darwin); [[ "${UNIVERSAL:-}" == 1 ]] && targets+=(x86_64-apple-darwin) ;;
    ios) targets=(aarch64-apple-ios) ;;
    ios-sim) targets=(aarch64-apple-ios-sim); [[ "${UNIVERSAL:-}" == 1 ]] && targets+=(x86_64-apple-ios) ;;
    *) echo "unknown platform $platform" >&2; exit 2 ;;
  esac
  libraries=()
  for target in "${targets[@]}"; do
    cargo build "${flags[@]}" --target "$target"
    libraries+=("target/$target/$directory/libnanocode_swift.a")
  done
  mkdir -p "build/$platform"
  lipo -create "${libraries[@]}" -output "build/$platform/libnanocode_swift.a"
  arguments+=(-library "build/$platform/libnanocode_swift.a" -headers build/headers)
done
rm -rf build/NanocodeFFI.xcframework
xcodebuild -create-xcframework "${arguments[@]}" -output build/NanocodeFFI.xcframework
