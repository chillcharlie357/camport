// Winsock2 must precede windows.h (included by flutter_window.h).
#include <winsock2.h>

#include "flutter_window.h"

#include <flutter/standard_method_codec.h>
#include <iphlpapi.h>
#include <shellapi.h>

#include <cassert>
#include <cstdint>
#include <limits>
#include <optional>
#include <string>
#include <utility>
#include <variant>
#include <vector>

#include "flutter/generated_plugin_registrant.h"

namespace {
using flutter::EncodableMap;
using flutter::EncodableValue;

const EncodableValue* Argument(const EncodableValue* arguments,
                              const char* name) {
  const auto* map = arguments ? std::get_if<EncodableMap>(arguments) : nullptr;
  if (!map) return nullptr;
  const auto entry = map->find(EncodableValue(name));
  return entry == map->end() ? nullptr : &entry->second;
}

// StandardMethodCodec encodes Dart integers as either int32_t or int64_t.
// In particular, bool and double must not be silently coerced to counts.
std::optional<int64_t> Integer(const EncodableValue* value) {
  if (!value) return std::nullopt;
  if (const auto* number = std::get_if<int32_t>(value)) return *number;
  if (const auto* number = std::get_if<int64_t>(value)) return *number;
  return std::nullopt;
}

bool ValidFilename(const EncodableValue* value) {
  const auto* name = value ? std::get_if<std::string>(value) : nullptr;
  if (!name || name->empty() || name->find('\0') != std::string::npos ||
      name->size() > static_cast<size_t>((std::numeric_limits<int>::max)())) {
    return false;
  }
  const int length = MultiByteToWideChar(
      CP_UTF8, MB_ERR_INVALID_CHARS, name->data(),
      static_cast<int>(name->size()), nullptr, 0);
  if (length == 0) return false;
  std::vector<wchar_t> wide(length);
  std::vector<WORD> types(length);
  if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, name->data(),
                         static_cast<int>(name->size()), wide.data(), length) !=
          length ||
      !GetStringTypeW(CT_CTYPE1, wide.data(), length, types.data())) {
    return false;
  }
  for (int index = 0; index < length; ++index) {
    if ((types[index] & (C1_SPACE | C1_BLANK)) == 0 &&
        wide[index] != L'\ufeff') {
      return true;
    }
  }
  return false;
}

struct HeapDeleter {
  void operator()(void* memory) const {
    if (memory) HeapFree(GetProcessHeap(), 0, memory);
  }
};

struct NetworkReadiness {
  ULONG error;
  bool connected;
};

NetworkReadiness CheckNetworkReadiness() {
  // A camera AP need not have internet, DNS or a default gateway. Check only
  // local IPv4 interface readiness; do not connect, bind sockets or infer a host.
  ULONG size = 15 * 1024;
  for (int attempt = 0; attempt < 3; ++attempt) {
    std::unique_ptr<void, HeapDeleter> buffer(
        HeapAlloc(GetProcessHeap(), 0, size));
    if (!buffer) return {ERROR_NOT_ENOUGH_MEMORY, false};
    auto* adapters = static_cast<IP_ADAPTER_ADDRESSES*>(buffer.get());
    const ULONG status = GetAdaptersAddresses(
        AF_INET, GAA_FLAG_SKIP_ANYCAST | GAA_FLAG_SKIP_MULTICAST |
                     GAA_FLAG_SKIP_DNS_SERVER,
        nullptr, adapters, &size);
    if (status == ERROR_BUFFER_OVERFLOW) continue;
    if (status == ERROR_NO_DATA) return {NO_ERROR, false};
    if (status != NO_ERROR) return {status, false};
    for (auto* adapter = adapters; adapter; adapter = adapter->Next) {
      if (adapter->OperStatus != IfOperStatusUp ||
          (adapter->IfType != IF_TYPE_IEEE80211 &&
           adapter->IfType != IF_TYPE_ETHERNET_CSMACD) ||
          (adapter->Flags & IP_ADAPTER_RECEIVE_ONLY) != 0) {
        continue;
      }
      for (auto* address = adapter->FirstUnicastAddress; address;
           address = address->Next) {
        if (!address->Address.lpSockaddr ||
            address->Address.iSockaddrLength <
                static_cast<int>(sizeof(sockaddr_in)) ||
            address->Address.lpSockaddr->sa_family != AF_INET ||
            address->DadState != IpDadStatePreferred) {
          continue;
        }
        const auto* ipv4 = reinterpret_cast<const sockaddr_in*>(
            address->Address.lpSockaddr);
        const auto first_octet = ipv4->sin_addr.S_un.S_un_b.s_b1;
        if (first_octet != 0 && first_octet != 127 && first_octet < 224) {
          return {NO_ERROR, true};
        }
      }
    }
    return {NO_ERROR, false};
  }
  return {ERROR_BUFFER_OVERFLOW, false};
}
}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {
  // The base destructor cannot dispatch to our OnDestroy override.
  DisposeTransferBridge();
}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  transfer_thread_id_ = GetCurrentThreadId();
  transfer_channel_ =
      std::make_unique<flutter::MethodChannel<EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          "camport/transfer_background",
          &flutter::StandardMethodCodec::GetInstance());
  transfer_channel_->SetMethodCallHandler(
      [this](const auto& call, auto result) {
        HandleTransferMethod(call, std::move(result));
      });
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  DisposeTransferBridge();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

