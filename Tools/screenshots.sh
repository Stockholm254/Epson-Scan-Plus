#!/bin/bash
# Takes the window shots in doc/images again from the sources beside this script:
#   Tools/screenshots.sh [images folder]     (default: doc/images of this checkout)
# It builds Tools/Screenshots.swift with the app's Sources and runs it. It needs an unlocked
# screen and the screen-recording permission for whatever runs it. See doc/building-and-testing.md.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
images="${1:-$root/doc/images}"
build="${EPSCAN_SHOTS_BUILD_DIR:-${TMPDIR:-/tmp}/epscan-screenshots-build}"
mkdir -p "$build/module-cache"
sources=()
for f in "$root"/Sources/*.swift; do
  [[ "$f" == */EpsonScanPlus.swift ]] || sources+=("$f")
done
xcrun swiftc -swift-version 5 -O -module-cache-path "$build/module-cache" -target arm64-apple-macos26.0 \
  "${sources[@]}" "$root/Tools/Screenshots.swift" -o "$build/Screenshots"
"$build/Screenshots" "$images"
