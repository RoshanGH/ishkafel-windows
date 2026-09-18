#include "native_video_picker.h"

#include <windows.h>
#include <shlobj.h>
#include <shobjidl.h>
#include <wrl/client.h>

#include <cstdlib>
#include <cstdio>
#include <cstring>
#include <cwchar>
#include <string>

namespace {
using Microsoft::WRL::ComPtr;

// 只写固定阶段和 HRESULT；不在诊断文件中放用户路径。
void WriteStage(const wchar_t* destination, const char* phase) {
  const std::wstring result(destination);
  const auto slash = result.find_last_of(L"\\/");
  if (slash == std::wstring::npos) return;
  const std::wstring stage = result.substr(0, slash + 1) + L"stage.txt";
  const HANDLE file = ::CreateFileW(stage.c_str(), GENERIC_WRITE, FILE_SHARE_READ,
      nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) return;
  DWORD written = 0;
  ::WriteFile(file, phase, static_cast<DWORD>(std::strlen(phase)), &written, nullptr);
  ::CloseHandle(file);
}

int Failure(const wchar_t* destination, const char* phase, HRESULT hr) {
  char message[128]{};
  std::snprintf(message, sizeof(message), "failure at=%s hr=0x%08lX", phase,
      static_cast<unsigned long>(hr));
  WriteStage(destination, message);
  return 2;
}

// 即使 GUI 崩溃或退出，helper 也不能变成遗留窗口。
DWORD WINAPI WatchParent(void* context) {
  const HANDLE parent = static_cast<HANDLE>(context);
  const DWORD result = ::WaitForSingleObject(parent, 180000);
  ::CloseHandle(parent);
  ::ExitProcess(result == WAIT_TIMEOUT ? 3 : 1);
}

bool WriteResult(const wchar_t* destination, const std::wstring& path) {
  const int size = ::WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS,
      path.data(), static_cast<int>(path.size()), nullptr, 0, nullptr, nullptr);
  if (size <= 0) return false;
  std::string bytes(static_cast<size_t>(size), '\0');
  if (::WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, path.data(),
      static_cast<int>(path.size()), bytes.data(), size, nullptr, nullptr) != size) {
    return false;
  }
  // 只创建 Dart 为本次请求指定的新文件，绝不覆盖已有文件。
  const HANDLE file = ::CreateFileW(destination, GENERIC_WRITE, 0, nullptr,
      CREATE_NEW, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) return false;
  DWORD written = 0;
  const bool ok = ::WriteFile(file, bytes.data(), static_cast<DWORD>(size),
      &written, nullptr) && written == static_cast<DWORD>(size);
  ::CloseHandle(file);
  return ok;
}

bool IsLocalDirectory(const std::wstring& path) {
  if (path.size() < 3 || path[1] != L':' || path[2] != L'\\') return false;
  if (::GetDriveTypeW(path.substr(0, 3).c_str()) != DRIVE_FIXED) return false;
  const DWORD attributes = ::GetFileAttributesW(path.c_str());
  return attributes != INVALID_FILE_ATTRIBUTES &&
      (attributes & FILE_ATTRIBUTE_DIRECTORY) != 0;
}

std::wstring InitialFolder() {
  PWSTR videos = nullptr;
  std::wstring folder;
  if (SUCCEEDED(::SHGetKnownFolderPath(FOLDERID_Videos,
      KF_FLAG_DEFAULT_PATH | KF_FLAG_DONT_VERIFY, nullptr, &videos))) {
    folder = videos;
    ::CoTaskMemFree(videos);
    if (IsLocalDirectory(folder)) return folder;
  }
  wchar_t windows[MAX_PATH]{};
  if (::GetWindowsDirectoryW(windows, MAX_PATH) > 0) {
    folder = std::wstring(windows).substr(0, 3);
    if (IsLocalDirectory(folder)) return folder;
  }
  return {};
}

