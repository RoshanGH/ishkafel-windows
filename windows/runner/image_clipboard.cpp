#include "image_clipboard.h"
#include <windows.h>
#include <objidl.h>
#include <gdiplus.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <vector>
#include <cstring>

namespace {
constexpr size_t kMaxBytes = 4 * 1024 * 1024;
struct ClipboardGuard {
  ~ClipboardGuard() { CloseClipboard(); }
};
struct GdiGuard {
  ULONG_PTR token = 0;
  ~GdiGuard() { if (token) Gdiplus::GdiplusShutdown(token); }
};
void ReadImage(flutter::MethodResult<flutter::EncodableValue>* result) {
  if (!OpenClipboard(nullptr)) {
    result->Error("clipboard_busy", "剪贴板正被占用，请重新粘贴。");
    return;
  }
  ClipboardGuard clipboard;
  // 浏览器、聊天工具的 PNG 优先；Windows 截图的 DIB 由系统转换为位图。
  const UINT png_format = RegisterClipboardFormatW(L"PNG");
  if (IsClipboardFormatAvailable(png_format)) {
    HANDLE handle = GetClipboardData(png_format);
    const SIZE_T size = handle ? GlobalSize(handle) : 0;
    if (size == 0 || size > kMaxBytes) {
      result->Error("image_size", "截图为空或超过 4 MB。");
      return;
    }
    const auto* data = static_cast<const uint8_t*>(GlobalLock(handle));
    if (!data) { result->Error("clipboard_read", "截图读取失败。"); return; }
    std::vector<uint8_t> bytes(data, data + size);
    GlobalUnlock(handle);
    const uint8_t signature[] = {137, 80, 78, 71, 13, 10, 26, 10};
    if (bytes.size() < 33 || std::memcmp(bytes.data(), signature, 8) != 0 ||
        std::memcmp(bytes.data() + 12, "IHDR", 4) != 0) {
      result->Error("image_format", "剪贴板图片不是有效的 PNG。"); return;
    }
    const auto read_u32 = [&bytes](size_t offset) -> uint32_t {
      return (uint32_t(bytes[offset]) << 24) | (uint32_t(bytes[offset + 1]) << 16) |
             (uint32_t(bytes[offset + 2]) << 8) | uint32_t(bytes[offset + 3]);
    };
    const uint32_t width = read_u32(16), height = read_u32(20);
    if (read_u32(8) != 13 || width == 0 || height == 0 || width > 8192 ||
        height > 8192 || static_cast<uint64_t>(width) * height > 9000000) {
      result->Error("image_size", "截图尺寸过大或无法读取。"); return;
    }
    result->Success(flutter::EncodableValue(bytes));
    return;
  }
  if (!IsClipboardFormatAvailable(CF_BITMAP)) { result->Success(); return; }
  auto handle = static_cast<HBITMAP>(GetClipboardData(CF_BITMAP));
  BITMAP info{};
  if (!handle || !GetObject(handle, sizeof(info), &info) ||
      info.bmWidth <= 0 || info.bmHeight <= 0 ||
      info.bmWidth > 8192 || info.bmHeight > 8192 ||
      static_cast<int64_t>(info.bmWidth) * info.bmHeight > 9000000) {
    result->Error("image_size", "截图尺寸过大或无法读取。");
    return;
  }
  GdiGuard gdi;
  Gdiplus::GdiplusStartupInput input;
  if (Gdiplus::GdiplusStartup(&gdi.token, &input, nullptr) != Gdiplus::Ok) {
    result->Error("image_encode", "截图编码不可用。"); return;
  }
  Gdiplus::Bitmap bitmap(handle, nullptr);
  // Windows 内置 PNG 编码器 CLSID。
  const CLSID png_encoder = {0x557cf406, 0x1a04, 0x11d3,
                            {0x9a, 0x73, 0x00, 0x00, 0xf8, 0x1e, 0xf3, 0x2e}};
  IStream* stream = nullptr;
  if (FAILED(CreateStreamOnHGlobal(nullptr, TRUE, &stream))) {
    result->Error("image_encode", "截图编码失败。"); return;
  }
  const auto status = bitmap.Save(stream, &png_encoder, nullptr);
  STATSTG stat{};
  const auto stat_status = stream->Stat(&stat, STATFLAG_NONAME);
  if (status != Gdiplus::Ok || FAILED(stat_status) ||
      stat.cbSize.QuadPart == 0 || stat.cbSize.QuadPart > kMaxBytes) {
    stream->Release();
    result->Error("image_size", "截图无法编码或超过 4 MB。"); return;
  }
  std::vector<uint8_t> bytes(static_cast<size_t>(stat.cbSize.QuadPart));
  LARGE_INTEGER zero{};
  stream->Seek(zero, STREAM_SEEK_SET, nullptr);
  ULONG read = 0;
  const auto read_status = stream->Read(bytes.data(), static_cast<ULONG>(bytes.size()), &read);
  stream->Release();
  if (FAILED(read_status) || read != bytes.size()) {
    result->Error("image_read", "截图读取不完整。"); return;
  }
  result->Success(flutter::EncodableValue(bytes));
}
}  // namespace

void RegisterImageClipboard(flutter::BinaryMessenger* messenger) {
  flutter::MethodChannel<flutter::EncodableValue> channel(
      messenger, "ishkafel/clipboard", &flutter::StandardMethodCodec::GetInstance());
  channel.SetMethodCallHandler([](const auto& call, auto result) {
    if (call.method_name() == "readImage") ReadImage(result.get());
    else result->NotImplemented();
  });
}
