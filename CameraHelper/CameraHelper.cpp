// Epson Scan plus's camera process: drives a Sony camera (the A7R IV on the copy stand) over
// Sony's Camera Remote SDK, and talks to the app in JSON lines, a command per line on stdin and an
// event per line on stdout. It is a process of its own, as the scanner's is: the SDK owns USB while
// it runs, cannot be started again after it is released, and a crash in it never takes the app.
//
// Commands: {"cmd":"connect","save":"<folder>"} · {"cmd":"disconnect"} · {"cmd":"props"} ·
// {"cmd":"set","name":"FNumber","value":800} · {"cmd":"live","on":true,"dir":"<folder>"} ·
// {"cmd":"af"} · {"cmd":"nearfar","step":-3} · {"cmd":"afpoint","x":320,"y":240} ·
// {"cmd":"shoot","af":false} · {"cmd":"quit"}.
// Events: ready, connected, disconnected, error, warning, props, changed, set, frame, af, shot,
// downloaded, log.

#include <unistd.h>

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <map>
#include <functional>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "CameraRemote_SDK.h"
#include "CrDeviceProperty.h"
#include "ICrCameraObjectInfo.h"
#include "IDeviceCallback.h"

namespace sdk = SCRSDK;

// MARK: Output

static std::mutex outLock;
static void emit(const std::string& json) {
  std::lock_guard<std::mutex> g(outLock);
  fputs(json.c_str(), stdout);
  fputc('\n', stdout);
  fflush(stdout);
}
static std::string quote(const std::string& s) {
  std::string out = "\"";
  for (unsigned char c : s) {
    if (c == '"' || c == '\\') { out += '\\'; out += (char)c; }
    else if (c == '\n') out += "\\n";
    else if (c < 0x20) { char b[8]; snprintf(b, sizeof b, "\\u%04x", c); out += b; }
    else out += (char)c;
  }
  return out + "\"";
}
static std::string hex(uint64_t v) {
  char b[24];
  snprintf(b, sizeof b, "0x%llx", (unsigned long long)v);
  return b;
}
static void error(const std::string& stage, uint64_t code, const std::string& message) {
  emit("{\"event\":\"error\",\"stage\":" + quote(stage) + ",\"code\":" + quote(hex(code)) + ",\"message\":" + quote(message) + "}");
}
static void logLine(const std::string& text) { emit("{\"event\":\"log\",\"text\":" + quote(text) + "}"); }

// MARK: Input

/// A command: a flat JSON object of strings, numbers and booleans.
struct Message {
  std::map<std::string, std::string> text;
  std::map<std::string, double> number;
  std::map<std::string, bool> flag;
  std::string str(const char* k) const { auto i = text.find(k); return i == text.end() ? "" : i->second; }
  double num(const char* k, double d = 0) const { auto i = number.find(k); return i == number.end() ? d : i->second; }
  bool on(const char* k, bool d = false) const { auto i = flag.find(k); return i == flag.end() ? d : i->second; }
};
static bool parse(const std::string& s, Message& m) {
  size_t i = 0;
  auto ws = [&] { while (i < s.size() && isspace((unsigned char)s[i])) i++; };
  auto string = [&](std::string& out) -> bool {
    if (i >= s.size() || s[i] != '"') return false;
    i++;
    while (i < s.size() && s[i] != '"') {
      if (s[i] == '\\' && i + 1 < s.size()) {
        i++;
        char c = s[i];
        out += c == 'n' ? '\n' : c == 't' ? '\t' : c;
      } else out += s[i];
      i++;
    }
    if (i >= s.size()) return false;
    i++;
    return true;
  };
  ws();
  if (i >= s.size() || s[i] != '{') return false;
  i++;
  for (;;) {
    ws();
    if (i < s.size() && s[i] == '}') return true;
    std::string key;
    if (!string(key)) return false;
    ws();
    if (i >= s.size() || s[i] != ':') return false;
    i++;
    ws();
    if (i < s.size() && s[i] == '"') {
      std::string v;
      if (!string(v)) return false;
      m.text[key] = v;
    } else if (s.compare(i, 4, "true") == 0) { m.flag[key] = true; i += 4; }
    else if (s.compare(i, 5, "false") == 0) { m.flag[key] = false; i += 5; }
    else if (s.compare(i, 4, "null") == 0) { i += 4; }
    else {
      char* end = nullptr;
      double v = strtod(s.c_str() + i, &end);
      if (end == s.c_str() + i) return false;
      m.number[key] = v;
      i = end - s.c_str();
    }
    ws();
    if (i < s.size() && s[i] == ',') { i++; continue; }
    if (i < s.size() && s[i] == '}') return true;
    return false;
  }
}

