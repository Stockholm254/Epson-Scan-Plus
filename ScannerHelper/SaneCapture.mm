// SPDX-License-Identifier: GPL-2.0-only
// Epson Scan plus experimental USB capture helper. SANE stays in this process.
#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#include <sane/sane.h>
#include <dlfcn.h>
#include <signal.h>
#include <sys/file.h>
#include <fcntl.h>
#include <unistd.h>
#include <cmath>
#include <stdexcept>
#include <vector>

// SIGINT/SIGTERM are a user cancel; SIGALRM means the scanner sent no data for
// stallSeconds. Both stop after the current transfer drains, but are reported separately.
// A slow scan that keeps delivering data re-arms the alarm and is never discarded.
// Tests compile a short window with -DSTALL_SECONDS=n.
#ifndef STALL_SECONDS
#define STALL_SECONDS (5 * 60)
#endif
static const unsigned stallSeconds = STALL_SECONDS;
static volatile sig_atomic_t cancelled = 0, timedOut = 0;
static void cancel_signal(int n) { if (n == SIGALRM) timedOut = 1; else cancelled = 1; }
static bool stopping() { return cancelled || timedOut; }
static const char *stopMessage() {
  return cancelled ? "扫描已取消" : "扫描仪超过 5 分钟没有返回数据，本张未保存，后续不再扫描。请检查扫描仪，必要时关机再开机。";
}
static void emit(NSDictionary *event) {
  NSData *data = [NSJSONSerialization dataWithJSONObject:event options:0 error:nil];
  fwrite(data.bytes, 1, data.length, stdout); fputc('\n', stdout); fflush(stdout);
}
static void require(bool ok, const char *message) { if (!ok) throw std::runtime_error(message); }
#define API(name) __typeof__(name) *name = nullptr
struct Sane {
  API(sane_init); API(sane_exit); API(sane_get_devices); API(sane_open); API(sane_close);
  API(sane_get_option_descriptor); API(sane_control_option); API(sane_get_parameters);
  API(sane_start); API(sane_read); API(sane_cancel); API(sane_strstatus);
  void *library = nullptr;
  SANE_Handle handle = nullptr;
  bool initialized = false, scanning = false;
  ~Sane() {
    // On an unexpected exception, finish the existing transfer before closing.
    // The GT-X980's mid-transfer CAN path failed reconnection in hardware testing.
    // No new scan is started; a normal user cancel also drains below and publishes no TIFF.
    if (handle && scanning) {
      SANE_Byte buffer[65536]; SANE_Int count;
      // 768 MiB is our maximum frame size; allow enough calls to drain it.
      for (int i = 0; i < 32768; i++) {
        SANE_Status st = sane_read(handle, buffer, sizeof(buffer), &count);
        if (st != SANE_STATUS_GOOD) break;
      }
    }
    if (handle) sane_close(handle);
    if (initialized) sane_exit();
    if (library) dlclose(library);
  }
  void check(SANE_Status status, const char *operation) {
    if (status != SANE_STATUS_GOOD)
      throw std::runtime_error(std::string(operation) + ": " + sane_strstatus(status));
  }
  void open(NSString *path) {
    library = dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
    if (!library) throw std::runtime_error(dlerror());
#define LOAD(name) name = (__typeof__(name))dlsym(library, #name); require(name, "Incomplete SANE backend")
    LOAD(sane_init); LOAD(sane_exit); LOAD(sane_get_devices); LOAD(sane_open); LOAD(sane_close);
    LOAD(sane_get_option_descriptor); LOAD(sane_control_option); LOAD(sane_get_parameters);
    LOAD(sane_start); LOAD(sane_read); LOAD(sane_cancel); LOAD(sane_strstatus);
#undef LOAD
    SANE_Int version; check(sane_init(&version, nullptr), "sane_init"); initialized = true;
    // Discovery should fail promptly on an unresponsive USB device. Actual scan
    // transfers retain the backend's 60-second allowance for warmup/mechanics.
    auto usbTimeout = (void (*)(SANE_Int))dlsym(library, "sanei_usb_set_timeout");
    if (usbTimeout) usbTimeout(5000);
    const SANE_Device **devices = nullptr;
    check(sane_get_devices(&devices, SANE_TRUE), "discover");
    require(devices && devices[0], "没有找到可响应的 V800/V850。请检查 USB、关闭其他扫描程序；若刚发生中途停止或断线，请重启扫描仪。");
    require(!devices[1], "找到多台扫描仪。实验接口暂只支持连接一台 V800/V850。");
    require(strstr(devices[0]->name, "libusb:") == devices[0]->name, "USB device required");
    check(sane_open(devices[0]->name, &handle), "open scanner");
    if (usbTimeout) usbTimeout(60000);
  }
  int option(const char *name) {
    SANE_Int count = 0; check(sane_control_option(handle, 0, SANE_ACTION_GET_VALUE, &count, nullptr), "option count");
    for (int i = 1; i < count; i++) {
      auto d = sane_get_option_descriptor(handle, i);
      if (d && d->name && !strcmp(d->name, name)) return i;
    }
    throw std::runtime_error(std::string("Missing scanner option: ") + name);
  }
  void set(const char *name, const char *string, double number = 0) {
    int i = option(name); auto d = sane_get_option_descriptor(handle, i);
    require(SANE_OPTION_IS_ACTIVE(d->cap) && (d->cap & SANE_CAP_SOFT_SELECT), "Inactive scanner option");
    std::vector<char> value(d->size + 1, 0);
    SANE_Word word = d->type == SANE_TYPE_FIXED ? SANE_FIX(number) : (SANE_Word)number;
    if (string) { require(strlen(string) < (size_t)d->size, "Invalid scanner string"); strcpy(value.data(), string); }
    else { require(d->size == sizeof(word), "Invalid scanner numeric option"); memcpy(value.data(), &word, sizeof(word)); }
    check(sane_control_option(handle, i, SANE_ACTION_SET_VALUE, value.data(), nullptr), name);
    check(sane_control_option(handle, i, SANE_ACTION_GET_VALUE, value.data(), nullptr), name);
    if (string) require(!strcmp(string, value.data()), "Scanner rejected requested setting");
    else require(*(SANE_Word *)value.data() == word, "Scanner changed requested setting");
  }
  double maximum(const char *name) {
    auto d = sane_get_option_descriptor(handle, option(name));
    require(d && d->constraint_type == SANE_CONSTRAINT_RANGE, "Missing scan area range");
    return SANE_UNFIX(d->constraint.range->max);
  }
  NSArray *resolutions() {
    auto d = sane_get_option_descriptor(handle, option("resolution"));
    NSMutableArray *result = [NSMutableArray array];
    for (int dpi : {150, 300, 600, 1200, 1800, 2400, 3200, 4800, 6400}) {
      bool found = false;
      if (d->constraint_type == SANE_CONSTRAINT_WORD_LIST)
        for (int j = 1; j <= d->constraint.word_list[0]; j++) found |= d->constraint.word_list[j] == dpi;
      if (found) [result addObject:@(dpi)];
    }
    return result;
  }
  void configure() {
    set("source", "Transparency Unit"); set("mode", "Color"); set("depth", nullptr, 16);
    set("film-type", "Positive Film"); set("color-correction", "None");
    set("gamma-correction", "User defined");
    // Identity LUT on all channels: leave tonal decoding explicit, inputGamma = 1.
    for (auto name : {"red-gamma-table", "green-gamma-table", "blue-gamma-table"}) {
      int i = option(name); auto d = sane_get_option_descriptor(handle, i);
      require(d->size == 256 * sizeof(SANE_Word), "Unsupported gamma table size");
      SANE_Word table[256]; for (int j = 0; j < 256; j++) table[j] = j;
      check(sane_control_option(handle, i, SANE_ACTION_SET_VALUE, table, nullptr), name);
      check(sane_control_option(handle, i, SANE_ACTION_GET_VALUE, table, nullptr), name);
      for (int j = 0; j < 256; j++) require(table[j] == j, "Gamma table readback mismatch");
    }
    set("sharpness", nullptr, 0); set("mirror", nullptr, 0); set("preview", nullptr, 0);
    set("wait-for-button", nullptr, 0); set("autofocus", nullptr, 0);
    // Source selection above chooses the manufacturer's film-holder focus position.
  }
};

