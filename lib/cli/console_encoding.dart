import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

const int windowsUtf8CodePage = 65001;

typedef ConsoleCodePageSetter = bool Function(int codePage);
typedef _SetConsoleCodePageNative = Int32 Function(Uint32 codePage);
typedef _SetConsoleCodePageDart = int Function(int codePage);

/// Establishes UTF-8 before argument parsing or any diagnostic output.
///
/// Redirected output is always emitted as UTF-8 bytes. For an attached legacy
/// Windows console the Win32 code pages are changed as well, so Chinese text is
/// not interpreted as CP936/GBK.
bool configureConsoleEncoding({
  String? operatingSystem,
  ConsoleCodePageSetter? setInputCodePage,
  ConsoleCodePageSetter? setOutputCodePage,
}) {
  stdout.encoding = utf8;
  stderr.encoding = utf8;

  if ((operatingSystem ?? Platform.operatingSystem) != 'windows') return false;
  try {
    final input = setInputCodePage ?? _setConsoleInputCodePage;
    final output = setOutputCodePage ?? _setConsoleOutputCodePage;
    return input(windowsUtf8CodePage) && output(windowsUtf8CodePage);
  } catch (_) {
    // Redirection does not have a console handle. UTF-8 sink encoding above is
    // still the required behavior, so lack of a console is not fatal.
    return false;
  }
}

bool _setConsoleInputCodePage(int codePage) =>
    _kernel32
        .lookupFunction<_SetConsoleCodePageNative, _SetConsoleCodePageDart>(
          'SetConsoleCP',
        )(codePage) !=
    0;

bool _setConsoleOutputCodePage(int codePage) =>
    _kernel32
        .lookupFunction<_SetConsoleCodePageNative, _SetConsoleCodePageDart>(
          'SetConsoleOutputCP',
        )(codePage) !=
    0;

final DynamicLibrary _kernel32 = DynamicLibrary.open('kernel32.dll');
