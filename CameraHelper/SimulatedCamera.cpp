// A simulated A7R IV behind the Camera Remote SDK's functions, for testing the camera process
// without a camera: linked in place of Sony's library, it answers as the camera on the copy stand
// was seen to, including where it was hard to work with.
//
// - Just after it connects it answers 0x8402 (called too early) for a moment.
// - It starts with the camera's own priority, and takes a press then without doing anything.
// - In an autofocus mode (DMF among them) a full press takes a picture only once a half-press has
//   focused: focus first.
// - A press held for less than a moment is not taken.
// - While it writes and sends a picture it takes no new one, and says nothing.
// - A focus step outside manual focus is refused with the 0x60003 warning on NearFar.
// - Changing the focus mode ends its magnifier.
// - Set up so (busy), for a while after a half-press is let go it takes a change of focus mode and
//   does not make it; set up so (stepsneed), with its own priority it takes a focus step and the
//   lens does not move.
// - Each half-press that focuses, and each step the lens makes, goes to stderr.
//
// EPSON_CAMERA_SIM sets it up, as name=value pairs separated by commas: focus (the focus mode, 6
// DMF), priority (1 the camera's, 2 the computer's), early (milliseconds of 0x8402 after connecting,
// 600), transfer (milliseconds a picture takes to arrive, 1500), af (ok or fail), hold (the
// shortest press taken, in milliseconds, 100), cameras (1; 0 for none found), refuse (0; 1 for a
// camera another program has a session with, which refuses the connection), busy (milliseconds
// after a half-press is let go that a change of focus mode is not made, 0), stepsneed (1: a focus
// step needs the computer's priority, 0). EPSON_CAMERA_SIM_LIVE
// names a JPEG for its live view. What it does with a press goes to stderr, a line each.
//
// Not Sony's code: the functions and classes the camera process uses, declared by Sony's headers,
// implemented here from what they are documented and seen to do.

#include <unistd.h>

#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <functional>
#include <map>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "CameraRemote_SDK.h"
#include "CrDeviceProperty.h"
#include "ICrCameraObjectInfo.h"
#include "IDeviceCallback.h"

using namespace SCRSDK;
using Clock = std::chrono::steady_clock;

