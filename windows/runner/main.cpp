#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

namespace {
// Phone-shaped default window size (logical pixels). The framework's
// Win32Window::Create scales these by the active monitor's DPI, so the
// physical size at 100% DPI matches the logical size.
constexpr int kDefaultWindowWidth = 412;
constexpr int kDefaultWindowHeight = 892;
// Smallest size the user can drag-resize down to (logical pixels).
constexpr int kMinWindowWidth = 360;
constexpr int kMinWindowHeight = 640;

// Centers |hwnd| on the primary monitor using physical pixels.
void CenterWindowOnScreen(HWND hwnd) {
  if (hwnd == nullptr) return;
  RECT rect;
  if (!::GetWindowRect(hwnd, &rect)) return;
  const int win_w = rect.right - rect.left;
  const int win_h = rect.bottom - rect.top;
  const int screen_w = ::GetSystemMetrics(SM_CXSCREEN);
  const int screen_h = ::GetSystemMetrics(SM_CYSCREEN);
  int x = (screen_w - win_w) / 2;
  int y = (screen_h - win_h) / 2;
  if (x < 0) x = 0;
  if (y < 0) y = 0;
  ::SetWindowPos(hwnd, nullptr, x, y, 0, 0,
                 SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
}
}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(0, 0);
  Win32Window::Size size(kDefaultWindowWidth, kDefaultWindowHeight);
  if (!window.Create(L"agent_buddy", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetMinimumSize(kMinWindowWidth, kMinWindowHeight);
  // Now that the actual (DPI-scaled) window size is known, center it on
  // the primary monitor.
  CenterWindowOnScreen(window.GetHandle());
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
