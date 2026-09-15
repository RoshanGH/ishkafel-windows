import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/cli/commands/voice_file_command.dart';
import 'package:ishkafel/core/models/renew_task.dart';
import 'package:ishkafel/core/script/script_doc.dart';
import 'package:ishkafel/core/script/uploaded_voice.dart';
import 'package:ishkafel/core/storage/file_task_repository.dart';
import 'package:path/path.dart' as p;

/// `script voice-file` —— 用我自己录的配音。
///
/// 合成语音的情绪天花板就摆在那儿，产品负责人的结论是：不再磨了，
/// 「如果还不能满足，就只能自己上传了」。所以这条路必须走得稳。
void main() {
  late Directory dir;
  late FileTaskRepository repo;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('vf');
    repo = FileTaskRepository(dir);
    await repo.save(
      RenewTask(
        id: 't1',
        name: '片子',
        status: RenewTaskStatus.ready,
        createdAt: DateTime(2026, 9, 1),
        updatedAt: DateTime(2026, 9, 1),
        script: ScriptDoc([
          ScriptLine.create(text: '早就跟你们说了'),
          ScriptLine.create(text: '第二句'),
        ]).withDefaultVoiceId('vivi'),
      ),
    );
  });
  tearDown(() => dir.deleteSync(recursive: true));

  File audio() => File('${dir.path}/我录的.wav')..writeAsBytesSync([1, 2, 3, 4]);

  Future<(int, String, String)> run({
    required List<String> rest,
    int? line,
    int durationMs = 2600,
    List<VoiceWord> words = const [],
  }) async {
    final out = StringBuffer();
    final err = StringBuffer();
    final code = await runScriptVoiceFileCommand(
      rest: rest,
      dataDir: dir,
      line: line,
      measureMs: (_) async => durationMs,
      transcribe: (_) async => words,
      out: out,
      err: err,
    );
    return (code, '$out', '$err');
  }

  test('装上之后，这一行的时长由这段录音说了算', () async {
    final (code, _, _) = await run(
      rest: ['t1', audio().path],
      line: 1,
      durationMs: 3300,
      words: const [VoiceWord(text: '早', startMs: 0, endMs: 300)],
    );
    expect(code, 0);
    final saved = (await repo.findById('t1'))!.script!;
    expect(saved.lines.first.voiceover!.durationMs, 3300);
    expect(isHumanVoice(saved.lines.first), isTrue);
  });

  test('音频文件被收进任务名下——外面那份随时会被移走', () async {
    await run(rest: ['t1', audio().path], line: 1);
    final saved = (await repo.findById('t1'))!.script!;
    final kept = saved.lines.first.voiceover!.audioPath;
    expect(
      kept,
      contains(p.join('voices', 't1')),
      reason: '它现在是这一行的时间根，留在别人家里等于地基不稳',
    );
    expect(File(kept).existsSync(), isTrue);
  });

  test('录的和脚本不一样：改脚本，并且说出来', () async {
    final (code, jsonOut, log) = await run(
      rest: ['t1', audio().path],
      line: 1,
      words: const [VoiceWord(text: '早就跟你们讲过了', startMs: 0, endMs: 900)],
    );
    expect(code, 0);
    expect((await repo.findById('t1'))!.script!.lines.first.text, '早就跟你们讲过了');
    expect(log, contains('台词按你录的改了'), reason: '悄悄把台词换掉，人回头看脚本会以为自己记错了');
  });

  test('听不出内容也不该挡住这件事——时长照用，但要说清代价', () async {
    final (code, jsonOut, log) = await run(
      rest: ['t1', audio().path],
      line: 1,
      words: const [],
    );
    expect(code, 0, reason: '断不了句是遗憾，不是失败');
    final saved = (await repo.findById('t1'))!.script!;
    expect(saved.lines.first.voiceover!.durationMs, 2600);
    expect(saved.lines.first.text, '早就跟你们说了', reason: '没听出来就别乱改台词');
    expect(jsonDecode(jsonOut)['words'], 0);
  });

  test('画面行没有台词，不该往上装配音', () async {
    // 画面行 = 没有台词的行（type 是从 text 推出来的）
    final task = (await repo.findById('t1'))!;
    await repo.save(task.copyWith(script: task.script!.updateText(1, '')));
    final (code, jsonOut, log) = await run(rest: ['t1', audio().path], line: 2);
    expect(code, isNot(0));
    expect(log, contains('画面行'));
  });

  test('文件不在就直说，别留个空壳', () async {
    final (code, jsonOut, log) = await run(
      rest: ['t1', '${dir.path}/没有.wav'],
      line: 1,
    );
    expect(code, isNot(0));
    expect(log, contains('找不到这个音频文件'));
  });
}
