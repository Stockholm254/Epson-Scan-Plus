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
bash "$project_dir/KeyHelper/build-key.sh" "$build_dir" "$app_dir"
xcrun swiftc -swift-version 5 -O -module-cache-path "$build_dir/module-cache" -target arm64-apple-macos26.0 "$project_dir"/Sources/*.swift -o "$app_dir/Contents/MacOS/EpsonScanPlus"
cp "$project_dir/Info.plist" "$app_dir/Contents/Info.plist"
# The icon, compiled from Icon/AppIcon.icon by Icon/build-icon.sh.
cp "$project_dir/Icon/Assets.car" "$project_dir/Icon/AppIcon.icns" "$app_dir/Contents/Resources/"
xattr -d com.apple.FinderInfo "$app_dir" 2>/dev/null || true
# Signed with a fixed identity where this Mac has one (Keychain Access → Certificate Assistant →
# a self-signed root for code signing, named as below): macOS then knows each version as the same
# app. The Keychain still knows an app without a developer team by its build's own hash, so the
# OpenAI key is read through EpsonScanKey, which stays the same (KeyHelper/build-key.sh). An ad hoc
# signature is the fallback. The helpers in Contents/MacOS keep their own signatures.
identity="${EPSON_SCAN_PLUS_SIGNING_IDENTITY:-Epson Scan plus Signing}"
if security find-identity -p codesigning 2>/dev/null | grep -qF "\"$identity\""; then
  codesign --force --sign "$identity" "$app_dir" || {
    echo "signing with \"$identity\" failed: signed ad hoc instead" >&2
    codesign --force --sign - "$app_dir"
  }
else
  codesign --force --sign - "$app_dir"
fi
printf '%s\n' "$app_dir"