namespace {

int setting(const char* name, int fallback) {
  const char* all = getenv("EPSON_CAMERA_SIM");
  if (!all) return fallback;
  std::string s = std::string(",") + all + ",", key = std::string(",") + name + "=";
  size_t at = s.find(key);
  if (at == std::string::npos) return fallback;
  std::string value = s.substr(at + key.size(), s.find(',', at + key.size()) - at - key.size());
  if (value == "ok") return 1;
  if (value == "fail") return 0;
  return atoi(value.c_str());
}
void say(const std::string& text) {
  fprintf(stderr, "模拟相机：%s\n", text.c_str());
  fflush(stderr);
}
void later(int ms, std::function<void()> work) {
  std::thread([ms, work] {
    std::this_thread::sleep_for(std::chrono::milliseconds(ms));
    work();
  }).detach();
}

struct Camera {
  std::mutex lock;
  IDeviceCallback* callback = nullptr;
  Clock::time_point connectedAt;
  int early = 600, transfer = 1500, hold = 100, busy = 0;
  bool focuses = true, stepsNeedPriority = false;
  Clock::time_point letGo;
  std::map<CrInt32u, int64_t> values;
  bool halfPressed = false, focused = false, sending = false;
  Clock::time_point downAt;
  bool down = false;
  int pictures = 0;
  std::string folder = ".", prefix = "DSC";
  bool live = false;
  /// The live view's last picture, as the camera hands it over.
  std::vector<CrInt8u> frame;
} camera;

bool tooEarly() {
  std::lock_guard<std::mutex> g(camera.lock);
  return Clock::now() < camera.connectedAt + std::chrono::milliseconds(camera.early);
}
bool autofocusing() { return camera.values[CrDeviceProperty_FocusMode] >= 2 && camera.values[CrDeviceProperty_FocusMode] <= 6; }
void changed(std::vector<CrInt32u> codes) {
  later(30, [codes]() mutable {
    if (camera.callback) camera.callback->OnPropertyChangedCodes((CrInt32u)codes.size(), codes.data());
  });
}

/// The values the camera offers for a property, and the size of each.
std::pair<std::vector<int64_t>, int> offered(CrInt32u code) {
  switch (code) {
    case CrDeviceProperty_FocusMode: return {{2, 4, 3, 6, 1}, 2};
    case CrDeviceProperty_Focus_Magnifier_Setting:
      return {{0xFFFFFFFFLL, (10LL << 32) | 0xFFFFFFFF, (59LL << 32) | 0xFFFFFFFF, (119LL << 32) | 0xFFFFFFFF}, 8};
    case CrDeviceProperty_PriorityKeySettings: return {{1, 2}, 2};
    case CrDeviceProperty_FNumber: return {{400, 560, 800, 1100}, 2};
    default: return {{}, 0};
  }
}
CrDataType typeOf(CrInt32u code) {
  switch (code) {
    case CrDeviceProperty_Focus_Magnifier_Setting: return CrDataType_UInt64;
    case CrDeviceProperty_FocusIndication: case CrDeviceProperty_AF_Area_Position: return CrDataType_UInt32;
    case CrDeviceProperty_NearFar: return CrDataType_Int16;
    default: return CrDataType_UInt16;
  }
}

struct Info : ICrCameraObjectInfo {
  CrChar name[16] = "ILCE-7RM4", model[16] = "ILCE-7RM4", none[1] = "";
  CrInt8u id[4] = {1, 2, 3, 4};
  void Release() override {}
  CrChar* GetName() const override { return const_cast<CrChar*>(name); }
  CrInt32u GetNameSize() const override { return 9; }
  CrChar* GetModel() const override { return const_cast<CrChar*>(model); }
  CrInt32u GetModelSize() const override { return 9; }
  CrInt16 GetUsbPid() const override { return 0x0CCC; }
  CrInt8u* GetId() const override { return const_cast<CrInt8u*>(id); }
  CrInt32u GetIdSize() const override { return 4; }
  CrInt32u GetIdType() const override { return 0; }
  CrInt32u GetConnectionStatus() const override { return 0; }
  CrChar* GetConnectionTypeName() const override { return const_cast<CrChar*>(none); }
  CrChar* GetAdaptorName() const override { return const_cast<CrChar*>(none); }
  CrChar* GetGuid() const override { return const_cast<CrChar*>(none); }
  CrChar* GetPairingNecessity() const override { return const_cast<CrChar*>(none); }
  CrInt16u GetAuthenticationState() const override { return 0; }
  CrInt32u GetSSHsupport() const override { return 0; }
  CrInt32u GetIPAddress() const override { return 0; }
  CrChar* GetIPAddressChar() const override { return const_cast<CrChar*>(none); }
  CrInt32u GetIPAddressCharSize() const override { return 0; }
  CrInt8u* GetMACAddress() const override { return const_cast<CrInt8u*>(id); }
  CrInt32u GetMACAddressSize() const override { return 0; }
  CrChar* GetMACAddressChar() const override { return const_cast<CrChar*>(none); }
  CrInt32u GetMACAddressCharSize() const override { return 0; }
} info;
struct Found : ICrEnumCameraObjectInfo {
  CrInt32u count = 1;
  CrInt32u GetCount() const override { return count; }
  const ICrCameraObjectInfo* GetCameraObjectInfo(CrInt32u) const override { return &info; }
  void Release() override {}
} found;

/// The full press let go: a picture, unless the camera has a reason to take none.
void released(int heldMs) {
  std::string why;
  {
    std::lock_guard<std::mutex> g(camera.lock);
    if (camera.values[CrDeviceProperty_PriorityKeySettings] != CrPriorityKey_PCRemote) why = "相机优先，按键不生效";
    else if (heldMs < camera.hold) why = "按住 " + std::to_string(heldMs) + " ms，太短";
    else if (camera.sending) why = "上一张还在传输";
    else if (autofocusing() && !(camera.halfPressed && camera.focused)) why = "对焦优先，没有合焦";
    else camera.sending = true;
  }
  if (!why.empty()) return say("快门被忽略（" + why + "）");
  int n;
  std::string path;
  {
    std::lock_guard<std::mutex> g(camera.lock);
    n = ++camera.pictures;
    char name[32];
    snprintf(name, sizeof name, "%s%05d.ARW", camera.prefix.c_str(), n);
    path = camera.folder + "/" + name;
  }
  say("拍摄第 " + std::to_string(n) + " 张");
  later(camera.transfer, [path] {
    if (FILE* f = fopen(path.c_str(), "wb")) {
      std::vector<char> bytes(4096, 0);
      fwrite(bytes.data(), 1, bytes.size(), f);
      fclose(f);
    }
    {
      std::lock_guard<std::mutex> g(camera.lock);
      camera.sending = false;
    }
    std::vector<CrChar> name(path.begin(), path.end());
    name.push_back(0);
    if (camera.callback) camera.callback->OnCompleteDownload(name.data(), 1);
  });
}

}  // namespace

