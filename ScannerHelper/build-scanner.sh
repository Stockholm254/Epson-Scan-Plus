#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="$1/scanner"
destination="$2/Contents/Resources/Scanner"
runtime="$build_dir/runtime"
export MACOSX_DEPLOYMENT_TARGET=14.0
mkdir -p "$build_dir" "$destination/config" "$destination/Licenses" "$destination/Source"
sources="$project_dir/ThirdParty/Sources"
printf '%s  %s\n' \
  fea36f34f9156400209595e300840767ab1a385ede1dc7ee893015aea9c6dbaf "$sources/libusb-1.0.30.tar.bz2" \
  f99205c903dfe2fb8990f0c531232c9a00ec9c2c66ac7cb0ce50b4af9f407a72 "$sources/sane-backends-1.4.0.tar.gz" | shasum -a 256 -c -
if [ ! -d "$build_dir/libusb-1.0.30" ]; then tar -xjf "$sources/libusb-1.0.30.tar.bz2" -C "$build_dir"; fi
if [ ! -d "$build_dir/sane-backends-1.4.0" ]; then tar -xzf "$sources/sane-backends-1.4.0.tar.gz" -C "$build_dir"; fi
# configure only asks whether a function links, and against a newer SDK than the deployment
# target one that is newer still does: weakly, and null on the systems the app runs on. pipe2 is
# in the macOS 27 SDK, and libusb calls it straight away. Built again when these change.
libusb_cache="ac_cv_func_pipe2=no"
if [ ! -f "$runtime/lib/libusb-1.0.0.dylib" ] || [ "$(cat "$runtime/libusb-configure" 2>/dev/null)" != "$libusb_cache" ]; then
  (
    cd "$build_dir/libusb-1.0.30"
    make distclean || true
    env $libusb_cache ./configure --prefix="$runtime" --disable-examples-build --disable-tests-build
    make -j6
    make install
    echo "$libusb_cache" > "$runtime/libusb-configure"
  ) > "$build_dir/libusb-build.log" 2>&1
fi
if [ ! -f "$build_dir/sane-backends-1.4.0/backend/.libs/libsane-epson2.1.dylib" ]; then
  (
    cd "$build_dir/sane-backends-1.4.0"
    BACKENDS=epson2 USB_CFLAGS="-I$runtime/include/libusb-1.0" USB_LIBS="-L$runtime/lib -lusb-1.0" \
      ./configure --prefix="$runtime" --with-usb --without-avahi --without-snmp --without-gphoto2 --without-v4l --disable-nls --disable-dynamic --enable-pthread
    # Link the single backend, not the optional SANE dispatcher/frontends/daemon.
    make -j6 -C lib
    make -j6 -C sanei
    make -j6 -C backend libsane-epson2.la
  ) > "$build_dir/sane-build.log" 2>&1
fi
xcrun clang++ -std=c++17 -fobjc-arc -O2 -target arm64-apple-macos14.0 \
  -I"$build_dir/sane-backends-1.4.0/include" \
  -framework Foundation -framework ImageIO -framework CoreGraphics \
  "$project_dir/ScannerHelper/SaneCapture.mm" -o "$destination/SaneCapture"
cp "$build_dir/sane-backends-1.4.0/backend/.libs/libsane-epson2.1.dylib" "$destination/"
cp "$runtime/lib/libusb-1.0.0.dylib" "$destination/"
install_name_tool -id '@loader_path/libsane-epson2.1.dylib' \
  -change "$runtime/lib/libusb-1.0.0.dylib" '@loader_path/libusb-1.0.0.dylib' "$destination/libsane-epson2.1.dylib"
install_name_tool -id '@loader_path/libusb-1.0.0.dylib' "$destination/libusb-1.0.0.dylib"
cp "$project_dir/ScannerHelper/config/epson2.conf" "$destination/config/"
cp "$build_dir/sane-backends-1.4.0/COPYING" "$destination/Licenses/SANE-GPL-2.txt"
cp "$build_dir/libusb-1.0.30/COPYING" "$destination/Licenses/libusb-LGPL-2.1.txt"
cp "$project_dir/ThirdParty/README.md" "$destination/Licenses/README.md"
# Ship corresponding upstream sources and helper source with the binary too.
cp "$sources/libusb-1.0.30.tar.bz2" "$sources/sane-backends-1.4.0.tar.gz" "$destination/Source/"
cp "$project_dir/ScannerHelper/SaneCapture.mm" "$project_dir/ScannerHelper/build-scanner.sh" "$destination/Source/"
for artifact in SaneCapture libsane-epson2.1.dylib libusb-1.0.0.dylib; do
  # Nothing here checks availability at run time, so a weakly linked function is one the
  # deployment target may not have.
  if xcrun nm -um "$destination/$artifact" | grep -q "weak external"; then
    echo "Weakly linked functions in $artifact, which macOS 14 may not have:" >&2
    xcrun nm -um "$destination/$artifact" | grep "weak external" >&2
    exit 1
  fi
  codesign --force --sign - "$destination/$artifact"
done
