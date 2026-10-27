#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
repository=${GITHUB_REPOSITORY:-gakonst/nanocode-swift}
fingerprint=$(cat Cargo.toml Cargo.lock sdk-revision.json rust-toolchain.toml scripts/build-ffi.sh include/* $(find src -name '*.rs' | sort) | shasum -a 256 | cut -c1-20)
tag="ffi-$fingerprint"
url="https://github.com/$repository/releases/download/$tag/NanocodeFFI.xcframework.zip"
if [[ "${1:-}" == --fingerprint ]]; then
  echo "$fingerprint"
  exit 0
fi
if gh release view "$tag" --repo "$repository" >/dev/null 2>&1; then
  gh release download "$tag" --repo "$repository" --pattern ffi-release.json --output ffi-release.json --clobber
  echo "$tag already published"
  exit 0
fi
PROFILE=release UNIVERSAL=1 ./scripts/build-ffi.sh
rm -f build/NanocodeFFI.xcframework.zip
(cd build && ditto -c -k --sequesterRsrc --keepParent NanocodeFFI.xcframework NanocodeFFI.xcframework.zip)
checksum=$(swift package compute-checksum build/NanocodeFFI.xcframework.zip)
printf '{\n  "url": "%s",\n  "checksum": "%s",\n  "fingerprint": "%s"\n}\n' "$url" "$checksum" "$fingerprint" > ffi-release.json
if [[ "${1:-}" == --upload ]]; then
  gh release create "$tag" build/NanocodeFFI.xcframework.zip ffi-release.json --repo "$repository" \
    --title "NanocodeFFI $fingerprint" \
    --notes "The nanocode SDK at $(jq -r .revision sdk-revision.json) built for macOS (arm64, x86_64), iOS and the iOS simulator. Package.swift reads ffi-release.json."
fi
