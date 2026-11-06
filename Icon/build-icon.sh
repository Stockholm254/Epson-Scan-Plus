#!/bin/bash
# Compiles the app icon. AppIcon.icon is an Icon Composer document (open it in Icon Composer,
# which comes with Xcode, to change it): a 135 cassette and its film leader as glass layers, which
# the system lights and renders for the light, dark, clear and tinted looks. actool, which only
# Xcode has, turns it into Assets.car (the layered icon) and AppIcon.icns (a flat copy for
# what cannot read the layers). Both are committed, so build.sh needs only the Command Line Tools;
# run this after changing the icon, then commit the two files with it.
set -euo pipefail
icon_dir="$(cd "$(dirname "$0")" && pwd)"
developer="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
actool="$developer/usr/bin/actool"
if [ ! -x "$actool" ]; then echo "no actool at $actool: compiling the icon needs Xcode" >&2; exit 1; fi
out="$(mktemp -d "${TMPDIR:-/tmp}/epscan-icon.XXXXXX")"
trap 'rm -rf "$out"' EXIT
"$actool" "$icon_dir/AppIcon.icon" --compile "$out" --output-format human-readable-text --errors --warnings \
  --output-partial-info-plist "$out/partial.plist" --app-icon AppIcon --include-all-app-icons \
  --enable-on-demand-resources NO --development-region en --target-device mac \
  --minimum-deployment-target 26.0 --platform macosx >/dev/null
# Info.plist names the icon the same way.
for key in CFBundleIconFile CFBundleIconName; do
  [ "$(plutil -extract "$key" raw "$out/partial.plist")" = AppIcon ] || { echo "actool named the icon differently ($key)" >&2; exit 1; }
done
cp "$out/Assets.car" "$out/AppIcon.icns" "$icon_dir/"
ls -l "$icon_dir/Assets.car" "$icon_dir/AppIcon.icns"
