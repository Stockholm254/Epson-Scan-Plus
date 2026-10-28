#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")" && pwd)"
build_dir="${EPSON_SCAN_PLUS_BUILD_DIR:-$project_dir/.build}"
app_dir="${EPSON_SCAN_PLUS_APP_DIR:-$project_dir/../Epson Scan plus.app}"
mkdir -p "$build_dir/module-cache" "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
# Offline helper checks run first, so a cancel or watchdog regression never reaches the bundle.
bash "$project_dir/ScannerHelper/test-fake-backend.sh"
bash "$project_dir/ScannerHelper/build-scanner.sh" "$build_dir" "$app_dir"
bash "$project_dir/CameraHelper/build-camera.sh" "$build_dir" "$app_dir"
xcrun swiftc -swift-version 5 -O -module-cache-path "$build_dir/module-cache" -target arm64-apple-macos14.0 "$project_dir"/Sources/*.swift -o "$app_dir/Contents/MacOS/EpsonScanPlus"
cp "$project_dir/Info.plist" "$app_dir/Contents/Info.plist"
xattr -d com.apple.FinderInfo "$app_dir" 2>/dev/null || true
codesign --force --sign - "$app_dir"
printf '%s\n' "$app_dir"