// MARK: Properties

struct Known { const char* name; uint32_t code; sdk::CrDataType type; };
/// The properties the app reads and sets, with the type to set them as when the camera does not
/// offer them for reading.
static const Known known[] = {
  {"ShutterSpeed", sdk::CrDeviceProperty_ShutterSpeed, sdk::CrDataType_UInt32},
  {"FNumber", sdk::CrDeviceProperty_FNumber, sdk::CrDataType_UInt16},
  {"IsoSensitivity", sdk::CrDeviceProperty_IsoSensitivity, sdk::CrDataType_UInt32},
  {"ExposureBiasCompensation", sdk::CrDeviceProperty_ExposureBiasCompensation, sdk::CrDataType_UInt16},
  {"Colortemp", sdk::CrDeviceProperty_Colortemp, sdk::CrDataType_UInt16},
  {"ExposureProgramMode", sdk::CrDeviceProperty_ExposureProgramMode, sdk::CrDataType_UInt32},
  {"FileType", sdk::CrDeviceProperty_FileType, sdk::CrDataType_UInt16},
  {"StillImageQuality", sdk::CrDeviceProperty_StillImageQuality, sdk::CrDataType_UInt16},
  {"WhiteBalance", sdk::CrDeviceProperty_WhiteBalance, sdk::CrDataType_UInt16},
  {"FocusMode", sdk::CrDeviceProperty_FocusMode, sdk::CrDataType_UInt16},
  {"FocusArea", sdk::CrDeviceProperty_FocusArea, sdk::CrDataType_UInt16},
  {"DriveMode", sdk::CrDeviceProperty_DriveMode, sdk::CrDataType_UInt32},
  {"StillImageStoreDestination", sdk::CrDeviceProperty_StillImageStoreDestination, sdk::CrDataType_UInt16},
  {"PriorityKeySettings", sdk::CrDeviceProperty_PriorityKeySettings, sdk::CrDataType_UInt16},
  {"FocusIndication", sdk::CrDeviceProperty_FocusIndication, sdk::CrDataType_UInt32},
  {"BatteryRemain", sdk::CrDeviceProperty_BatteryRemain, sdk::CrDataType_UInt16},
  {"LiveView_Image_Quality", sdk::CrDeviceProperty_LiveView_Image_Quality, sdk::CrDataType_UInt16},
  {"Focus_Magnifier_Setting", sdk::CrDeviceProperty_Focus_Magnifier_Setting, sdk::CrDataType_UInt64},
  {"AF_Area_Position", sdk::CrDeviceProperty_AF_Area_Position, sdk::CrDataType_UInt32},
  {"NearFar", sdk::CrDeviceProperty_NearFar, sdk::CrDataType_Int16},
  {"S1", sdk::CrDeviceProperty_S1, sdk::CrDataType_UInt16},
};
static const Known* byName(const std::string& name) {
  for (auto& k : known) if (name == k.name) return &k;
  return nullptr;
}
static const char* nameOf(uint32_t code) {
  for (auto& k : known) if (k.code == code) return k.name;
  return nullptr;
}
static int elementSize(uint32_t type) {
  switch (type & 0x0F) {
    case 1: return 1;
    case 2: return 2;
    case 3: return 4;
    case 4: return 8;
    default: return 0;
  }
}
static int64_t element(const uint8_t* p, uint32_t type) {
  bool sign = (type & sdk::CrDataType_SignBit) != 0;
  switch (elementSize(type)) {
    case 1: return sign ? (int64_t)*(const int8_t*)p : (int64_t)*p;
    case 2: { uint16_t v; memcpy(&v, p, 2); return sign ? (int64_t)(int16_t)v : (int64_t)v; }
    case 4: { uint32_t v; memcpy(&v, p, 4); return sign ? (int64_t)(int32_t)v : (int64_t)v; }
    case 8: { uint64_t v; memcpy(&v, p, 8); return (int64_t)v; }
    default: return 0;
  }
}
static int64_t current(const sdk::CrDeviceProperty& p) {
  uint32_t type = p.GetValueType();
  uint64_t v = p.GetCurrentValue();
  switch (elementSize(type)) {
    case 1: return (type & sdk::CrDataType_SignBit) ? (int64_t)(int8_t)v : (int64_t)(uint8_t)v;
    case 2: return (type & sdk::CrDataType_SignBit) ? (int64_t)(int16_t)v : (int64_t)(uint16_t)v;
    case 4: return (type & sdk::CrDataType_SignBit) ? (int64_t)(int32_t)v : (int64_t)(uint32_t)v;
    default: return (int64_t)v;
  }
}
static std::string describe(const sdk::CrDeviceProperty& p, const char* name) {
  uint32_t type = p.GetValueType();
  std::string out = "{\"name\":" + quote(name) + ",\"code\":" + std::to_string(p.GetCode()) + ",\"type\":" +
    std::to_string(type) + ",\"value\":" + std::to_string(current(p)) + ",\"settable\":" +
    (p.IsSetEnableCurrentValue() ? "true" : "false") + ",\"readable\":" + (p.IsGetEnableCurrentValue() ? "true" : "false") +
    ",\"values\":[";
  int size = elementSize(type);
  if (size > 0 && p.GetValues() && p.GetValueSize() > 0) {
    uint32_t n = p.GetValueSize() / size;
    for (uint32_t i = 0; i < n && i < 512; i++) {
      if (i) out += ",";
      out += std::to_string(element(p.GetValues() + i * size, type));
    }
  }
  return out + "]}";
}

