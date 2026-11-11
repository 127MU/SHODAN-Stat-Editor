#include "flutter_window.h"

#include <optional>
#include <dwmapi.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include "flutter/generated_plugin_registrant.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }
  // Windows 11 rounds the actual HWND, including the custom title bar. Older
  // systems may reject this attribute; keep their normal window behavior.
  const DWORD corner_preference = 2;  // DWMWCP_ROUND
  ::DwmSetWindowAttribute(GetHandle(), 33, &corner_preference,
                         sizeof(corner_preference));

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
  auto* engine = flutter_controller_->engine();
  auto* wallpaper_registrar = flutter::PluginRegistrarManager::GetInstance()
      ->GetRegistrar<flutter::PluginRegistrarWindows>(
          engine->GetRegistrarForPlugin("ShodanWallpaperVideo"));
  wallpaper_video_ = std::make_unique<WallpaperVideo>(
      engine->messenger(), wallpaper_registrar->texture_registrar());
  close_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "shodan/window",
      &flutter::StandardMethodCodec::GetInstance());
  close_channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    if (call.method_name() == "hideNow") {
      ::ShowWindow(GetHandle(), SW_HIDE);
      result->Success();
    } else if (call.method_name() == "closeNow") {
      result->Success();
      // Leave the method-channel callback before exiting. Flutter's current
      // Windows view teardown can call GetEngine on an invalidated view.
      ::PostMessage(GetHandle(), WM_APP + 120, 0, 0);
    } else {
      result->NotImplemented();
    }
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
  wallpaper_video_.reset();
  close_channel_.reset();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if (message == WM_CLOSE ||
      (message == WM_SYSCOMMAND && (wparam & 0xfff0) == SC_CLOSE)) {
    // Do not route an explicit close through Dart/plugin teardown or wait for
    // a save dialog. Edits are auto-saved; the data host drains on pipe EOF.
    ::ShowWindow(hwnd, SW_HIDE);
    if (wallpaper_video_) wallpaper_video_->CloseAll();
    ::SetTimer(hwnd, 120, 25, nullptr);
    return 0;
  }
  if (message == WM_TIMER && wparam == 120) {
    ::KillTimer(hwnd, 120);
    ::ExitProcess(0);
  }
  if (message == WM_APP + 120) {
    // Explicit user exit only. OS releases UI/GPU/COM resources atomically;
    // the independent Rust data process drains its input and flushes on EOF.
    if (wallpaper_video_) wallpaper_video_->CloseAll();
    ::ExitProcess(0);
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
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
