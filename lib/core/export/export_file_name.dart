/// 成片的文件名。
///
/// **方案名就是文件名**：三条方案本来就是设计成有区别的（「居家写实线」
/// 「跨项目混编线」…），文件名把这个区别抹平的话，人拖进剪辑软件时得回头
/// 翻导出记录才知道哪条是哪条。手册一直是这么承诺的，实现以前没跟上。
library;

/// 文件名里绝不能留的字符：路径分隔符会把文件写到别处去，
/// 冒号在 macOS 上是老的路径分隔符、Finder 里会被显示成斜杠
final _illegal = RegExp(r'[/\\:*?"<>|\x00-\x1f]');
final _spaces = RegExp(r'\s+');

/// 留给名字的长度上限。文件系统按字节算（多数是 255），中文一个字三字节，
/// 取 60 个字符是安全的，也没人真需要更长的方案名
const int _maxNameLength = 60;

final _windowsReservedName = RegExp(
  r'^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)',
  caseSensitive: false,
);

/// 清洗一个可安全用作目录或文件名主体的路径段。
///
/// 除了通用非法字符，还处理 Windows 的设备保留名与尾随点/空格；后两者会让
/// `Directory.create` 失败，或创建出的名字与界面显示不一致。
String safePathSegment(String name, {String fallback = '未命名'}) {
  var cleaned = name
      .replaceAll(_spaces, ' ')
      .replaceAll(_illegal, '-')
      .replaceAll(RegExp(r'^[.\-\s]+|[.\s]+$'), '')
      .trim();
  if (cleaned.isEmpty) return fallback;
  if (_windowsReservedName.hasMatch(cleaned)) cleaned = '_$cleaned';
  if (cleaned.length > _maxNameLength) {
    cleaned = cleaned.substring(0, _maxNameLength).trimRight();
    cleaned = cleaned.replaceAll(RegExp(r'[.\s]+$'), '');
  }
  return cleaned.isEmpty ? fallback : cleaned;
}

/// 拼出成片文件名。[name] 为空或清洗后什么都不剩时退回「变体N」——
/// 界面上枚举出来的组合本来就没有名字
String exportFileName({
  required String? name,
  required int index,
  required String extension,
}) {
  // 先用同一份 Windows 路径段契约处理设备保留名，再补上
  // 成片文件名特有的首尾横杠规则。
  final cleaned = safePathSegment(name ?? '', fallback: '')
      // 首尾的点和横杠去掉：`../../etc` 清完是 `..-..-etc`，
      // 以点开头在 Finder 里是隐藏文件，人会以为片子没导出来
      .replaceAll(RegExp(r'^[.\-\s]+|[.\-\s]+$'), '')
      .trim();
  // 清完只剩标点就等于没名字
  if (cleaned.isEmpty || !RegExp(r'[\w\u4e00-\u9fa5]').hasMatch(cleaned)) {
    return '变体$index.$extension';
  }
  return '$cleaned.$extension';
}
