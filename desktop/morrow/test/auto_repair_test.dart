import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shodan_desktop/main.dart';
import 'editor_test.dart' show FakeBackend;

class RepairBackend extends FakeBackend {
  final wait = Completer<void>();
  bool failStartup = false;
  int repairs = 0;
  @override
  Future<void> start() async {
    usesNativeDesktop = true;
    if (failStartup) throw StateError('编辑草稿无效');
  }
  @override
  Future<dynamic> nativeCall(String method, [Map<String, dynamic> params = const {}]) async {
    if (method != 'game-repair') return {};
    repairs++;
    await wait.future;
    return {
      'ok': true,
      'message': '自动修复完成',
      'actions': ['已备份并解除失效派生记录'],
      'warnings': ['保留第三方 Mod 文件'],
      'problems': [],
    };
  }
}

void main() {
  for (final failStartup in [false, true]) {
    testWidgets('自动修复展示进度和结果，启动失败=$failStartup', (tester) async {
      final backend = RepairBackend()..failStartup = failStartup;
      await tester.binding.setSurfaceSize(const Size(1280, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(Workbench(backend: backend, persistAppearance: false));
      await tester.pumpAndSettle();
      if (!failStartup) {
        await tester.tap(find.byKey(const ValueKey('navigation-Settings')));
        await tester.pumpAndSettle();
      } else {
        await tester.tap(find.byKey(const ValueKey('navigation-Mechas')));
        await tester.pumpAndSettle();
        expect(find.text('工作区尚未打开'), findsOneWidget);
        await tester.tap(find.text('前往设置修复'));
        await tester.pumpAndSettle();
      }
      expect(find.byKey(const ValueKey('auto-repair')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('auto-repair')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 700));
      expect(backend.repairs, 1);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      backend.wait.complete();
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.textContaining('已备份并解除失效派生记录'), findsOneWidget);
      expect(find.textContaining('保留第三方 Mod 文件'), findsOneWidget);
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('navigation-Primary')));
      await tester.pumpAndSettle();
      expect(find.text('AR-11 仲裁者'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
