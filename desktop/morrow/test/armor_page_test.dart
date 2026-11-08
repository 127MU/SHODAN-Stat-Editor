import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shodan_desktop/armor_page.dart';
import 'package:shodan_desktop/glass_theme.dart';
import 'editor_test.dart' show FakeBackend;

class ArmorBackend extends FakeBackend {
  final enabled = <String, bool>{};
  double passiveValue = 1.0;
  Completer<void>? saveGate;
  bool rejectSave = false;
  int saveCalls = 0;
  @override
  Future<dynamic> call(String method, [List<dynamic> args = const []]) async {
    if (method == 'info') {
      return {
        'armor': [
          {'id': 1, 'zh': '额外垫料'},
          {'id': 2, 'zh': '侦察'},
          {'id': 3, 'zh': '强化'},
          {'id': 4, 'zh': '医疗包'},
        ],
      };
    }
    if (method == 'armor_profile') {
      return {'own': true, 'conflicts': 'stack', 'enabled': Map.of(enabled)};
    }
    if (method == 'armor_update') {
      enabled['${args[1]}'] = args[2] == true;
      return true;
    }
    if (method == 'armor_rows') {
      return [
        {'key': 'value', 'label': '倍率', 'value': passiveValue, 'default': 1.0},
      ];
    }
    if (method == 'armor_set') {
      saveCalls++;
      await saveGate?.future;
      if (rejectSave) throw StateError('保存失败');
      passiveValue = args[2] as double;
      return true;
    }
    return super.call(method, args);
  }
}

void main() {
  final valueField = find.descendant(
    of: find.byType(GlassDialog),
    matching: find.byType(TextField),
  );
  Future<void> openValues(WidgetTester tester, ArmorBackend backend) async {
    await tester.binding.setSurfaceSize(const Size(1200, 820));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ArmorPage(
            backend: backend,
            onError: (e) => fail('$e'),
            surface: (child) => child,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('修改数值').first);
    await tester.pumpAndSettle();
  }

  testWidgets('直接关闭会等被动数值保存，重新打开保留修改', (tester) async {
    final backend = ArmorBackend()..saveGate = Completer<void>();
    await openValues(tester, backend);
    await tester.enterText(valueField, '1.75');
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(find.text('正在保存…'), findsOneWidget);
    expect(backend.saveCalls, 1);
    backend.saveGate!.complete();
    await tester.pumpAndSettle();
    expect(valueField, findsNothing);
    await tester.tap(find.text('修改数值').first);
    await tester.pumpAndSettle();
    expect(find.text('1.75'), findsOneWidget);
    expect(backend.saveCalls, 1);
  });

  testWidgets('弹窗外点击也会保存，保存失败可在原弹窗重试', (tester) async {
    final backend = ArmorBackend()..rejectSave = true;
    await openValues(tester, backend);
    await tester.enterText(valueField, '2.5');
    await tester.tapAt(const Offset(20, 20));
    await tester.pumpAndSettle();
    expect(find.textContaining('保存失败'), findsOneWidget);
    expect(find.text('2.5'), findsOneWidget);
    backend.rejectSave = false;
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(valueField, findsNothing);
    expect(backend.passiveValue, 2.5);
  });

  testWidgets('被动搜索、已选筛选和勾选状态保持一致', (tester) async {
    final backend = ArmorBackend();
    var query = '';
    late StateSetter rebuild;
    await tester.binding.setSurfaceSize(const Size(1200, 820));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              rebuild = setState;
              return ArmorPage(
                backend: backend,
                query: query,
                onError: (e) => fail('$e'),
                surface: (child) =>
                    Padding(padding: const EdgeInsets.all(20), child: child),
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('已选择 0 / 4 个被动 · 显示 4 项'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey('passive:2')).findChildCheckbox(),
    );
    await tester.pumpAndSettle();
    expect(backend.enabled['2'], isTrue);
    expect(find.text('已加入组合'), findsOneWidget);
    await tester.tap(find.text('仅看已选'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('passive:1')), findsNothing);
    rebuild(() => query = '医疗');
    await tester.pumpAndSettle();
    expect(find.text('没有匹配的被动'), findsOneWidget);
    await tester.tap(find.text('仅看已选'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('passive:4')), findsOneWidget);
    expect(find.byKey(const ValueKey('passive:2')), findsNothing);
    expect(tester.takeException(), isNull);
  });
  testWidgets('被动显示为2可回车提交整数，重新打开保留2', (tester) async {
    final backend = ArmorBackend()..passiveValue = 1.9999999403953552;
    await openValues(tester, backend);
    await tester.tap(valueField);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(backend.passiveValue, 2);
    expect(backend.saveCalls, 1);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('修改数值').first);
    await tester.pumpAndSettle();
    expect(find.text('2'), findsOneWidget);
  });
  testWidgets('只查看被动不取整，编辑回相同显示值关闭会保存', (tester) async {
    final backend = ArmorBackend()..passiveValue = 2.000000238418579;
    await openValues(tester, backend);
    await tester.tap(valueField);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(backend.saveCalls, 0);
    await tester.tap(find.text('修改数值').first);
    await tester.pumpAndSettle();
    await tester.enterText(valueField, '3');
    await tester.enterText(valueField, '2');
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(backend.passiveValue, 2);
    expect(backend.saveCalls, 1);
  });
}

extension on Finder {
  Finder findChildCheckbox() =>
      find.descendant(of: this, matching: find.byType(Checkbox));
}
