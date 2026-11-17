#!/bin/bash
# Draws the app icon's pictures again from the sources beside this script:
#   Tools/render-icon.sh
# It builds Tools/IconRender.swift with the app's Sources and runs it, writing cassette.png and
# glow.png into Icon/AppIcon.icon/Assets. Then run Icon/build-icon.sh to compile the icon. See
# doc/building-and-testing.md.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
build="${EPSCAN_ICON_BUILD_DIR:-${TMPDIR:-/tmp}/epscan-icon-build}"
mkdir -p "$build/module-cache"
sources=()
for f in "$root"/Sources/*.swift; do
  [[ "$f" == */EpsonScanPlus.swift ]] || sources+=("$f")
done
xcrun swiftc -swift-version 5 -O -module-cache-path "$build/module-cache" -target arm64-apple-macos26.0 \
  "${sources[@]}" "$root/Tools/IconRender.swift" -o "$build/IconRender"
"$build/IconRender" "$root/Icon/AppIcon.icon/Assets"
