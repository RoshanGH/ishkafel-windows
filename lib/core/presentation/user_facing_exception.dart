/// Marker contract for domain failures whose [message] is deliberately safe
/// and actionable for direct display in the UI.
///
/// Unknown exceptions must never implement this contract merely to preserve
/// their raw text. Keep technical details and causes in logs instead.
abstract interface class UserFacingException implements Exception {
  String get message;
}
