import 'dart:io';
import 'package:path/path.dart' as p;
import '../app_version.dart';
import '../platform/platform_paths.dart';
import '../platform/runtime_directories.dart';
import '../platform/windows_storage_preferences.dart';
import 'report_service.dart';

ReportService standaloneReportService() {
  final paths = PlatformPaths(
    windowsStorageValue: WindowsStoragePreferences().readValue,
  );
  final dirs = RuntimeDirectories(
    supportDirectory: Directory(paths.applicationSupport),
    environment: Platform.environment,
    configuredStorageRoot: paths.configuredStorageRoot,
  );
  const url = String.fromEnvironment('REPORT_API_URL');
  return ReportService(
    directory: Directory(
      p.join(dirs.dataDirectory.path, 'diagnostics', 'outbox'),
    ),
    logs: dirs.logDirectory,
    version: appVersion,
    endpoint: url.isEmpty ? null : Uri.tryParse(url),
    token: const String.fromEnvironment('REPORT_SUBMIT_TOKEN'),
    trustedCertificateBase64: const String.fromEnvironment(
      'REPORT_TLS_CA_BASE64',
    ),
    secrets: [
      const String.fromEnvironment('ARK_API_KEY'),
      const String.fromEnvironment('SPEECH_APP_ID'),
      const String.fromEnvironment('SPEECH_ACCESS_TOKEN'),
      const String.fromEnvironment('UPDATE_TOS_AK'),
      const String.fromEnvironment('UPDATE_TOS_SK'),
    ],
  );
}
