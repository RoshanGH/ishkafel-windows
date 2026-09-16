import 'package:flutter_test/flutter_test.dart';

import '../../tool/windows_visual_fixture.dart';

void main() {
  test('Windows 视觉夹具包含七个单元和多镜头时间线', () {
    final task = buildWindowsVisualFixture(
      sourcePath: r'C:\fixture\source.mp4',
      sourceBytes: 1234,
    );

    expect(task.seq, 4);
    expect(task.units, hasLength(7));
    expect(task.units!.expand((unit) => unit.shots), hasLength(38));
    expect(task.videoInfo!.width, 1080);
    expect(task.videoInfo!.height, 1920);
    expect(task.unitTagGroups, isNotEmpty);
    expect(task.shotTagGroups, isNotEmpty);
  });
}
