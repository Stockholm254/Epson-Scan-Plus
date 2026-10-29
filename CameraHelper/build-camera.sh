#!/bin/bash
# Builds the camera process against Sony's Camera Remote SDK when the SDK is on this Mac, and puts
# it and the SDK's libraries into the app. Without the SDK the app builds as before and its camera
# panel says the SDK is missing. The SDK is not in this repository: Sony's licence governs it.
# EPSON_SCAN_PLUS_CRSDK names its folder (include/ with the headers, lib/ with libCr_Core.dylib and
# lib/CrAdapter/); by default it sits beside the project as Sony-CrSDK.
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
app_dir="$2"
sdk="${EPSON_SCAN_PLUS_CRSDK:-$project_dir/../Sony-CrSDK}"
helper="$app_dir/Contents/MacOS/EpsonCameraHelper"
frameworks="$app_dir/Contents/Frameworks"
if [ ! -f "$sdk/include/CameraRemote_SDK.h" ] || [ ! -f "$sdk/lib/libCr_Core.dylib" ]; then
  echo "Sony Camera Remote SDK not found at $sdk: building without the camera" >&2
  rm -f "$helper" "$app_dir/Contents/MacOS/EpsonCameraSimulator"
  exit 0
fi
mkdir -p "$frameworks/CrAdapter"
xcrun clang++ -std=c++17 -O2 -Wall -Wno-unused-parameter -target arm64-apple-macos14.0 \
  -isystem "$sdk/include" "$project_dir/CameraHelper/CameraHelper.cpp" \
  -L"$sdk/lib" -lCr_Core -Wl,-rpath,@executable_path/../Frameworks -o "$helper"
# The same process against a simulated camera (SimulatedCamera.cpp, not Sony's library), for the
# self-test to take pictures with: only ever started by the self-test.
xcrun clang++ -std=c++17 -O2 -Wall -Wno-unused-parameter -target arm64-apple-macos14.0 \
  -isystem "$sdk/include" "$project_dir/CameraHelper/CameraHelper.cpp" "$project_dir/CameraHelper/SimulatedCamera.cpp" \
  -o "$app_dir/Contents/MacOS/EpsonCameraSimulator"
# libCr_Core finds its adapters in the bundle's Contents/Frameworks/CrAdapter.
cp "$sdk/lib/libCr_Core.dylib" "$frameworks/"
cp "$sdk/lib/CrAdapter/"*.dylib "$frameworks/CrAdapter/"
xattr -cr "$frameworks" "$helper" "$app_dir/Contents/MacOS/EpsonCameraSimulator"
for artifact in "$frameworks/CrAdapter/"*.dylib "$frameworks/libCr_Core.dylib" "$helper" "$app_dir/Contents/MacOS/EpsonCameraSimulator"; do
  codesign --force --sign - "$artifact"
done
