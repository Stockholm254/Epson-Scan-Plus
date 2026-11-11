#!/bin/bash
# Puts the Keychain's key reader, EpsonScanKey, into the app: the same program every version, so
# the Keychain's 始终允许 given to it holds across updates (KeyHelper/EpsonScanKey.swift says why).
# It is built and signed once per source and kept outside the repository, in
# ~/Library/Application Support/epscan-release/key-helper (EPSON_SCAN_PLUS_KEY_HELPER_DIR), named
# by its source's hash; every build copies the kept program, byte for byte. Changing the source
# makes a new program, and the Keychain asks once more. Without the signing identity it is built
# ad hoc each time, as the app is, and the app reads the Keychain itself if it cannot use it.
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="$1"
app_dir="$2"
source="$project_dir/KeyHelper/EpsonScanKey.swift"
store="${EPSON_SCAN_PLUS_KEY_HELPER_DIR:-$HOME/Library/Application Support/epscan-release/key-helper}"
identity="${EPSON_SCAN_PLUS_SIGNING_IDENTITY:-Epson Scan plus Signing}"
target="$app_dir/Contents/MacOS/EpsonScanKey"
build() {
  xcrun swiftc -swift-version 5 -O -module-cache-path "$build_dir/module-cache" -target arm64-apple-macos26.0 "$source" -o "$1"
}
if ! security find-identity -p codesigning 2>/dev/null | grep -qF "\"$identity\""; then
  build "$build_dir/EpsonScanKey"
  codesign --force --sign - --identifier local.epscan.keyhelper "$build_dir/EpsonScanKey"
  cp "$build_dir/EpsonScanKey" "$target"
  exit 0
fi
kept="$store/EpsonScanKey-$(shasum -a 256 "$source" | cut -c1-16)"
if [ ! -x "$kept" ]; then
  mkdir -p "$store"
  build "$build_dir/EpsonScanKey"
  codesign --force --sign "$identity" --identifier local.epscan.keyhelper "$build_dir/EpsonScanKey"
  cp "$build_dir/EpsonScanKey" "$kept.$$"
  mv "$kept.$$" "$kept"
  echo "built and kept a new EpsonScanKey: the Keychain will ask once for it" >&2
fi
cp "$kept" "$target"
