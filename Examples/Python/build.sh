#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
library=build/macos/libnanocode_swift.a
[[ -f "$library" ]] || PLATFORMS=macos ./scripts/build-ffi.sh
mkdir -p build/python
cc -dynamiclib -Wl,-force_load,"$library" \
  -framework Security -framework SystemConfiguration -framework CoreFoundation -lresolv -liconv \
  -o build/python/libnanocode.dylib
echo build/python/libnanocode.dylib
