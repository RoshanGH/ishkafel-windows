import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 仅采集硬件允许字段，不收集机器名、序列号、MAC、IP 或环境变量。
Future<Map<String, Object?>> collectSystemSnapshot() async {
  final result = <String, Object?>{
    'os': Platform.operatingSystem,
    'os_version': Platform.operatingSystemVersion,
    'processors': Platform.numberOfProcessors,
    'process_rss_bytes': ProcessInfo.currentRss,
  };
  if (!Platform.isWindows) return result;
  final process = await Process.start('powershell.exe', [
    '-NoProfile',
    '-NonInteractive',
    '-Command',
    r'''$ErrorActionPreference='Stop'; [Console]::OutputEncoding=[System.Text.UTF8Encoding]::new();
@{cpu=@(Get-CimInstance Win32_Processor | Select-Object Name,NumberOfCores,NumberOfLogicalProcessors);
gpu=@(Get-CimInstance Win32_VideoController | Select-Object Name,DriverVersion,AdapterRAM);
app_processes=@(Get-Process ishkafel -ErrorAction SilentlyContinue | Select-Object Id,Responding,CPU,WorkingSet64);
memory=(Get-CimInstance Win32_OperatingSystem | Select-Object TotalVisibleMemorySize,FreePhysicalMemory);
disks=@(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' | Select-Object DeviceID,Size,FreeSpace)} | ConvertTo-Json -Depth 4 -Compress''',
  ]);
  final output = process.stdout
      .transform(const Utf8Decoder(allowMalformed: true))
      .join();
  final errors = process.stderr.drain<void>();
  try {
    // 真机冷启动 PowerShell/CIM 可达 17 秒；8 秒会静默漏掉显卡和驱动。
    final code = await process.exitCode.timeout(const Duration(seconds: 30));
    final text = await output;
    await errors;
    if (code == 0) {
      result['hardware'] = jsonDecode(text.trim().replaceFirst('\ufeff', ''));
    } else {
      result['hardware_probe'] = 'failed';
    }
  } on TimeoutException {
    process.kill();
    output.ignore();
    errors.ignore();
    result['hardware_probe'] = 'timeout';
  }
  return result;
}
