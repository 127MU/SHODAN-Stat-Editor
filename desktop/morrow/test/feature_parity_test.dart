import 'package:flutter/material.dart';
import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:shodan_desktop/main.dart';
import 'editor_test.dart' show FakeBackend;

class ParityBackend extends FakeBackend {
  Completer<void>? selectionWait;
  int undoCount = 0, redoCount = 0, patchWrites = 0;
  final tweaks = <String, bool>{
    'reticle': false,
    'bounce': false,
    'foliage': false,
  };
  final calls = <String>[];
  @override
  Future<dynamic> call(String method, [List<dynamic> args = const []]) async {
    calls.add(method);
    if (method == 'items')
      return [
        {'id': 'test', 'name': 'AR-11 仲裁者', 'changed': value != '66'},
      ];
    if (method == 'rows_fast' && selectionWait != null)
      await selectionWait!.future;
    if (method == 'history')
      return {
        'undo': undoCount,
        'redo': redoCount,
        'entries': undoCount == 0
            ? []
            : [
                {'label': 'AR-11 仲裁者 · 伤害', 'count': 1},
              ],
      };
    if (method == 'set') {
      undoCount = 1;
      redoCount = 0;
    }
    if (method == 'undo') {
      undoCount = 0;
      redoCount = 1;
      value = '66';
      return {};
    }
    if (method == 'redo') {
      undoCount = 1;
      redoCount = 0;
      value = '123';
      return {};
    }
    if (method == 'tweaks') {
      if (args.isNotEmpty) tweaks[args[0]] = args[1];
      return Map.of(tweaks);
    }
    if (method == 'ragdoll_preview')
      return {'supported': true, 'enabled': false, 'message': '测试资源版本核对通过'};
    if (method == 'ragdoll_apply') {
      patchWrites++;
      return '测试写入';
    }
    if (method == 'diagnostic_chain')
      return {
        'equipment': 'AR-11 仲裁者',
        'entries': [
          {
            'title': '射弹 #1',
            'via': '主射击模式',
            'record_hash': 'F100000000000001',
            'missing': false,
          },
        ],
      };
    if (method == 'diagnostic_resources')
      return {
        'equipment': 'AR-11 仲裁者',
        'owner': 'test',
        'entries': [
          {
            'type_name': '音效',
            'id': '1234',
            'status': '已定位',
            'providers': ['来源资源包'],
          },
        ],
      };
    return super.call(method, args);
  }
}

void main() {
  testWidgets('主页仅已修改筛选刷新刚编辑的装备并保留搜索', (tester) async {
    final backend = ParityBackend();
    await tester.binding.setSurfaceSize(const Size(1480, 960));
    await tester.pumpWidget(
      Workbench(backend: backend, persistAppearance: false),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('仅已修改'));
    await tester.pumpAndSettle();
    expect(find.text('打开'), findsNothing);
    await tester.tap(find.text('仅已修改'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('catalog-search')), '仲裁者');
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, '123');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('catalog-search')))
          .controller!
          .text,
      '仲裁者',
    );
    await tester.tap(find.text('仅已修改'));
    await tester.pumpAndSettle();
    expect(find.text('打开'), findsOneWidget);
    expect(find.text('已修改'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.binding.setSurfaceSize(null);
  });
  testWidgets('参数准备完成后一次切换，等待期间保留目录而不是空白', (tester) async {
    final backend = ParityBackend();
    await tester.binding.setSurfaceSize(const Size(1480, 960));
    await tester.pumpWidget(
      Workbench(backend: backend, persistAppearance: false),
    );
    await tester.pumpAndSettle();
    backend.selectionWait = Completer<void>();
    await tester.tap(find.text('打开'));
    await tester.pump();
    expect(find.byKey(const ValueKey('catalog-search')), findsOneWidget);
    expect(find.text('打开'), findsOneWidget);
    backend.selectionWait!.complete();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('parameter-search')), findsOneWidget);
    expect(find.text('伤害参数'), findsOneWidget);
    expect(
      (tester.getCenter(find.text('装备预设')).dy -
              tester.getCenter(find.text('仅已修改')).dy)
          .abs(),
      lessThan(6),
    );
    await tester.pumpWidget(const SizedBox());
    await tester.binding.setSurfaceSize(null);
  });
  testWidgets('列表搜索与参数搜索隔离，返回列表保留原查询', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1480, 960));
    await tester.pumpWidget(
      Workbench(backend: ParityBackend(), persistAppearance: false),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('catalog-search')), '仲裁者');
    await tester.pumpAndSettle();
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    expect(find.text('伤害参数'), findsOneWidget);
    final input = tester.widget<TextField>(
      find.byKey(const ValueKey('parameter-search')),
    );
    expect(input.controller!.text, isEmpty);
    await tester.enterText(
      find.byKey(const ValueKey('parameter-search')),
      '不存在',
    );
    await tester.pumpAndSettle();
    expect(find.text('伤害参数'), findsNothing);
    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('catalog-search')))
          .controller!
          .text,
      '仲裁者',
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    expect(find.text('伤害参数'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.binding.setSurfaceSize(null);
  });

  testWidgets('旧工具栏入口可用，实际撤销重做并打开引用链数据记录', (tester) async {
    final backend = ParityBackend();
    await tester.binding.setSurfaceSize(const Size(1480, 960));
    await tester.pumpWidget(
      Workbench(backend: backend, persistAppearance: false),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    for (final title in ['装备预设', '修改记录', '射击引用链', '资源诊断', '撤销', '重做', '恢复本项']) {
      expect(find.text(title), findsOneWidget);
    }
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, '123');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('撤销'));
    await tester.pumpAndSettle();
    expect(backend.value, '66');
    await tester.tap(find.text('重做'));
    await tester.pumpAndSettle();
    expect(backend.value, '123');
    await tester.tap(find.text('修改记录'));
    await tester.pumpAndSettle();
    expect(find.text('AR-11 仲裁者 · 伤害'), findsOneWidget);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('资源诊断'));
    await tester.pumpAndSettle();
    expect(find.text('来源包：来源资源包'), findsOneWidget);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('射击引用链'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('打开数据记录'));
    await tester.pumpAndSettle();
    expect(find.text('射弹 #1'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.binding.setSurfaceSize(null);
  });

  testWidgets('游戏参数开关恢复，布娃娃补丁取消后不写入', (tester) async {
    final backend = ParityBackend();
    await tester.binding.setSurfaceSize(const Size(1480, 960));
    await tester.pumpWidget(
      Workbench(backend: backend, persistAppearance: false),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('navigation-Tweaks')));
    await tester.pumpAndSettle();
    expect(find.text('狙击步枪第三人称准星'), findsOneWidget);
    expect(find.text('策略球部署限制放宽'), findsOneWidget);
    expect(find.text('射弹穿过树冠与灌木'), findsOneWidget);
    await tester.tap(find.byType(Switch).first);
    await tester.pumpAndSettle();
    expect(backend.tweaks['reticle'], isTrue);
    await tester.tap(find.byType(Switch).last);
    await tester.pumpAndSettle();
    expect(find.text('启用布娃娃优化（实验性）'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(backend.patchWrites, 0);
    await tester.pumpWidget(const SizedBox());
    await tester.binding.setSurfaceSize(null);
  });
}
