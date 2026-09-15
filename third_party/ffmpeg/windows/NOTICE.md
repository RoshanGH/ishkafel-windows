# FFmpeg Windows distribution notice

Ishkafel 的 Windows Release 随包分发独立的 `ffmpeg.exe` 与 `ffprobe.exe` 子进程。

- Version: FFmpeg 9.0.1 Essentials x64 static
- Distributor: Gyan Doshi / gyan.dev
- Build information: https://www.gyan.dev/ffmpeg/builds/
- Corresponding FFmpeg source: https://github.com/FFmpeg/FFmpeg/commit/bf1b838f2a
- License: GNU General Public License version 3 or later

该构建包含 `libx264`，因此整个 FFmpeg 二进制按 GPLv3 分发。FFmpeg 与 Ishkafel
是彼此独立的程序；Ishkafel 通过命令行子进程调用它，不把 FFmpeg 库链接进主程序。
构建脚本会把发布归档中的许可证原文复制为 `LICENSE.txt`，并在复制任何可执行文件前
校验 `manifest.json` 中固定的 SHA-256。
