#ifndef RUNNER_PRIVACY_BRIDGE_H_
#define RUNNER_PRIVACY_BRIDGE_H_

#include <windows.h>
#include <flutter/binary_messenger.h>
#include <flutter/method_channel.h>
#include <memory>

class PrivacyBridge {
 public:
  PrivacyBridge(HWND window, flutter::BinaryMessenger* messenger);
  ~PrivacyBridge();
  bool HandleMessage(UINT message, WPARAM wparam, LPARAM lparam);
 private:
  struct State;
  std::shared_ptr<State> state_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  bool manual_capture_ = false;
  bool app_lock_ = false;
  bool shielded_ = true;
  bool ApplyCapture(bool manual, bool app_lock, bool shielded);
  void CancelAuthentication();
};
#endif
