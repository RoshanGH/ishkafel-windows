#ifndef RUNNER_NATIVE_VIDEO_PICKER_H_
#define RUNNER_NATIVE_VIDEO_PICKER_H_

#include <optional>

// helper 参数必须在 Flutter、单例锁和主进程 COM 初始化之前识别。
std::optional<int> TryRunNativeVideoPicker();

#endif  // RUNNER_NATIVE_VIDEO_PICKER_H_