void FlutterWindow::HandleTransferMethod(
    const flutter::MethodCall<EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
  if (GetCurrentThreadId() != transfer_thread_id_) {
    result->Error("transfer_state", "Transfer bridge requires the window thread");
    return;
  }
  const auto& method = call.method_name();
  const auto* arguments = call.arguments();
  if (method == "start") {
    const auto count = Integer(Argument(arguments, "pendingFiles"));
    if (!count || *count <= 0 ||
        *count > (std::numeric_limits<int32_t>::max)()) {
      result->Error("invalid_arguments", "pendingFiles must be a positive int32");
      return;
    }
    if (!transfer_active_) {
      if (SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED) == 0) {
        result->Error("transfer_platform_error",
                      "Windows could not prevent idle system sleep");
        return;
      }
      transfer_active_ = true;
    }
    result->Success(EncodableValue(EncodableMap{
        {EncodableValue("message"),
         EncodableValue("Idle system sleep is inhibited while the app runs; "
                        "explicit sleep and quitting still stop transfers.")}}));
  } else if (method == "update") {
    const auto bytes = Integer(Argument(arguments, "bytes"));
    const auto* total_value = Argument(arguments, "total");
    const auto total = Integer(total_value);
    if (!ValidFilename(Argument(arguments, "filename")) || !bytes || *bytes < 0 ||
        (total_value && !total_value->IsNull() && (!total || *total < 0))) {
      result->Error("invalid_arguments",
                    "A nonblank filename and nonnegative integer byte counts "
                    "are required; total may be null or omitted");
      return;
    }
    if (!transfer_active_) {
      result->Error("transfer_state", "No active transfer protection");
      return;
    }
    // Progress belongs to Dart; no native queue, file IO or display assertion.
    result->Success();
  } else if (method == "stop") {
    if (!StopTransferProtection()) {
      result->Error("transfer_platform_error",
                    "Windows could not release idle sleep protection");
      return;
    }
    result->Success();
  } else if (method == "prepareNetwork") {
    const auto network = CheckNetworkReadiness();
    if (network.error != NO_ERROR) {
      result->Error("transfer_platform_error",
                    "Could not inspect IPv4 interfaces (Windows error " +
                        std::to_string(network.error) + ")");
      return;
    }
    result->Success(EncodableValue(EncodableMap{
        {EncodableValue("connected"), EncodableValue(network.connected)},
        {EncodableValue("message"),
         EncodableValue(network.connected
                            ? "An operational Wi-Fi or Ethernet IPv4 interface "
                              "is available. Windows routing is unchanged; "
                              "camera reachability has not been verified."
                            : "No operational Wi-Fi or Ethernet interface with "
                              "a usable IPv4 address. Connect to the camera "
                              "network and retry.")}}));
  } else if (method == "releaseNetwork") {
    if (transfer_active_) {
      result->Error("transfer_state",
                    "Stop the active transfer before releasing the network");
      return;
    }
    // prepareNetwork never acquires a binding or changes system networking.
    result->Success();
  } else if (method == "openWifiSettings") {
    const auto status = reinterpret_cast<INT_PTR>(
        ShellExecuteW(GetHandle(), L"open", L"ms-settings:network-wifi", nullptr,
                      nullptr, SW_SHOWNORMAL));
    if (status <= 32) {
      result->Error("transfer_platform_error",
                    "Could not open Wi-Fi settings (ShellExecute error " +
                        std::to_string(status) + ")");
      return;
    }
    result->Success();
  } else {
    result->NotImplemented();
  }
}

bool FlutterWindow::StopTransferProtection() {
  if (!transfer_active_) return true;
  assert(GetCurrentThreadId() == transfer_thread_id_);
  if (GetCurrentThreadId() != transfer_thread_id_ ||
      SetThreadExecutionState(ES_CONTINUOUS) == 0) {
    return false;
  }
  transfer_active_ = false;
  return true;
}

void FlutterWindow::EmitTransferEvent(const char* event) {
  if (transfer_channel_) {
    transfer_channel_->InvokeMethod("event",
                                  std::make_unique<EncodableValue>(event));
  }
}

void FlutterWindow::DisposeTransferBridge() {
  if (!StopTransferProtection()) {
    OutputDebugStringW(L"Could not release camera transfer sleep protection\n");
  }
  resume_after_suspend_ = false;
  if (transfer_channel_) {
    transfer_channel_->SetMethodCallHandler(nullptr);
    transfer_channel_.reset();
  }
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Process lifecycle messages before plugins can consume them. Closing the
  // window destroys this bridge and the Dart engine; nothing survives quit.
  if (message == WM_DESTROY) {
    return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
  }
  if (message == WM_CLOSE && transfer_active_) {
    EmitTransferEvent("pauseRequested");
  }
  if (message == WM_POWERBROADCAST) {
    if (wparam == PBT_APMSUSPEND && transfer_active_) {
      resume_after_suspend_ = true;
      EmitTransferEvent("pauseRequested");
      if (!StopTransferProtection()) {
        OutputDebugStringW(L"Could not release transfer protection on suspend\n");
      }
    } else if ((wparam == PBT_APMRESUMEAUTOMATIC ||
                wparam == PBT_APMRESUMESUSPEND) && resume_after_suspend_) {
      resume_after_suspend_ = false;
      // Dart decides whether to resume (including manual-pause suppression),
      // and must call start again. Never acquire protection or run work here.
      EmitTransferEvent("resumeRequested");
    }
  }
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_POWERBROADCAST:
      if (wparam == PBT_APMSUSPEND || wparam == PBT_APMRESUMEAUTOMATIC ||
          wparam == PBT_APMRESUMESUSPEND) {
        return TRUE;
      }
      break;
    case WM_FONTCHANGE:
      if (flutter_controller_) {
        flutter_controller_->engine()->ReloadSystemFonts();
      }
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