// MARK: The camera

static std::atomic<int64_t> handle{0};
static std::atomic<bool> connected{false};
static std::mutex stateLock;
static std::condition_variable stateChanged;
static int connectOutcome = 0;  // 1 connected, -1 failed
static uint32_t lastFocus = 0;
static int focusSerial = 0;
static sdk::ICrEnumCameraObjectInfo* cameras = nullptr;

static bool readProp(uint32_t code, sdk::CrDeviceProperty& out) {
  sdk::CrDeviceProperty* list = nullptr;
  int32_t n = 0;
  if (sdk::GetSelectDeviceProperties(handle, 1, &code, &list, &n) != 0 || !list) return false;
  bool found = false;
  for (int32_t i = 0; i < n; i++) if (list[i].GetCode() == code) { out = list[i]; found = true; }
  sdk::ReleaseDeviceProperties(handle, list);
  return found;
}
/// Sets a property; one the camera does not offer for reading is set as the table says.
static sdk::CrError writeProp(const Known& k, int64_t value) {
  sdk::CrDeviceProperty p;
  if (!readProp(k.code, p)) {
    p.SetCode(k.code);
    p.SetValueType(k.type);
  }
  p.SetCurrentValue((uint64_t)value);
  return sdk::SetDeviceProperty(handle, &p);
}
/// Just after it connects, the camera takes nothing for a moment and says so with 0x8402 (called
/// too early): what is asked of it then is asked again, for up to three seconds.
static const sdk::CrError tooEarly = 0x8402;
static sdk::CrError patiently(const std::function<sdk::CrError()>& call) {
  sdk::CrError err = call();
  for (int i = 0; i < 15 && err == tooEarly; i++) {
    std::this_thread::sleep_for(std::chrono::milliseconds(200));
    err = call();
  }
  return err;
}

class Callback : public sdk::IDeviceCallback {
 public:
  void OnConnected(sdk::DeviceConnectionVersioin) override {
    connected = true;
    std::lock_guard<std::mutex> g(stateLock);
    connectOutcome = 1;
    stateChanged.notify_all();
  }
  void OnDisconnected(CrInt32u err) override {
    connected = false;
    emit("{\"event\":\"disconnected\",\"code\":" + quote(hex(err)) + "}");
    std::lock_guard<std::mutex> g(stateLock);
    if (connectOutcome == 0) connectOutcome = -1;
    stateChanged.notify_all();
  }
  void OnError(CrInt32u err) override {
    error("camera", err, "相机报告错误");
    std::lock_guard<std::mutex> g(stateLock);
    if (connectOutcome == 0) connectOutcome = -1;
    stateChanged.notify_all();
  }
  void OnWarning(CrInt32u w) override {
    if (w == sdk::CrWarning_Connect_Reconnecting) emit("{\"event\":\"warning\",\"code\":\"reconnecting\"}");
    else emit("{\"event\":\"warning\",\"code\":" + quote(hex(w)) + "}");
  }
  void OnWarningExt(CrInt32u w, CrInt32 a, CrInt32 b, CrInt32 c) override {
    emit("{\"event\":\"warning\",\"code\":" + quote(hex(w)) + ",\"params\":[" + std::to_string(a) + "," + std::to_string(b) + "," + std::to_string(c) + "]}");
  }
  void OnPropertyChanged() override { emit("{\"event\":\"changed\",\"codes\":[]}"); }
  void OnPropertyChangedCodes(CrInt32u num, CrInt32u* codes) override {
    std::string list;
    for (CrInt32u i = 0; i < num; i++) {
      if (codes[i] == sdk::CrDeviceProperty_FocusIndication) {
        sdk::CrDeviceProperty p;
        if (readProp(codes[i], p)) {
          std::lock_guard<std::mutex> g(stateLock);
          lastFocus = (uint32_t)p.GetCurrentValue();
          focusSerial++;
          stateChanged.notify_all();
        }
      }
      if (const char* n = nameOf(codes[i])) list += (list.empty() ? "" : ",") + quote(n);
    }
    if (!list.empty()) emit("{\"event\":\"changed\",\"names\":[" + list + "]}");
  }
  void OnCompleteDownload(CrChar* filename, CrInt32u type) override {
    emit("{\"event\":\"downloaded\",\"path\":" + quote(filename ? filename : "") + ",\"type\":" + std::to_string(type) + "}");
  }
  void OnNotifyPostViewImage(CrChar* filename, CrInt32u size) override {
    emit("{\"event\":\"postview\",\"path\":" + quote(filename ? filename : "") + "}");
  }
};
static Callback callback;

