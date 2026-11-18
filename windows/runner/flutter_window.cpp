#include "flutter_window.h"

#include <flutter_windows.h>

#include <algorithm>
#include <optional>

#include "flutter/generated_plugin_registrant.h"

namespace {

// Smallest window the UI is designed for, in logical pixels (the app scrolls
// below roughly 720 x 560 of page area). Scaled by the monitor DPI and
// clamped to the monitor work area, so a 1366x768 laptop at 150% scaling or a
// 1024x600 screen can still fit the whole window on screen.
constexpr int kMinLogicalWidth = 800;
constexpr int kMinLogicalHeight = 500;

RECT WorkAreaFor(HWND hwnd) {
  MONITORINFO info{};
  info.cbSize = sizeof(MONITORINFO);
  GetMonitorInfo(MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST), &info);
  return info.rcWork;
}

double ScaleFor(HWND hwnd) {
  const UINT dpi = FlutterDesktopGetDpiForMonitor(
      MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST));
  return dpi == 0 ? 1.0 : dpi / 96.0;
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project,
                             bool start_hidden)
    : project_(project), start_hidden_(start_hidden) {}

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
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    if (!start_hidden_) this->ShowFitted();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::ShowFitted() {
  // The default 1440x900 (logical) window is larger than small laptop
  // screens and high-DPI setups; open maximized there so no part of the
  // window (e.g. the POS "Complete" button) starts off-screen.
  HWND hwnd = GetHandle();
  RECT window{};
  GetWindowRect(hwnd, &window);
  const RECT work = WorkAreaFor(hwnd);
  const bool too_big = (window.right - window.left) > (work.right - work.left) ||
                       (window.bottom - window.top) > (work.bottom - work.top);
  if (too_big) {
    ShowWindow(hwnd, SW_SHOWMAXIMIZED);
  } else {
    Show();
  }
}

void FlutterWindow::OnDestroy() {
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
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
    case WM_GETMINMAXINFO: {
      // Minimum size in physical pixels: the logical minimum scaled by DPI,
      // never larger than the monitor's work area (taskbar excluded).
      auto* info = reinterpret_cast<MINMAXINFO*>(lparam);
      const double scale = ScaleFor(hwnd);
      const RECT work = WorkAreaFor(hwnd);
      info->ptMinTrackSize.x = std::min<LONG>(
          static_cast<LONG>(kMinLogicalWidth * scale), work.right - work.left);
      info->ptMinTrackSize.y = std::min<LONG>(
          static_cast<LONG>(kMinLogicalHeight * scale), work.bottom - work.top);
      return 0;
    }
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
