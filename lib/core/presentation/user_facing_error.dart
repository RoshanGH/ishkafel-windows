/// Convert an unexpected exception into text that is safe to show in the UI.
///
/// Raw exception class names, stack details, and English library errors belong
/// in logs. Chinese domain messages are retained because they usually contain
/// the action the user needs to take.
String userFacingError(
  Object error, {
  required String fallback,
  int maxLength = 220,
}) {
  String raw;
  try {
    final message = (error as dynamic).message;
    raw = message is String ? message : error.toString();
  } catch (_) {
    raw = error.toString();
  }

  var text = raw
      .replaceFirst(RegExp(r'^[A-Za-z_$][\w.$<>]*Exception\s*:\s*'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  final containsSensitiveDetail = RegExp(
    r'(?:authorization|bearer|token|api[-_ ]?key|secret|signature|password|credential|access[-_ ]?key)\s*[:=]?',
    caseSensitive: false,
  ).hasMatch(text) ||
      RegExp(r'https?://', caseSensitive: false).hasMatch(text) ||
      RegExp(r'[A-Za-z]:[\\/]').hasMatch(text) ||
      RegExp(r'\\\\[^\\\s]+[\\/]').hasMatch(text) ||
      RegExp(r'/(?:Users|home|var|tmp|etc)/').hasMatch(text) ||
      text.contains('file://') ||
      RegExp(r'(?:^|\s)#\d+\s').hasMatch(text);
  if (text.isEmpty ||
      !RegExp(r'[\u3400-\u9fff]').hasMatch(text) ||
      containsSensitiveDetail) {
    return fallback;
  }
  if (text.length > maxLength) {
    text = '${text.substring(0, maxLength - 1)}…';
  }
  return text;
}