// MARK: Live view

static std::atomic<bool> liveOn{false};
static std::thread liveThread;
static std::string liveDir;

static void liveLoop() {
  std::vector<uint8_t> buffer;
  uint64_t n = 0, misses = 0;
  while (liveOn) {
    sdk::CrImageInfo info;
    sdk::CrError err = sdk::GetLiveViewImageInfo(handle, &info);
    uint32_t size = err == 0 ? info.GetBufferSize() : 0;
    if (size == 0) {
      if (++misses % 50 == 1) logLine("实时取景暂无画面：" + hex(err));
      std::this_thread::sleep_for(std::chrono::milliseconds(100));
      continue;
    }
    buffer.resize(size);
    sdk::CrImageDataBlock block;
    block.SetData(buffer.data());
    block.SetSize(size);
    err = sdk::GetLiveViewImage(handle, &block);
    if (err == 0 && block.GetImageSize() > 0 && block.GetImageData()) {
      n++;
      // Written aside and renamed into place, so the app never reads half a frame.
      std::string path = liveDir + "/live-" + std::to_string(n % 4) + ".jpg", part = path + ".part";
      if (FILE* f = fopen(part.c_str(), "wb")) {
        fwrite(block.GetImageData(), 1, block.GetImageSize(), f);
        fclose(f);
        rename(part.c_str(), path.c_str());
        emit("{\"event\":\"frame\",\"path\":" + quote(path) + ",\"n\":" + std::to_string(n) + "}");
      }
    } else if (++misses % 50 == 1) {
      logLine("实时取景读取失败：" + hex(err));
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(60));
  }
}
static void stopLive() {
  liveOn = false;
  if (liveThread.joinable()) liveThread.join();
  if (handle) sdk::SetDeviceSetting(handle, sdk::Setting_Key_EnableLiveView, 0);
}

// MARK: Commands