// MARK: The classes

namespace SCRSDK {

CrDeviceProperty::CrDeviceProperty()
  : code(0), valueType(CrDataType_UInt16), enableFlag(CrEnableValue_True), variableFlag(CrEnableValue_Variable),
    currentValue(0), currentStr(nullptr), valuesSize(0), values(nullptr), getSetValuesSize(0), getSetValues(nullptr) {}
CrDeviceProperty::~CrDeviceProperty() { delete[] values; }
CrDeviceProperty::CrDeviceProperty(const CrDeviceProperty& ref) : CrDeviceProperty() { *this = ref; }
CrDeviceProperty& CrDeviceProperty::operator=(const CrDeviceProperty& ref) {
  if (this == &ref) return *this;
  delete[] values;
  code = ref.code;
  valueType = ref.valueType;
  enableFlag = ref.enableFlag;
  variableFlag = ref.variableFlag;
  currentValue = ref.currentValue;
  currentStr = nullptr;
  valuesSize = ref.valuesSize;
  values = ref.values && ref.valuesSize ? new CrInt8u[ref.valuesSize] : nullptr;
  if (values) memcpy(values, ref.values, valuesSize);
  getSetValuesSize = 0;
  getSetValues = nullptr;
  return *this;
}
bool CrDeviceProperty::IsGetEnableCurrentValue() const { return enableFlag == CrEnableValue_True || enableFlag == CrEnableValue_DisplayOnly; }
bool CrDeviceProperty::IsSetEnableCurrentValue() const { return enableFlag == CrEnableValue_True || enableFlag == CrEnableValue_SetOnly; }
void CrDeviceProperty::SetCode(CrInt32u c) { code = c; }
CrInt32u CrDeviceProperty::GetCode() const { return code; }
void CrDeviceProperty::SetValueType(CrDataType t) { valueType = t; }
CrDataType CrDeviceProperty::GetValueType() const { return valueType; }
void CrDeviceProperty::SetCurrentValue(CrInt64u v) { currentValue = v; }
CrInt64u CrDeviceProperty::GetCurrentValue() const { return currentValue; }
void CrDeviceProperty::SetValueSize(CrInt32u size) { valuesSize = size; }
CrInt32u CrDeviceProperty::GetValueSize() const { return valuesSize; }
void CrDeviceProperty::SetValues(CrInt8u* v) { values = v; }
CrInt8u* CrDeviceProperty::GetValues() const { return values; }

// The live view's sizes are the camera's last picture's, read when it is handed over.
CrImageInfo::CrImageInfo() : width(0), height(0), bufferSize(0) {}
CrImageInfo::~CrImageInfo() {}
CrInt32u CrImageInfo::GetBufferSize() const { return camera.frame.empty() ? 0 : (CrInt32u)camera.frame.size() + 1024; }
CrImageDataBlock::CrImageDataBlock() : frameNo(0), size(0), pData(nullptr), imageSize(0), timeCode(0) {}
CrImageDataBlock::~CrImageDataBlock() {}
void CrImageDataBlock::SetSize(CrInt32u s) { size = s; }
CrInt32u CrImageDataBlock::GetSize() const { return size; }
void CrImageDataBlock::SetData(CrInt8u* d) { pData = d; }
CrInt32u CrImageDataBlock::GetImageSize() const { return pData && size >= camera.frame.size() ? (CrInt32u)camera.frame.size() : 0; }
CrInt8u* CrImageDataBlock::GetImageData() const { return pData; }

// MARK: The functions

bool Init(CrInt32u) {
  camera.early = setting("early", 600);
  camera.transfer = setting("transfer", 1500);
  camera.hold = setting("hold", 100);
  camera.focuses = setting("af", 1) != 0;
  camera.busy = setting("busy", 0);
  camera.stepsNeedPriority = setting("stepsneed", 0) != 0;
  camera.values[CrDeviceProperty_FocusMode] = setting("focus", 6);
  camera.values[CrDeviceProperty_PriorityKeySettings] = setting("priority", CrPriorityKey_CameraPosition);
  camera.values[CrDeviceProperty_Focus_Magnifier_Setting] = (320 << 16) | 240;
  camera.values[CrDeviceProperty_FocusIndication] = CrFocusIndicator_Unlocked;
  camera.values[CrDeviceProperty_FNumber] = 800;
  camera.values[CrDeviceProperty_S1] = CrLockIndicator_Unlocked;
  found.count = (CrInt32u)setting("cameras", 1);
  return true;
}
bool Release() { return true; }
CrInt32u GetSDKVersion() { return 0x02020000; }
CrError EnumCameraObjects(ICrEnumCameraObjectInfo** list, CrInt8u) {
  *list = &found;
  return CrError_None;
}
CrError Connect(ICrCameraObjectInfo*, IDeviceCallback* callback, CrDeviceHandle* handle, CrSdkControlMode, CrReconnectingSet,
  const char*, const char*, const char*, CrInt32u, const CrInt16u*) {
  camera.callback = callback;
  *handle = 1;
  later(150, [] {
    if (setting("refuse", 0)) {
      if (camera.callback) camera.callback->OnError(CrError_Connect_SessionAlreadyOpened);
      return;
    }
    {
      std::lock_guard<std::mutex> g(camera.lock);
      camera.connectedAt = Clock::now();
    }
    if (camera.callback) camera.callback->OnConnected(DEVICE_CONNECTION_VERSION_RCP3);
  });
  return CrError_None;
}
CrError Disconnect(CrDeviceHandle) {
  later(50, [] { if (camera.callback) camera.callback->OnDisconnected(0); });
  return CrError_None;
}
CrError ReleaseDevice(CrDeviceHandle) { return CrError_None; }
CrError SetSaveInfo(CrDeviceHandle, CrChar* path, CrChar* prefix, CrInt32) {
  std::lock_guard<std::mutex> g(camera.lock);
  camera.folder = path ? path : ".";
  camera.prefix = prefix ? prefix : "DSC";
  return CrError_None;
}
CrError GetSelectDeviceProperties(CrDeviceHandle, CrInt32u count, CrInt32u* codes, CrDeviceProperty** out, CrInt32* n) {
  if (tooEarly()) return CrError_Api_InvalidCalled;
  auto* list = new CrDeviceProperty[count];
  std::lock_guard<std::mutex> g(camera.lock);
  for (CrInt32u i = 0; i < count; i++) {
    list[i].SetCode(codes[i]);
    list[i].SetValueType(typeOf(codes[i]));
    list[i].SetCurrentValue((CrInt64u)camera.values[codes[i]]);
    auto [values, size] = offered(codes[i]);
    if (size) {
      auto* bytes = new CrInt8u[values.size() * size];
      for (size_t k = 0; k < values.size(); k++) memcpy(bytes + k * size, &values[k], size);
      list[i].SetValues(bytes);
      list[i].SetValueSize((CrInt32u)(values.size() * size));
    }
  }
  *out = list;
  *n = (CrInt32)count;
  return CrError_None;
}
CrError ReleaseDeviceProperties(CrDeviceHandle, CrDeviceProperty* list) {
  delete[] list;
  return CrError_None;
}
CrError SetDeviceProperty(CrDeviceHandle, CrDeviceProperty* p) {
  if (tooEarly()) return CrError_Api_InvalidCalled;
  CrInt32u code = p->GetCode();
  int64_t v = (int64_t)p->GetCurrentValue();
  std::unique_lock<std::mutex> g(camera.lock);
  switch (code) {
    case CrDeviceProperty_FocusMode:
      if (camera.busy && Clock::now() < camera.letGo + std::chrono::milliseconds(camera.busy)) {
        g.unlock();
        say("刚松开半按，切换对焦模式没生效");
        return CrError_None;
      }
      camera.values[code] = v;
      // A change of focus mode ends the magnifier.
      camera.values[CrDeviceProperty_Focus_Magnifier_Setting] &= 0xFFFFFFFF;
      g.unlock();
      changed({CrDeviceProperty_FocusMode, CrDeviceProperty_Focus_Magnifier_Setting});
      return CrError_None;
    case CrDeviceProperty_NearFar:
      if (camera.values[CrDeviceProperty_FocusMode] != CrFocus_MF) {
        g.unlock();
        say("对焦步进被拒绝（不在 MF）");
        later(20, [] { if (camera.callback) camera.callback->OnWarningExt(CrWarningExt_OperationInvalid, CrDeviceProperty_NearFar, 0, 0); });
      } else if (camera.stepsNeedPriority && camera.values[CrDeviceProperty_PriorityKeySettings] != CrPriorityKey_PCRemote) {
        g.unlock();
        say("对焦步进没生效（相机优先）");
      } else {
        g.unlock();
        say("镜头步进 " + std::to_string(v));
      }
      return CrError_None;
    case CrDeviceProperty_S1:
      camera.values[code] = v;
      if (v == CrLockIndicator_Locked) {
        camera.halfPressed = true;
        if (autofocusing()) {
          g.unlock();
          say("半按，开始对焦");
          later(300, [] {
            {
              std::lock_guard<std::mutex> g(camera.lock);
              if (!camera.halfPressed) return;
              camera.focused = camera.focuses;
              camera.values[CrDeviceProperty_FocusIndication] = camera.focuses ? CrFocusIndicator_Focused_AF_S : CrFocusIndicator_NotFocused_AF_S;
            }
            changed({CrDeviceProperty_FocusIndication});
          });
        }
      } else {
        if (camera.halfPressed) camera.letGo = Clock::now();
        camera.halfPressed = camera.focused = false;
        camera.values[CrDeviceProperty_FocusIndication] = CrFocusIndicator_Unlocked;
      }
      return CrError_None;
    case CrDeviceProperty_Focus_Magnifier_Setting:
    case CrDeviceProperty_PriorityKeySettings:
      camera.values[code] = v;
      g.unlock();
      changed({code});
      return CrError_None;
    default:
      camera.values[code] = v;
      return CrError_None;
  }
}
CrError SendCommand(CrDeviceHandle, CrInt32u command, CrCommandParam param) {
  if (command != CrCommandId_Release) return CrError_None;
  if (param == CrCommandParam_Down) {
    std::lock_guard<std::mutex> g(camera.lock);
    camera.down = true;
    camera.downAt = Clock::now();
  } else if (param == CrCommandParam_Up) {
    int held;
    {
      std::lock_guard<std::mutex> g(camera.lock);
      if (!camera.down) return CrError_None;
      camera.down = false;
      held = (int)std::chrono::duration_cast<std::chrono::milliseconds>(Clock::now() - camera.downAt).count();
    }
    released(held);
  }
  return CrError_None;
}
CrError SetDeviceSetting(CrDeviceHandle, CrInt32u key, CrInt32u value) {
  if (key == Setting_Key_EnableLiveView) camera.live = value != 0;
  return CrError_None;
}
CrError GetLiveViewImageInfo(CrDeviceHandle, CrImageInfo*) {
  const char* path = getenv("EPSON_CAMERA_SIM_LIVE");
  FILE* f = path && camera.live ? fopen(path, "rb") : nullptr;
  if (!f) return CrError_Api_InvalidCalled;
  std::vector<CrInt8u> bytes;
  CrInt8u chunk[65536];
  for (size_t n; (n = fread(chunk, 1, sizeof chunk, f)) > 0;) bytes.insert(bytes.end(), chunk, chunk + n);
  fclose(f);
  camera.frame = bytes;
  return bytes.empty() ? CrError_Api_InvalidCalled : CrError_None;
}
CrError GetLiveViewImage(CrDeviceHandle, CrImageDataBlock* block) {
  if (camera.frame.empty() || !block->GetImageData() || block->GetSize() < camera.frame.size()) return CrError_Api_InvalidCalled;
  memcpy(block->GetImageData(), camera.frame.data(), camera.frame.size());
  return CrError_None;
}

}  // namespace SCRSDK
