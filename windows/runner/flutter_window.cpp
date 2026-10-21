#include "flutter_window.h"

#include <optional>
#include <flutter/standard_method_codec.h>

#include "flutter/generated_plugin_registrant.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

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
  privacy_bridge_ = std::make_unique<PrivacyBridge>(GetHandle(), flutter_controller_->engine()->messenger());
  network_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "oplayer/network",
      &flutter::StandardMethodCodec::GetInstance());
  network_channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    if (call.method_name() == "forgetProcess") {
      if (network_job_) { CloseHandle(network_job_); network_job_ = nullptr; }
      result->Success(); return;
    }
    if (call.method_name() != "ownProcess") { result->NotImplemented(); return; }
    const auto* pid = call.arguments() ? std::get_if<int32_t>(call.arguments()) : nullptr;
    if (!pid || *pid <= 0) { result->Error("PID", "Invalid child process"); return; }
    if (network_job_) { CloseHandle(network_job_); network_job_ = nullptr; }
    network_job_ = CreateJobObject(nullptr, nullptr);
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits = {};
    limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    HANDLE process = OpenProcess(PROCESS_SET_QUOTA | PROCESS_TERMINATE, FALSE, *pid);
    const bool assigned = network_job_ && process &&
        SetInformationJobObject(network_job_, JobObjectExtendedLimitInformation, &limits, sizeof(limits)) &&
        AssignProcessToJobObject(network_job_, process);
    if (process) CloseHandle(process);
    if (!assigned) {
      if (network_job_) { CloseHandle(network_job_); network_job_ = nullptr; }
      result->Error("PROCESS_OWNER", "Cannot own ByeDPI child"); return;
    }
    result->Success();
  });
  window_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "oplayer/window",
      &flutter::StandardMethodCodec::GetInstance());
  window_channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    if (call.method_name() != "compact") { result->NotImplemented(); return; }
    const auto* enabled = call.arguments() ? std::get_if<bool>(call.arguments()) : nullptr;
    if (!enabled) { result->Error("INVALID_ARGUMENT", "Expected a boolean"); return; }
    if (*enabled != compact_) {
      if (*enabled) {
        GetWindowPlacement(GetHandle(), &saved_placement_);
        ShowWindow(GetHandle(), SW_RESTORE);
        MONITORINFO monitor = {sizeof(MONITORINFO)};
        GetMonitorInfo(MonitorFromWindow(GetHandle(), MONITOR_DEFAULTTONEAREST), &monitor);
        const auto dpi = GetDpiForWindow(GetHandle());
        const int width = MulDiv(480, dpi, 96), height = MulDiv(320, dpi, 96);
        SetWindowPos(GetHandle(), HWND_TOPMOST, monitor.rcWork.right - width - 20,
                     monitor.rcWork.bottom - height - 20, width, height, SWP_SHOWWINDOW);
      } else {
        SetWindowPos(GetHandle(), HWND_NOTOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE);
        SetWindowPlacement(GetHandle(), &saved_placement_);
      }
      compact_ = *enabled;
    }
    result->Success();
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
  privacy_bridge_.reset();
  network_channel_.reset();
  if (network_job_) { CloseHandle(network_job_); network_job_ = nullptr; }
  window_channel_.reset();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if (privacy_bridge_ && privacy_bridge_->HandleMessage(message, wparam, lparam)) return 0;
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
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