static void connect(const Message& m) {
  if (connected) { emit("{\"event\":\"connected\",\"again\":true}"); return; }
  if (cameras) { cameras->Release(); cameras = nullptr; }
  sdk::CrError err = sdk::EnumCameraObjects(&cameras, 3);
  if (err != 0 || !cameras || cameras->GetCount() == 0) {
    error("enum", err, "没有找到相机：请确认已用 USB 连接、开机，且相机的 USB 连接方式是「PC 遥控」；照片、图像捕捉等 App 开着时可能占住相机");
    return;
  }
  uint32_t pick = 0;
  for (uint32_t i = 0; i < cameras->GetCount(); i++) {
    const char* model = cameras->GetCameraObjectInfo(i)->GetModel();
    if (model && strstr(model, "7RM4")) { pick = i; break; }
  }
  auto* info = const_cast<sdk::ICrCameraObjectInfo*>(cameras->GetCameraObjectInfo(pick));
  std::string model = info->GetModel() ? info->GetModel() : "Sony";
  {
    std::lock_guard<std::mutex> g(stateLock);
    connectOutcome = 0;
  }
  int64_t h = 0;
  err = sdk::Connect(info, &callback, &h, sdk::CrSdkControlMode_Remote, sdk::CrReconnecting_ON);
  if (err != 0) { error("connect", err, "连接相机失败"); return; }
  handle = h;
  {
    std::unique_lock<std::mutex> g(stateLock);
    stateChanged.wait_for(g, std::chrono::seconds(15), [] { return connectOutcome != 0; });
    if (connectOutcome != 1) {
      g.unlock();
      error("connect", 0, connectOutcome == 0 ? "等待相机响应超时" : "相机拒绝了连接");
      sdk::ReleaseDevice(handle);
      handle = 0;
      return;
    }
  }
  std::string save = m.str("save");
  if (!save.empty()) {
    err = sdk::SetSaveInfo(handle, const_cast<CrChar*>(save.c_str()), const_cast<CrChar*>("EPS"), -1);
    if (err) error("save", err, "设定保存文件夹失败");
  }
  // The app sets focus, exposure and drive mode, not the camera's dials.
  if (auto k = byName("PriorityKeySettings")) {
    err = patiently([&] { return writeProp(*k, sdk::CrPriorityKey_PCRemote); });
    if (err) logLine("切换到电脑优先失败：" + hex(err));
  }
  if (auto k = byName("StillImageStoreDestination")) {
    int64_t store = m.on("card") ? sdk::CrStillImageStoreDestination_HostPCAndMemoryCard : sdk::CrStillImageStoreDestination_HostPC;
    err = patiently([&] { return writeProp(*k, store); });
    if (err) logLine("设定保存位置失败：" + hex(err));
  }
  if (auto k = byName("LiveView_Image_Quality")) patiently([&] { return writeProp(*k, sdk::CrPropertyLiveViewImageQuality_High); });
  emit("{\"event\":\"connected\",\"model\":" + quote(model) + ",\"cameras\":" + std::to_string(cameras->GetCount()) + "}");
}
static void disconnect() {
  stopLive();
  if (!handle) return;
  if (connected) {
    sdk::Disconnect(handle);
    std::unique_lock<std::mutex> g(stateLock);
    stateChanged.wait_for(g, std::chrono::seconds(3), [] { return !connected.load(); });
  }
  sdk::ReleaseDevice(handle);
  handle = 0;
  connected = false;
}
static void props() {
  std::vector<CrInt32u> codes;
  for (auto& k : known) codes.push_back(k.code);
  sdk::CrDeviceProperty* list = nullptr;
  int32_t n = 0;
  sdk::CrError err = patiently([&] { return sdk::GetSelectDeviceProperties(handle, (CrInt32u)codes.size(), codes.data(), &list, &n); });
  if (err != 0 || !list) { error("props", err, "读取相机设置失败"); return; }
  std::string out = "{\"event\":\"props\",\"props\":[";
  bool first = true;
  for (int32_t i = 0; i < n; i++) {
    const char* name = nameOf(list[i].GetCode());
    if (!name) continue;
    out += (first ? "" : ",") + describe(list[i], name);
    first = false;
  }
  sdk::ReleaseDeviceProperties(handle, list);
  emit(out + "]}");
}
static void set(const Message& m) {
  const Known* k = byName(m.str("name"));
  if (!k) { error("set", 0, "未知的设置：" + m.str("name")); return; }
  sdk::CrError err = writeProp(*k, (int64_t)m.num("value"));
  emit("{\"event\":\"set\",\"name\":" + quote(k->name) + ",\"ok\":" + (err ? "false" : "true") + ",\"code\":" + quote(hex(err)) + "}");
}
/// Half-presses the shutter and waits for the camera to say whether it focused.
static std::string autofocus() {
  const Known* s1 = byName("S1");
  int serial;
  {
    std::lock_guard<std::mutex> g(stateLock);
    serial = focusSerial;
  }
  sdk::CrError err = writeProp(*s1, sdk::CrLockIndicator_Locked);
  if (err) { error("af", err, "半按快门失败"); return "error"; }
  std::string result = "timeout";
  {
    std::unique_lock<std::mutex> g(stateLock);
    auto until = std::chrono::steady_clock::now() + std::chrono::seconds(4);
    while (std::chrono::steady_clock::now() < until) {
      if (!stateChanged.wait_until(g, until, [&] { return focusSerial != serial; })) break;
      serial = focusSerial;
      if (lastFocus == sdk::CrFocusIndicator_Focused_AF_S || lastFocus == sdk::CrFocusIndicator_Focused_AF_C) { result = "focused"; break; }
      if (lastFocus == sdk::CrFocusIndicator_NotFocused_AF_S || lastFocus == sdk::CrFocusIndicator_NotFocused_AF_C) { result = "failed"; break; }
    }
  }
  return result;
}
static void releaseS1() {
  if (auto s1 = byName("S1")) writeProp(*s1, sdk::CrLockIndicator_Unlocked);
}
/// The shutter: in an autofocus mode half-pressed until the camera has focused, as its own button
/// is, since with focus first a full press alone ends before it can focus and nothing is taken;
/// then pressed fully, and the half-press let go once the picture is taken.
static void shoot(const Message& m) {
  std::string focus = "skipped";
  if (m.on("af")) focus = autofocus();
  sdk::CrError err = sdk::SendCommand(handle, sdk::CrCommandId_Release, sdk::CrCommandParam_Down);
  std::this_thread::sleep_for(std::chrono::milliseconds(35));
  if (!err) err = sdk::SendCommand(handle, sdk::CrCommandId_Release, sdk::CrCommandParam_Up);
  if (m.on("af")) {
    std::this_thread::sleep_for(std::chrono::milliseconds(500));
    releaseS1();
  }
  emit("{\"event\":\"shot\",\"ok\":" + std::string(err ? "false" : "true") + ",\"code\":" + quote(hex(err)) + ",\"focus\":" + quote(focus) + "}");
}

