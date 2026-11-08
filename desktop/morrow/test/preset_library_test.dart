import 'dart:async';
import 'dart:io';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shodan_desktop/preset_library_page.dart';
import 'package:shodan_desktop/glass_theme.dart';
import 'editor_test.dart' show FakeBackend;

class LibraryBackend extends FakeBackend {
  final calls = <String>[];
  Completer<Map>? previewGate;
  String title = '作者的战备组合';
  @override
  Future<dynamic> call(String method, [List<dynamic> args = const []]) async {
    calls.add(method);
    if (method == 'library_list')
      return [
        {
          'id': 'one',
          'name': title,
          'count': 2,
          'targets': ['飞矛', '加特林'],
        },
      ];
    if (method == 'library_preview')
      return previewGate?.future ??
          {
            'groups': [
              {
                'name': title,
                'count': 2,
                'targets': ['飞矛', '加特林'],
              },
            ],
            'entries': [],
            'warnings': [],
          };
    if (method == 'library_import')
      return {'selected': 'one', 'message': '已导入'};
    if (method == 'library_load') return {'warnings': []};
    if (method == 'library_rename') {
      title = args[1];
      return '已保存';
    }
    return super.call(method, args);
  }
}

void main() {
  testWidgets('独立预设库用选择器切换，名称可修改，读取需明确点击', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final backend = LibraryBackend();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PresetLibraryPage(backend: backend, onError: (e) => fail('$e')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(DropdownMenu<String>), findsOneWidget);
    expect(find.text('作者的战备组合'), findsWidgets);
    expect(backend.calls.contains('library_load'), false);
    await tester.tap(find.text('重命名'));
    await tester.pumpAndSettle();
    final field = find.descendant(
      of: find.byType(GlassDialog),
      matching: find.byType(TextField),
    );
    await tester.enterText(field, '我的名称 English');
    await tester.tap(find.text('确认'));
    await tester.pumpAndSettle();
    expect(backend.title, '我的名称 English');
    await tester.tap(find.text('读取预设'));
    await tester.pumpAndSettle();
    expect(backend.calls.contains('library_load'), true);
    expect(tester.takeException(), isNull);
  });
  testWidgets('悬停提示、松开识别动画、确认导入，完成后仍能继续拖入', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1100, 850));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final backend = LibraryBackend()..previewGate = Completer<Map>();
    final nav = GlobalKey<NavigatorState>();
    Map? imported;
    final errors = <Object>[];
    final dir = Directory.systemTemp.createTempSync('shodan-preset-drop-');
    final file = File('${dir.path}/预设.txt')
      ..writeAsStringSync('SHODAN-SHARE 1');
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: nav,
        home: Scaffold(
          body: PresetDropZone(
            backend: backend,
            dialogContext: () => nav.currentContext!,
            onImported: (r) => imported = r,
            onError: errors.add,
            child: const Text('工作区'),
          ),
        ),
      ),
    );
    var target = tester.widget<DropTarget>(find.byType(DropTarget));
    target.onDragEntered!(
      DropEventDetails(localPosition: Offset.zero, globalPosition: Offset.zero),
    );
    await tester.pumpAndSettle();
    expect(find.text('松开以导入预设'), findsOneWidget);
    await tester.runAsync(() async {
      target.onDragDone!(
        DropDoneDetails(
          files: [DropItemFile(file.path)],
          localPosition: Offset.zero,
          globalPosition: Offset.zero,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('正在识别并准备导入…'), findsOneWidget);
    backend.previewGate!.complete({
      'groups': [
        {
          'name': backend.title,
          'count': 2,
          'targets': ['飞矛', '加特林'],
        },
      ],
      'warnings': [],
    });
    await tester.pumpAndSettle();
    expect(find.text(backend.title), findsOneWidget);
    expect(find.text('正在识别并准备导入…'), findsNothing);
    await tester.tap(find.text('确认导入'));
    await tester.pumpAndSettle();
    await tester.runAsync(() async { await Future<void>.delayed(const Duration(milliseconds: 10)); });
    await tester.pumpAndSettle();
    expect(backend.calls, contains('library_import'));
    expect(errors, isEmpty);
    expect(imported?['selected'], 'one');
    expect(errors, isEmpty);
    target = tester.widget<DropTarget>(find.byType(DropTarget));
    expect(target.enable, true);
    target.onDragEntered!(
      DropEventDetails(localPosition: Offset.zero, globalPosition: Offset.zero),
    );
    await tester.pumpAndSettle();
    expect(find.text('松开以导入预设'), findsOneWidget);
    target.onDragExited!(
      DropEventDetails(localPosition: Offset.zero, globalPosition: Offset.zero),
    );
    await tester.pumpAndSettle();
    expect(find.text('松开以导入预设'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    dir.deleteSync(recursive: true);
  });
}
