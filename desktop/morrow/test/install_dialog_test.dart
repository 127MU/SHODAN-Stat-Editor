import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shodan_desktop/backend.dart';
import 'package:shodan_desktop/diagnostics.dart';
import 'package:shodan_desktop/install_dialog.dart';

class InstallerBackend extends Backend {
  InstallerBackend(Directory dir)
    : super(diagnostics: AppDiagnostics(directory: dir, persist: false));
  final completion = Completer<Map<String, dynamic>>();
  @override
  Future<dynamic> call(String method, [List<dynamic> args = const []]) =>
      completion.future;
}

class SequencingBackend extends Backend {
  SequencingBackend(Directory dir)
    : super(diagnostics: AppDiagnostics(directory: dir, persist: false));
  final calls = <List<dynamic>>[];
  final completers = <Completer<dynamic>>[];
  @override
  Future<dynamic> call(String method, [List<dynamic> args = const []]) {
    calls.add([method, ...args]);
    final completer = Completer<dynamic>();
    completers.add(completer);
    return completer.future;
  }
}

void main() {
  testWidgets('恢复原版被外部修改阻断时可强制恢复', (tester) async {
    final dir = Directory.systemTemp.createTempSync('shodan-restore-ui-');
    final backend = SequencingBackend(dir);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: InstallDialog(backend: backend, restore: true)),
      ),
    );
    await tester.pump();
    expect(backend.calls.single.take(2), ['restore_task', false]);
    backend.completers.single.completeError(
      StateError('generated_customization_passive_bonuses.dl_bin 的文件已变化'),
    );
    await tester.pumpAndSettle();
    expect(find.text('恢复未完成'), findsOneWidget);
    expect(find.text('强制恢复'), findsOneWidget);
    expect(
      find.descendant(
        of: find.widgetWithText(OutlinedButton, '强制恢复'),
        matching: find.byIcon(Icons.warning_amber_outlined),
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('强制恢复'));
    await tester.pumpAndSettle();
    expect(find.text('确认强制恢复'), findsOneWidget);
    await tester.tap(find.text('备份并强制恢复'));
    // The progress spinner keeps animating while the forced restore runs, so
    // settle the route transition instead of waiting for all animations.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(backend.calls.last, ['restore_task', false, true]);
    backend.completers.last.complete({
      'ok': true,
      'message': '已恢复 1 个数值文件、0 个独立资源',
      'warnings': ['generated_customization_passive_bonuses.dl_bin 已被其他工具修改，已强制恢复为备份内容'],
    });
    await tester.pumpAndSettle();
    expect(find.textContaining('强制恢复为备份内容'), findsOneWidget);
    expect(find.text('恢复完成'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => backend.diagnostics.snapshot());
    await backend.progress.close();
    dir.deleteSync(recursive: true);
  });

  for (final ok in [true, false]) {
    testWidgets('安装动画、实际阶段进度与${ok ? '成功' : '失败'}结果', (tester) async {
      final dir = Directory.systemTemp.createTempSync('shodan-install-ui-');
      final backend = InstallerBackend(dir);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: InstallDialog(backend: backend)),
        ),
      );
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('关闭'), findsNothing);
      backend.progress.add({'stage': '生成待写入文件', 'done': 2, 'total': 4});
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('当前阶段：2 / 4'), findsOneWidget);
      expect(
        tester
            .widget<LinearProgressIndicator>(
              find.byType(LinearProgressIndicator),
            )
            .value,
        .5,
      );
      backend.completion.complete({'ok': ok, 'message': ok ? '安装完成' : '权限不足'});
      await tester.pumpAndSettle();
      expect(find.text(ok ? '安装完成' : '安装未完成'), findsWidgets);
      expect(find.text('导出日志'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() => backend.diagnostics.snapshot());
      await backend.progress.close();
      dir.deleteSync(recursive: true);
    });
  }
}
