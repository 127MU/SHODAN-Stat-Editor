import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shodan_desktop/main.dart';
import 'editor_test.dart' show FakeBackend;

class ReleaseBackend extends FakeBackend {
  final nativeCalls = <String>[];
  String? opened;
  @override
  Future<dynamic> nativeCall(
    String method, [
    Map<String, dynamic> params = const {},
  ]) async {
    nativeCalls.add(method);
    if (method == 'update-start') return {'pending': true};
    if (method == 'update-poll') {
      return {
        'pending': false,
        'offer': {
          'version': 'v4.6.1',
          'current': '4.6.0',
          'newer': true,
          'notes': '修复被动勾选\n优化资源来源定位',
          'url':
              'https://github.com/127MU/SHODAN-Stat-Editor/releases/tag/v4.6.1',
          'download_url':
              'https://github.com/127MU/SHODAN-Stat-Editor/releases/download/v4.6.1/SHODAN_4.6.1.exe',
        },
      };
    }
    if (method == 'update-open-link') {
      opened = params['url'] as String;
      return true;
    }
    throw StateError('Unexpected native method: $method');
  }
}

void main() {
  testWidgets('设置使用原生更新接口显示日志和下载入口', (tester) async {
    final backend = ReleaseBackend();
    await tester.binding.setSurfaceSize(const Size(1480, 960));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      Workbench(backend: backend, persistAppearance: false),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('navigation-Settings')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('检查更新'));
    await tester.pumpAndSettle();
    expect(backend.nativeCalls, ['update-start', 'update-poll']);
    expect(find.text('发现新版本 v4.6.1'), findsWidgets);
    expect(find.text('修复被动勾选\n优化资源来源定位'), findsOneWidget);
    await tester.tap(find.text('直接下载'));
    await tester.pumpAndSettle();
    expect(backend.opened, endsWith('/v4.6.1/SHODAN_4.6.1.exe'));
    await tester.tap(find.text('稍后再说'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(backend.installs, 0);
  });
}
