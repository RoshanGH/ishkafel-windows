#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

namespace {

constexpr wchar_t kInstanceMutexName[] =
    L"Local\\com.jichuang.ishkafel.Windows.SingleInstance";
constexpr wchar_t kFlutterWindowClassName[] = L"FLUTTER_RUNNER_WIN32_WINDOW";
constexpr wchar_t kWindowTitle[] = L"ishkafel";

void BringExistingWindowToFront() {
  // A second process can arrive after the mutex is acquired but before the
  // first window exists. Retry briefly, but never create a second writer.
  HWND existing = nullptr;
  for (int attempt = 0; attempt < 80 && existing == nullptr; ++attempt) {
    existing = ::FindWindowW(kFlutterWindowClassName, kWindowTitle);
    if (existing == nullptr) {
      ::Sleep(25);
    }
  }
  if (existing == nullptr) {
    return;
  }
  if (::IsIconic(existing)) {
    ::ShowWindow(existing, SW_RESTORE);
  } else {
    ::ShowWindow(existing, SW_SHOW);
  }
  if (!::SetForegroundWindow(existing)) {
    FLASHWINFO flash{};
    flash.cbSize = sizeof(flash);
    flash.hwnd = existing;
    flash.dwFlags = FLASHW_TRAY;
    flash.uCount = 3;
    flash.dwTimeout = 0;
    ::FlashWindowEx(&flash);
  }
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  HANDLE instance_mutex = ::CreateMutexW(nullptr, FALSE, kInstanceMutexName);
  if (instance_mutex != nullptr && ::GetLastError() == ERROR_ALREADY_EXISTS) {
    BringExistingWindowToFront();
    ::CloseHandle(instance_mutex);
    return EXIT_SUCCESS;
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1440, 900);
  Win32Window::Size minimum_size(1100, 880);
  window.SetMinimumSize(minimum_size);
  if (!window.Create(kWindowTitle, origin, size)) {
    if (instance_mutex != nullptr) {
      ::CloseHandle(instance_mutex);
    }
    ::CoUninitialize();
    return EXIT_FAILURE;
  }
  window.CenterOnCurrentMonitor();
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  if (instance_mutex != nullptr) {
    ::CloseHandle(instance_mutex);
  }
  return EXIT_SUCCESS;
}
