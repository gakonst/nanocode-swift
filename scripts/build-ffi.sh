#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
profile=${PROFILE:-fast}
platforms=${PLATFORMS:-macos ios ios-sim}
flags=(--locked --lib)
directory=release
case "$profile" in
  debug) directory=debug ;;
  release) flags+=(--release) ;;
  fast)
    flags+=(--release)
    for setting in opt-level=1 codegen-units=256 incremental=true; do
      flags+=(--config "profile.release.package.nanocode-swift.$setting")
    done
    ;;
  *) echo "unknown profile $profile" >&2; exit 2 ;;
esac
targets=()
for platform in $platforms; do
  case "$platform" in
    macos) targets+=(aarch64-apple-darwin); [[ "${UNIVERSAL:-}" == 1 ]] && targets+=(x86_64-apple-darwin) ;;
    ios) targets+=(aarch64-apple-ios) ;;
    ios-sim) targets+=(aarch64-apple-ios-sim); [[ "${UNIVERSAL:-}" == 1 ]] && targets+=(x86_64-apple-ios) ;;
    *) echo "unknown platform $platform" >&2; exit 2 ;;
  esac
done
cargo build "${flags[@]}" "${targets[@]/#/--target=}"
rm -rf build/headers build/.xcframework
mkdir -p build/headers
cp include/nanocode.h include/module.modulemap build/headers/
arguments=()
for platform in $platforms; do
  libraries=()
  for target in "${targets[@]}"; do
    case "$platform:$target" in
      macos:*-apple-darwin | ios:aarch64-apple-ios | ios-sim:*-apple-ios-sim | ios-sim:x86_64-apple-ios)
        libraries+=("target/$target/$directory/libnanocode_swift.a") ;;
    esac
  done
  mkdir -p "build/$platform"
  lipo -create "${libraries[@]}" -output "build/$platform/libnanocode_swift.a"
  arguments+=(-library "build/$platform/libnanocode_swift.a" -headers build/headers)
done
xcodebuild -create-xcframework "${arguments[@]}" -output build/.xcframework >/dev/null
mkdir -p build/NanocodeFFI.xcframework
rsync -rc --delete build/.xcframework/ build/NanocodeFFI.xcframework/
rm -rf build/.xcframework
echo "build/NanocodeFFI.xcframework ($profile: ${targets[*]})"
