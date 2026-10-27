# Experimental V850 USB backend

This application is independently developed; it is not an Epson product.

- SANE backends 1.4.0, epson2 only. Copyright its respective authors; epson2 is GPL-2.0. The backend source is unmodified. https://www.sane-project.org/ and https://gitlab.com/sane-project/backends
- libusb 1.0.30. Copyright its respective authors; LGPL-2.1 or later. https://libusb.info/ and https://github.com/libusb/libusb
- SaneCapture.mm is distributed under GPL-2.0-only. It dynamically loads the standalone backend in an isolated subprocess. The app communicates through newline-delimited JSON and TIFF files.

Both upstream release source archives are included in `ThirdParty/Sources` in the source distribution and `Contents/Resources/Scanner/Source` in the app bundle. Full license texts are included in the upstream archives and the bundle's `Scanner/Licenses` directory. The helper source and build script are also included. Libraries are locally built, with relocatable install names; no system driver is installed or replaced. No SANE network daemon or frontend is packaged.

Build with `bash build.sh`. Apple command-line tools, arm64 macOS, and a filesystem path without spaces for the intermediate dependency build are required. `EPSON_SCAN_PLUS_BUILD_DIR` selects the intermediate directory. The script verifies the source archives, builds libusb and the single epson2 library, and signs the resulting local test bundle. No network download is required after obtaining this source distribution.

Official release sources:

- https://github.com/libusb/libusb/releases/download/v1.0.30/libusb-1.0.30.tar.bz2
- https://gitlab.com/-/project/429008/uploads/843c156420e211859e974f78f64c3ea3/sane-backends-1.4.0.tar.gz

This is an experimental integration, without warranty. A linear RGB encoding tag describes encoding, not a calibrated scanner color profile or verified 16-bit effective sensor precision. The application still does not implement dust removal or Digital ICE.
