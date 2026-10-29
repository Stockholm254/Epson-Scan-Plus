#!/bin/bash
# Offline helper test against FakeSane.c; it never touches USB or a scanner.
# Cancel, the no-data watchdog and a closed stdout must all drain the transfer
# before closing, never call sane_cancel, and never publish a partial TIFF.
# Usage: bash ScannerHelper/test-fake-backend.sh
set -euo pipefail
helper_dir="$(cd "$(dirname "$0")" && pwd)"
project_dir="$(cd "$helper_dir/.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/EpsonScanPlus-fake.XXXXXX")"
trap 'rm -rf "$work"' EXIT
tar -xzf "$project_dir/ThirdParty/Sources/sane-backends-1.4.0.tar.gz" -C "$work" sane-backends-1.4.0/include
include="$work/sane-backends-1.4.0/include"
xcrun clang -dynamiclib -O2 -I"$include" "$helper_dir/FakeSane.c" -o "$work/libfake.dylib"
# A 2-second no-data window. Each fake read takes 30 ms, so only a deliberate stall trips it,
# while the whole 10-second scan is far longer than the window.
xcrun clang++ -std=c++17 -fobjc-arc -O2 -DSTALL_SECONDS=2 -target arm64-apple-macos14.0 \
  -I"$include" -framework Foundation -framework ImageIO -framework CoreGraphics \
  "$helper_dir/SaneCapture.mm" -o "$work/SaneCapture"

failures=0
scan_args=(--scan 2400 16 14 20 20)  # 20 × 20 mm at 2400 dpi: about 330 fake reads
extra=()  # more arguments after --output, for one scan
start_scan() {  # name [VAR=value...]
  out="$work/$1"; shift
  mkdir "$out"
  env "$@" "$work/SaneCapture" "$work/libfake.dylib" "$helper_dir/config" "${scan_args[@]}" \
    --output "$out/frame.tiff" ${extra[@]+"${extra[@]}"} > "$out/events" 2> "$out/stderr" &
  pid=$!
}
wait_for() {  # event
  for _ in $(seq 300); do
    grep -q "\"event\":\"$1\"" "$out/events" && return 0
    sleep 0.1
  done
  echo "No $1 event" >&2
  return 1
}
check() {  # label expected-exit yes|no(TIFF published) [event patterns...]
  local label="$1" expected="$2" tiff="$3" problems=""
  shift 3
  [ "$code" = "$expected" ] || problems+=" exit $code, expected $expected;"
  if [ "$tiff" = yes ]; then
    [ -f "$out/frame.tiff" ] || problems+=" no TIFF;"
  else
    [ ! -e "$out/frame.tiff" ] || problems+=" TIFF published;"
  fi
  ! ls "$out" | grep -q partial || problems+=" partial file left;"
  grep -q "drained to EOF" "$out/stderr" || problems+=" transfer not drained;"
  for pattern in "$@"; do grep -q "$pattern" "$out/events" || problems+=" missing $pattern;"; done
  if [ -z "$problems" ]; then
    echo "PASS: $label"
  else
    echo "FAIL: $label:$problems"
    sed 's/^/    /' "$out/stderr"
    failures=$((failures + 1))
  fi
}

start_scan slow
code=0; wait "$pid" || code=$?
check "a scan longer than the window is saved while data keeps arriving" 0 yes '"event":"file"'

start_scan cancel
wait_for parameters; kill -INT "$pid"
code=0; wait "$pid" || code=$?
check "user cancel is reported as cancel" 130 no '"event":"cancelling"' '"cancelled":true' '"timedOut":false'

start_scan stall FAKE_SANE_STALL_SECONDS=4
code=0; wait "$pid" || code=$?
check "a scanner that stops sending data is reported as timeout" 124 no '"event":"timeout"' '"timedOut":true' '"cancelled":false'

start_scan both FAKE_SANE_STALL_SECONDS=6
wait_for timeout; kill -INT "$pid"
code=0; wait "$pid" || code=$?
check "cancel after the watchdog fired is reported as cancel" 130 no '"cancelled":true' '"timedOut":false'

# A preview shows as it is read: small pictures of what has come so far, renamed into place.
extra=(--partial "$work/preview/so-far.png")
start_scan preview
code=0; wait "$pid" || code=$?
extra=()
check "a preview with pictures of it so far is still saved whole" 0 yes '"event":"partial"'
shown=$(grep -c '"event":"partial"' "$out/events" || true)
size=$(sips -g pixelWidth -g pixelHeight "$out/so-far.png" 2>/dev/null | awk '/pixel/ {print $2}' | tr '\n' ' ')
if [ "$shown" -ge 3 ] && [ -n "$size" ] && [ ! -e "$out/so-far.png.part" ]; then
  echo "PASS: $shown pictures of the preview as it was read, the last $size"
else
  echo "FAIL: pictures of the preview so far: $shown, last $size"
  failures=$((failures + 1))
fi

# The app quit mid-scan: nobody reads stdout after the first line.
out="$work/closed-stdout"
mkdir "$out"
set +e +o pipefail
"$work/SaneCapture" "$work/libfake.dylib" "$helper_dir/config" "${scan_args[@]}" \
  --output "$out/frame.tiff" 2> "$out/stderr" | head -n 1 > "$out/events"
code=${PIPESTATUS[0]}
set -e -o pipefail
check "a closed stdout does not kill the helper mid-transfer" 0 yes

if [ "$failures" -ne 0 ]; then
  echo "$failures fake-backend test(s) failed" >&2
  exit 1
fi
echo "ALL FAKE-BACKEND TESTS PASSED"
