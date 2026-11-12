#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>

#include <memory>

#include "win32_window.h"

// Hosts Flutter and process-lifetime transfer protection (never a transfer queue).
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  void HandleTransferMethod(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  bool StopTransferProtection();
  void EmitTransferEvent(const char* event);
  void DisposeTransferBridge();

  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // All bridge calls, power messages and teardown run on the window thread.
  // Destroy the channel before its engine/messenger, including destructor paths.
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      transfer_channel_;
  DWORD transfer_thread_id_ = 0;
  bool transfer_active_ = false;
  bool resume_after_suspend_ = false;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
