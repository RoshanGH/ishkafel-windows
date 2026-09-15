import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/cli/app_locator.dart';

/// app 装在哪 —— **不该靠人告诉，也不该靠翻进程**。
///
/// 验收 Agent 开工前就卡在这儿：手册给的唯一办法是 `ps aux` 从进程里读，
/// 而 app 一关就返回空；手册接着把出路推给「问用户要」——那在无人值守的
/// 静默模式里是死路。
///
/// 真正的解法是现成的：**CLI 本身就装在 app 包里**
/// （`ishkafel.app/Contents/Resources/cli/ishkafel`），从自己的路径往上
/// 数四层就是 app。它一直知道自己在哪，只是没人问过它。
void main() {
  test('从自己在 app 包里的位置推出 app 路径', () {
    expect(
      appPathFromExecutable(
        '/Applications/ishkafel.app/Contents/Resources/cli/ishkafel',
        operatingSystem: 'macos',
      ),
      '/Applications/ishkafel.app',
    );
  });

  test('开发期的产物路径也认', () {
    expect(
      appPathFromExecutable(
        '/Users/me/www/ishkafel/build/macos/Build/'
        'Products/Release/ishkafel.app/Contents/Resources/cli/ishkafel',
        operatingSystem: 'macos',
      ),
      endsWith('Release/ishkafel.app'),
    );
  });

  test('不在 app 包里（比如直接跑编译产物）就返回 null，不硬猜', () {
    expect(
      appPathFromExecutable(
        '/usr/local/bin/ishkafel',
        operatingSystem: 'macos',
      ),
      isNull,
    );
    expect(
      appPathFromExecutable('/tmp/ishkafel', operatingSystem: 'macos'),
      isNull,
    );
  });

  group('按优先级找', () {
    test('环境变量最优先——用户指到哪就用哪', () {
      final got = resolveAppPath(
        env: {'ISHKAFEL_APP': '/custom/my.app'},
        executable:
            '/Applications/ishkafel.app/Contents/Resources/cli/ishkafel',
        exists: (_) => true,
        operatingSystem: 'macos',
      );
      expect(got, '/custom/my.app');
    });

    test('没给环境变量就从自己的位置推', () {
      final got = resolveAppPath(
        env: const {},
        executable:
            '/Applications/ishkafel.app/Contents/Resources/cli/ishkafel',
        exists: (p) => p == '/Applications/ishkafel.app',
        operatingSystem: 'macos',
      );
      expect(got, '/Applications/ishkafel.app');
    });

    test('推出来的路径不存在就退回默认位置', () {
      final got = resolveAppPath(
        env: const {},
        executable: '/tmp/somewhere/ishkafel',
        exists: (p) => p == '/Applications/ishkafel.app',
        operatingSystem: 'macos',
      );
      expect(got, '/Applications/ishkafel.app');
    });

    test('哪儿都找不到时返回 null——**说找不到，别给一个假路径**', () {
      expect(
        resolveAppPath(
          env: const {},
          executable: '/tmp/x',
          exists: (_) => false,
          operatingSystem: 'macos',
        ),
        isNull,
      );
    });
  });

  group('CLI 从自己所在的 app 包里读凭据', () {
    test('包里的 credentials 目录排在最后——人放在数据目录的能盖掉它', () {
      final dirs = cliSecretsDirs(
        dataDir: Directory('/data'),
        executable:
            '/Applications/ishkafel.app/Contents/Resources/cli/ishkafel',
        currentDir: '/work',
        operatingSystem: 'macos',
      );

      expect(
        dirs.map((d) => d.path),
        [
          '/data/credentials',
          '/work/.secrets',
          '/Applications/ishkafel.app/Contents/Resources/cli/credentials',
        ],
        reason:
            '正式包自带一份，是为了让 Agent 开箱就能跑；'
            '但人手动放的那份必须能盖过它，不然换 key 都没处换',
      );
    });

    test('工具被单独拷出来时就没有那一项，不硬编一个不存在的路径', () {
      final dirs = cliSecretsDirs(
        dataDir: Directory('/data'),
        executable: '/usr/local/bin/ishkafel',
        currentDir: '/work',
        operatingSystem: 'macos',
      );

      expect(dirs.map((d) => d.path), ['/data/credentials', '/work/.secrets']);
    });
  });

  /// 真机上栽过：写死「往上四层」在单测里绿着，装进包里就失效——
  /// 包内的真实布局比想当然的深两层，doctor 于是报「缺凭据」，
  /// 而凭据就躺在包里。测试要照抄真实布局，不能照抄假设。
  test('照包里的真实布局推：cli/<架构>/bundle/bin/ishkafel', () {
    const real =
        '/Applications/ishkafel.app/Contents/Resources/cli/'
        'macos_arm64/bundle/bin/ishkafel';

    expect(
      appPathFromExecutable(real, operatingSystem: 'macos'),
      '/Applications/ishkafel.app',
    );
    expect(
      cliSecretsDirs(
        dataDir: Directory('/data'),
        executable: real,
        currentDir: '/work',
        operatingSystem: 'macos',
      ).last.path,
      '/Applications/ishkafel.app/Contents/Resources/cli/credentials',
    );
  });

  test('Windows 正式包从 cli\\bin 回推出同目录 GUI bundle', () {
    const cli = r'C:\Program Files\Ishkafel\cli\bin\ishkafel.exe';
    expect(
      appPathFromExecutable(cli, operatingSystem: 'windows'),
      r'C:\Program Files\Ishkafel',
    );
    expect(
      cliSecretsDirs(
        dataDir: Directory(r'C:\Data'),
        executable: cli,
        currentDir: r'C:\Work',
        operatingSystem: 'windows',
      ).last.path,
      r'C:\Program Files\Ishkafel\cli\credentials',
    );
  });
}
