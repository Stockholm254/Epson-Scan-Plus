#!/bin/bash
# Builds the committed tree as the version Info.plist names, runs the self-test, and publishes it:
# a disk image to install from by dragging the app into Applications, and the zipped app on the
# update feed that copies in Applications update from. Nothing published is ever replaced: a
# version already on the feed or an image already made stops the release.
#   EPSCAN_RELEASE_FEED_DIR  the feed (default: ~/Library/Application Support/epscan/Releases)
#   EPSCAN_RELEASE_KEY       the release key (default: ~/Library/Application Support/epscan-release/update-signing.key)
#   EPSCAN_RELEASE_IMAGE_DIR where the disk image goes (default: the folder above the project)
#   EPSCAN_RELEASE_SKIP_TESTS=1 skips the self-test
set -euo pipefail
project_dir="$(cd "$(dirname "$0")" && pwd)"
support="$HOME/Library/Application Support"
feed_dir="${EPSCAN_RELEASE_FEED_DIR:-$support/epscan/Releases}"
key="${EPSCAN_RELEASE_KEY:-$support/epscan-release/update-signing.key}"
image_dir="${EPSCAN_RELEASE_IMAGE_DIR:-$project_dir/..}"
build_dir="$project_dir/.build"
version=$(plutil -extract CFBundleShortVersionString raw "$project_dir/Info.plist")
build=$(plutil -extract CFBundleVersion raw "$project_dir/Info.plist")
minimum=$(plutil -extract LSMinimumSystemVersion raw "$project_dir/Info.plist")
if [ -n "$(git -C "$project_dir" status --porcelain)" ]; then
  echo "uncommitted changes: commit first, so the release is a commit" >&2
  exit 1
fi
commit=$(git -C "$project_dir" rev-parse --short HEAD)
archive="$feed_dir/Epson-Scan-plus-$version-$build.zip"
image="$image_dir/Epson-Scan-plus-$version.dmg"
for out in "$archive" "$image"; do
  if [ -e "$out" ]; then echo "$out exists: a published version is never replaced; raise the version in Info.plist" >&2; exit 1; fi
done

mkdir -p "$build_dir/module-cache"
tool="$build_dir/release-tool"
xcrun swiftc -swift-version 5 -O -module-cache-path "$build_dir/module-cache" -target arm64-apple-macos26.0 \
  "$project_dir/Release/main.swift" "$project_dir/Sources/UpdateFeed.swift" -o "$tool"
"$tool" keygen "$key" >/dev/null
"$tool" check-key "$key"
"$tool" check-feed "$key" "$feed_dir/appcast.json" "$version" "$build"
# The notes are the headings of this version's entries in the change log.
notes="$build_dir/notes-$build.txt"
"$tool" notes "$project_dir/doc/CHANGELOG.md" "$version" > "$notes"
if [ ! -s "$notes" ]; then echo "doc/CHANGELOG.md has no section \"## $version\"" >&2; exit 1; fi

stage="$(mktemp -d "${TMPDIR:-/tmp}/epscan-release.XXXXXX")"
# What this run put out goes again if it does not finish, so a failed release leaves nothing
# that would stop the next one.
placed=()
finish() {
  local status=$?
  # Spelled so an empty list passes `set -u` in macOS's bash 3.2.
  if [ "$status" != 0 ]; then for out in ${placed[@]+"${placed[@]}"}; do rm -f "$out"; done; fi
  rm -rf "$stage"
}
trap finish EXIT
app="$stage/Epson Scan plus.app"
EPSON_SCAN_PLUS_BUILD_DIR="$build_dir" EPSON_SCAN_PLUS_APP_DIR="$app" bash "$project_dir/build.sh" >/dev/null
codesign --verify --deep --strict "$app"
if [ "${EPSCAN_RELEASE_SKIP_TESTS:-0}" != 1 ]; then
  if ! "$app/Contents/MacOS/EpsonScanPlus" --self-test --test-output "$stage/tests" > "$stage/self-test.log" 2>&1; then
    grep FAIL "$stage/self-test.log" >&2 || tail -5 "$stage/self-test.log" >&2
    exit 1
  fi
  echo "self-test: $(grep -c '^PASS' "$stage/self-test.log") passed"
fi

# The disk image: the app and a link to Applications to drag it onto.
mkdir "$stage/image"
ditto "$app" "$stage/image/Epson Scan plus.app"
ln -s /Applications "$stage/image/Applications"
hdiutil create -quiet -volname "Epson Scan plus $version" -srcfolder "$stage/image" -fs APFS -format UDZO "$stage/image.dmg"
mkdir -p "$image_dir" "$feed_dir"
# The update: the app zipped without extended attributes, so its signature checks strictly.
ditto -c -k --norsrc --keepParent "$app" "$stage/update.zip"
placed+=("$image")
mv "$stage/image.dmg" "$image"
placed+=("$archive")
mv "$stage/update.zip" "$archive"
"$tool" publish "$key" "$feed_dir/appcast.json" "$archive" "$version" "$build" "$minimum" "$commit" "$notes"
printf '%s\n%s\n' "$image" "$archive"