int PickVideo(const wchar_t* destination) {
  WriteStage(destination, "dialog_create");
  ComPtr<IFileOpenDialog> dialog;
  HRESULT hr = ::CoCreateInstance(CLSID_FileOpenDialog, nullptr,
      CLSCTX_INPROC_SERVER, IID_PPV_ARGS(dialog.GetAddressOf()));
  if (FAILED(hr)) return Failure(destination, "dialog_create", hr);
  DWORD options = 0;
  hr = dialog->GetOptions(&options);
  if (FAILED(hr)) return Failure(destination, "dialog_create", hr);
  hr = dialog->SetOptions(options | FOS_FORCEFILESYSTEM | FOS_FILEMUSTEXIST |
      FOS_PATHMUSTEXIST | FOS_DONTADDTORECENT | FOS_NOCHANGEDIR);
  if (FAILED(hr)) return Failure(destination, "dialog_create", hr);
  const COMDLG_FILTERSPEC types[] = {{L"视频 (*.mp4; *.mov)", L"*.mp4;*.mov"}};
  hr = dialog->SetFileTypes(1, types);
  if (FAILED(hr)) return Failure(destination, "dialog_create", hr);
  hr = dialog->SetTitle(L"选择本地视频 — Ishkafel");
  if (FAILED(hr)) return Failure(destination, "dialog_create", hr);
  WriteStage(destination, "initial_folder");
  const std::wstring initial = InitialFolder();
  if (initial.empty()) return Failure(destination, "initial_folder", E_FAIL);
  ComPtr<IShellItem> folder;
  hr = ::SHCreateItemFromParsingName(initial.c_str(), nullptr,
      IID_PPV_ARGS(folder.GetAddressOf()));
  if (FAILED(hr)) return Failure(destination, "initial_folder", hr);
  hr = dialog->SetFolder(folder.Get());
  if (FAILED(hr)) return Failure(destination, "initial_folder", hr);
  // 不把 GUI HWND 作为 owner，否则主窗口将被系统模态关系禁用，无法点取消。
  WriteStage(destination, "show");
  hr = dialog->Show(nullptr);
  if (hr == HRESULT_FROM_WIN32(ERROR_CANCELLED)) return 1;
  if (FAILED(hr)) return Failure(destination, "show", hr);
  WriteStage(destination, "result");
  ComPtr<IShellItem> item;
  hr = dialog->GetResult(item.GetAddressOf());
  if (FAILED(hr)) return Failure(destination, "result", hr);
  PWSTR selected = nullptr;
  hr = item->GetDisplayName(SIGDN_FILESYSPATH, &selected);
  if (FAILED(hr)) return Failure(destination, "result", hr);
  const bool saved = WriteResult(destination, selected);
  ::CoTaskMemFree(selected);
  return saved ? 0 : Failure(destination, "result", E_FAIL);
}
}  // namespace

std::optional<int> TryRunNativeVideoPicker() {
  int count = 0;
  LPWSTR* arguments = ::CommandLineToArgvW(::GetCommandLineW(), &count);
  if (arguments == nullptr) return std::nullopt;
  if (count < 2 || std::wcscmp(arguments[1], L"--pick-video") != 0) {
    ::LocalFree(arguments);
    return std::nullopt;
  }
  if (count != 4) {
    ::LocalFree(arguments);
    return 2;
  }
  const std::wstring destination(arguments[2]);
  wchar_t* end = nullptr;
  const unsigned long parent_pid = std::wcstoul(arguments[3], &end, 10);
  const bool valid_pid = end != arguments[3] && *end == L'\0' && parent_pid != 0;
  ::LocalFree(arguments);
  if (!valid_pid || destination.size() < 3 || destination[1] != L':') return 2;
  const HANDLE parent = ::OpenProcess(SYNCHRONIZE, FALSE, parent_pid);
  if (parent == nullptr) return 2;
  const HANDLE watcher = ::CreateThread(nullptr, 0, WatchParent, parent, 0, nullptr);
  if (watcher == nullptr) {
    ::CloseHandle(parent);
    return 2;
  }
  ::CloseHandle(watcher);
  WriteStage(destination.c_str(), "com_init");
  const HRESULT initialized = ::CoInitializeEx(nullptr,
      COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE);
  if (FAILED(initialized)) return Failure(destination.c_str(), "com_init", initialized);
  const int result = PickVideo(destination.c_str());
  ::CoUninitialize();
  return result;
}