static void writeTIFF(NSString *output, const std::vector<uint8_t>& data, const SANE_Parameters& p, int dpi) {
  require(![[NSFileManager defaultManager] fileExistsAtPath:output], "Output already exists; refusing to overwrite");
  NSString *temp = [output stringByAppendingFormat:@".partial-%@", NSUUID.UUID.UUIDString];
  CGDataProviderRef provider = CGDataProviderCreateWithData(nullptr, data.data(), data.size(), nullptr);
  CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceLinearSRGB);
  CGImageRef image = CGImageCreate(p.pixels_per_line, p.lines, 16, 48, p.bytes_per_line, space,
    kCGBitmapByteOrder16Little | kCGImageAlphaNone, provider, nullptr, false, kCGRenderingIntentDefault);
  CGColorSpaceRelease(space); CGDataProviderRelease(provider);
  require(image, "Cannot create RGB48 image");
  CGImageDestinationRef dest = CGImageDestinationCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:temp], CFSTR("public.tiff"), 1, nullptr);
  if (!dest) { CGImageRelease(image); throw std::runtime_error("Cannot create TIFF"); }
  NSDictionary *properties = @{
    (__bridge NSString *)kCGImagePropertyDPIWidth:@(dpi), (__bridge NSString *)kCGImagePropertyDPIHeight:@(dpi),
    (__bridge NSString *)kCGImagePropertyOrientation:@1,
    (__bridge NSString *)kCGImagePropertyTIFFDictionary:@{
      (__bridge NSString *)kCGImagePropertyTIFFCompression:@1,
      (__bridge NSString *)kCGImagePropertyTIFFSoftware:@"Epson Scan plus · epson2 RGB48 · identity gamma · no CCT",
      (__bridge NSString *)kCGImagePropertyTIFFImageDescription:@"Uninverted RGB16/channel, identity scanner LUT, input gamma 1.0. Linear RGB encoding tag is not a calibrated scanner ICC profile."}};
  CGImageDestinationAddImage(dest, image, (__bridge CFDictionaryRef)properties);
  bool success = CGImageDestinationFinalize(dest);
  CFRelease(dest); CGImageRelease(image);
  if (!success || stopping()) { unlink(temp.fileSystemRepresentation); throw std::runtime_error(stopping() ? stopMessage() : "TIFF write failed"); }
  // Same-directory link is atomic and fails if another writer created the final name.
  if (link(temp.fileSystemRepresentation, output.fileSystemRepresentation)) {
    unlink(temp.fileSystemRepresentation); throw std::runtime_error("Cannot publish TIFF without overwriting");
  }
  unlink(temp.fileSystemRepresentation);
}

