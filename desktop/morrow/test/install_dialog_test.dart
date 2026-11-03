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

void main() {
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
