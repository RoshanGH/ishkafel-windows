/// Escape a file path embedded directly in an FFmpeg filtergraph option.
///
/// This is not shell escaping: arguments are passed to Process as a list. The
/// filtergraph parser itself treats colon, comma, semicolon and brackets as
/// syntax, while a Windows backslash is an escape character. The option parser
/// needs `C\:/path`; embedding that value in a filtergraph requires `C\\:/path`.
String escapeFfmpegFilterPath(String path) {
  var value = path.replaceAll(r'\', '/');
  value = value.replaceAll("'", r"\\\'");
  value = value.replaceAll(':', r'\\:');
  for (final character in const [',', ';', '[', ']']) {
    value = value.replaceAll(character, '\\$character');
  }
  return value;
}
