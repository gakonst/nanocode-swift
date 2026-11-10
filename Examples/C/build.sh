#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
library=build/macos/libnanocode_swift.a
[[ -f "$library" ]] || PLATFORMS=macos ./scripts/build-ffi.sh
mkdir -p build/c
cc -O2 -Wall -Wextra -Iinclude Examples/C/main.c "$library" \
  -framework Security -framework SystemConfiguration -framework CoreFoundation -lresolv -liconv \
  -o build/c/nanocode-c
echo build/c/nanocode-c