int main(int argc, char** argv) {
  setvbuf(stdout, nullptr, _IOLBF, 0);
  if (!sdk::Init()) {
    error("init", 0, "Sony Camera Remote SDK 启动失败");
    return 2;
  }
  emit("{\"event\":\"ready\",\"sdk\":" + quote(hex(sdk::GetSDKVersion())) + "}");
  if (argc > 1 && strcmp(argv[1], "--probe") == 0) {
    sdk::Release();
    return 0;
  }
  char* line = nullptr;
  size_t capacity = 0;
  while (getline(&line, &capacity, stdin) > 0) {
    Message m;
    if (!parse(line, m)) { error("parse", 0, std::string("看不懂的命令：") + line); continue; }
    std::string cmd = m.str("cmd");
    if (cmd == "quit") break;
    if (cmd == "connect") { connect(m); continue; }
    if (cmd == "disconnect") { disconnect(); emit("{\"event\":\"disconnected\",\"code\":\"0x0\"}"); continue; }
    if (!connected || !handle) { error(cmd, 0, "相机没有连接"); continue; }
    if (cmd == "props") props();
    else if (cmd == "set") set(m);
    else if (cmd == "live") {
      if (m.on("on")) {
        if (!liveOn) {
          liveDir = m.str("dir");
          sdk::CrError err = sdk::SetDeviceSetting(handle, sdk::Setting_Key_EnableLiveView, 1);
          if (err) logLine("打开实时取景：" + hex(err));
          liveOn = true;
          liveThread = std::thread(liveLoop);
        }
      } else stopLive();
      emit(std::string("{\"event\":\"live\",\"on\":") + (liveOn ? "true" : "false") + "}");
    } else if (cmd == "af") {
      std::string result = autofocus();
      releaseS1();
      emit("{\"event\":\"af\",\"result\":" + quote(result) + "}");
    } else if (cmd == "nearfar") {
      // The lens steps only in manual focus: switched to it first when the app sees it is not.
      if (m.on("mf")) {
        sdk::CrError e = writeProp(*byName("FocusMode"), sdk::CrFocus_MF);
        logLine(e ? "切到手动对焦失败：" + hex(e) : "已切到手动对焦");
        std::this_thread::sleep_for(std::chrono::milliseconds(300));
      }
      sdk::CrError err = writeProp(*byName("NearFar"), (int64_t)m.num("step"));
      emit("{\"event\":\"set\",\"name\":\"NearFar\",\"ok\":" + std::string(err ? "false" : "true") + ",\"code\":" + quote(hex(err)) + "}");
    } else if (cmd == "afpoint") {
      int64_t x = (int64_t)m.num("x", 320), y = (int64_t)m.num("y", 240);
      sdk::CrError err = writeProp(*byName("AF_Area_Position"), (x << 16) | y);
      emit("{\"event\":\"set\",\"name\":\"AF_Area_Position\",\"ok\":" + std::string(err ? "false" : "true") + ",\"code\":" + quote(hex(err)) + "}");
    } else if (cmd == "shoot") shoot(m);
    else error(cmd, 0, "未知的命令");
  }
  free(line);
  disconnect();
  if (cameras) cameras->Release();
  sdk::Release();
  return 0;
}
