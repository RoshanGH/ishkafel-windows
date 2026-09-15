#include <flutter/dart_project.h>
#include <flutter/flutter_engine.h>
#include <windows.h>

#include <algorithm>
#include <chrono>
#include <filesystem>
#include <limits>
#include <string>
#include <vector>

namespace {

std::string Utf8FromWide(const wchar_t* value) {
  if (value == nullptr || *value == L'\0') {
    return {};
  }
  const int size = WideCharToMultiByte(CP_UTF8, 0, value, -1, nullptr, 0,
                                       nullptr, nullptr);
  if (size <= 1) {
    return {};
  }
  std::string result(static_cast<size_t>(size), '\0');
  WideCharToMultiByte(CP_UTF8, 0, value, -1, result.data(), size, nullptr,
                      nullptr);
  result.pop_back();
  return result;
}

DWORD WaitMilliseconds(std::chrono::nanoseconds delay) {
  if (delay == std::chrono::nanoseconds::max()) {
    return 50;
  }
  const auto millis = std::chrono::duration_cast<std::chrono::milliseconds>(
      std::max(delay, std::chrono::nanoseconds::zero()));
  return static_cast<DWORD>(std::clamp<int64_t>(millis.count(), 0, 50));
}

std::filesystem::path ModuleDirectory() {
  std::wstring path(MAX_PATH, L'\0');
  for (;;) {
    const DWORD length =
        GetModuleFileNameW(nullptr, path.data(), static_cast<DWORD>(path.size()));
    if (length == 0) {
      return std::filesystem::current_path();
    }
    if (length < path.size() - 1) {
      path.resize(length);
      return std::filesystem::path(path).parent_path();
    }
    path.resize(path.size() * 2);
  }
}

}  // namespace

int wmain(int argc, wchar_t** argv) {
  SetConsoleCP(CP_UTF8);
  SetConsoleOutputCP(CP_UTF8);
  if (argc != 2) {
    return 64;
  }
  CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  const std::filesystem::path data_directory = ModuleDirectory() / L"data";
  flutter::DartProject project(data_directory.c_str());
  // Subtitle output uses the pinned Flutter SDK's Skia text/image pipeline.
  // DartProject is the supported release-build API for disabling Impeller;
  // FLUTTER_ENGINE_SWITCHES is intentionally unavailable in release engines.
  project.set_impeller_switch(flutter::ImpellerSwitch::Disabled);
  project.set_dart_entrypoint_arguments({Utf8FromWide(argv[1])});
  flutter::FlutterEngine engine(project);
  if (!engine.Run("subtitleRendererMain")) {
    CoUninitialize();
    return 70;
  }

  for (;;) {
    const DWORD wait = WaitMilliseconds(engine.ProcessMessages());
    MsgWaitForMultipleObjectsEx(0, nullptr, wait, QS_ALLINPUT,
                                MWMO_INPUTAVAILABLE);
    MSG message;
    while (PeekMessage(&message, nullptr, 0, 0, PM_REMOVE)) {
      if (message.message == WM_QUIT) {
        engine.ShutDown();
        CoUninitialize();
        return static_cast<int>(message.wParam);
      }
      TranslateMessage(&message);
      DispatchMessage(&message);
    }
  }
}