int main(int argc, char **argv) {
  @autoreleasepool {
    setbuf(stdout, nullptr);
    signal(SIGINT, cancel_signal); signal(SIGTERM, cancel_signal); signal(SIGALRM, cancel_signal);
    // If the app quits mid-scan, writing progress to its closed pipe must not
    // kill this process before the current transfer drains.
    signal(SIGPIPE, SIG_IGN);
    alarm(stallSeconds);
    try {
      require(argc == 4 || argc == 11, "Usage: SaneCapture backend config --probe | --scan dpi x y width height output");
      setenv("SANE_CONFIG_DIR", argv[2], 1);
      // Only serialize this app's helpers; never steal a vendor driver's session.
      NSString *lockPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"EpsonScanPlus-V850-usb.lock"];
      int lock = open(lockPath.fileSystemRepresentation, O_CREAT | O_RDWR | O_NOFOLLOW, 0600);
      require(lock >= 0 && flock(lock, LOCK_EX | LOCK_NB) == 0, "扫描接口正在使用中，请等待当前操作结束。");
      Sane s; s.open([NSString stringWithUTF8String:argv[1]]); s.configure();
      double bedW = s.maximum("br-x"), bedH = s.maximum("br-y");
      require(bedW > 100 && bedW <= 151 && bedH > 200 && bedH <= 247, "Unexpected V850 transparency scan area");
      NSArray *resolutions = s.resolutions();
      emit(@{@"event":@"capabilities", @"name":@"EPSON V800/V850 · GT-X980", @"bits":@16,
        @"widthMM":@(bedW), @"heightMM":@(bedH), @"dpi":resolutions,
        @"backend":@"epson2-linear-v1", @"inputGamma":@1.0});
      if (argc == 4) { require(!strcmp(argv[3], "--probe"), "Invalid mode"); return 0; }
      require(!strcmp(argv[3], "--scan"), "Invalid mode");
      auto number = [](char *arg) { char *end = nullptr; double v = strtod(arg, &end); require(end && !*end && std::isfinite(v), "Invalid scan number"); return v; };
      double requestedDPI = number(argv[4]); int dpi = (int)requestedDPI;
      double x = number(argv[5]), y = number(argv[6]), w = number(argv[7]), h = number(argv[8]);
      require(dpi == requestedDPI && [resolutions containsObject:@(dpi)], "Unsupported scan resolution");
      require(x >= 0 && y >= 0 && w >= 0.5 && h >= 0.5 && x + w <= bedW + 0.0001 && y + h <= bedH + 0.0001, "Scan rectangle outside transparency area");
      require(!strcmp(argv[9], "--output"), "Missing output flag");
      NSString *output = [NSString stringWithUTF8String:argv[10]];
      require(output.isAbsolutePath && ![[NSFileManager defaultManager] fileExistsAtPath:output], "Output must be a new absolute path");
      // epson2 rounds width down to eight pixels. Request an outward-aligned
      // footprint and report its real extent, so crop coordinates do not stretch.
      // Fixed-point upper bounds sit just above the pixel boundary; this also
      // avoids epson2's integer-mm bottom-edge clamp when nearest rounding wins.
      double pixelsPerMM = dpi / 25.4;
      int left = (int)floor(x * pixelsPerMM), top = (int)floor(y * pixelsPerMM);
      int maxRight = (int)floor(bedW * pixelsPerMM), maxBottom = (int)floor(bedH * pixelsPerMM);
      int width = ((int)ceil((x + w) * pixelsPerMM) - left + 7) / 8 * 8;
      width = std::min(width, (maxRight - left) / 8 * 8);
      int bottom = std::min((int)ceil((y + h) * pixelsPerMM), maxBottom);
      auto upperFixed = [](double mm) { return ceil(mm * 65536.0) / 65536.0; };
      double scanX = left / pixelsPerMM, scanY = top / pixelsPerMM;
      double scanRight = upperFixed((left + width) / pixelsPerMM), scanBottom = upperFixed(bottom / pixelsPerMM);
      require(width > 0 && bottom > top && scanRight <= bedW && scanBottom <= bedH, "Aligned scan outside transparency area");
      s.set("resolution", nullptr, dpi);
      s.set("tl-x", nullptr, scanX); s.set("tl-y", nullptr, scanY);
      s.set("br-x", nullptr, scanRight); s.set("br-y", nullptr, scanBottom);
      SANE_Parameters p; s.check(s.sane_get_parameters(s.handle, &p), "scan parameters");
      auto validate = [&]() {
        require(p.format == SANE_FRAME_RGB && p.depth == 16 && p.last_frame && p.lines > 0 && p.pixels_per_line > 0,
          "Scanner did not accept RGB48");
        require(p.bytes_per_line >= p.pixels_per_line * 6 && p.bytes_per_line <= p.pixels_per_line * 6 + 256,
          "Unexpected RGB48 stride");
        require(std::abs(p.pixels_per_line - w / 25.4 * dpi) <= 16 && std::abs(p.lines - h / 25.4 * dpi) <= 16,
          "Unexpected scan dimensions");
        require((uint64_t)p.bytes_per_line * p.lines <= 768ULL * 1024 * 1024, "扫描区域过大，请降低 dpi 或逐张扫描。");
      };
      validate();
      require(!stopping(), stopMessage());
      s.scanning = true; s.check(s.sane_start(s.handle), "start scan");
      s.check(s.sane_get_parameters(s.handle, &p), "actual scan parameters"); validate();
      emit(@{@"event":@"parameters", @"width":@(p.pixels_per_line), @"height":@(p.lines), @"bits":@16, @"dpi":@(dpi)});
      size_t bytes = (size_t)p.bytes_per_line * p.lines, count = 0;
      std::vector<uint8_t> data(bytes), buffer(65536);
      bool cancellationReported = false, timeoutReported = false;
      while (true) {
        if (cancelled && !cancellationReported) {
          emit(@{@"event":@"cancelling", @"message":@"等待当前扫描完成归位，不保存本张、不再扫描下一张"});
          cancellationReported = true;
        }
        if (timedOut && !timeoutReported) {
          emit(@{@"event":@"timeout", @"message":@"扫描仪 5 分钟没有返回数据：等待当前传输结束，不保存本张、不再扫描下一张"});
          timeoutReported = true;
        }
        SANE_Int n = 0; SANE_Status status = s.sane_read(s.handle, buffer.data(), (SANE_Int)buffer.size(), &n);
        require(n >= 0 && count + n <= bytes, "Scan buffer overflow");
        if (!stopping()) memcpy(data.data() + count, buffer.data(), n);
        if (n && !timedOut) alarm(stallSeconds);
        count += n;
        if (n) emit(@{@"event":@"progress", @"value":@(0.98 * count / bytes)});
        // The transfer is complete; writing the TIFF must not count as a stalled scanner.
        if (status == SANE_STATUS_EOF) { s.scanning = false; alarm(0); break; }
        s.check(status, "read scan data");
      }
      require(!stopping() && count == bytes && !s.scanning, stopping() ? stopMessage() : "Incomplete scan data");
      writeTIFF(output, data, p, dpi);
      emit(@{@"event":@"file", @"path":output, @"bits":@16, @"width":@(p.pixels_per_line), @"height":@(p.lines), @"dpi":@(dpi),
        @"xMM":@(scanX), @"yMM":@(scanY), @"widthMM":@(p.pixels_per_line / pixelsPerMM), @"heightMM":@(p.lines / pixelsPerMM)});
      return 0;
    } catch (const std::exception& e) {
      // A user cancel takes precedence when both happened. Exit 124 follows timeout(1).
      bool limitReached = !cancelled && timedOut;
      emit(@{@"event":@"error", @"message":[NSString stringWithUTF8String:e.what()] ?: @"Scanner error",
        @"cancelled":@(cancelled != 0), @"timedOut":@(limitReached)});
      return cancelled ? 130 : limitReached ? 124 : 1;
    }
  }
}
