import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shodan_desktop/armor_page.dart';
import 'editor_test.dart' show FakeBackend;

class ArmorBackend extends FakeBackend {
  final enabled = <String, bool>{};
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
    return super.call(method, args);
  }
}

void main() {
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
}

extension on Finder {
  Finder findChildCheckbox() =>
      find.descendant(of: this, matching: find.byType(Checkbox));
}
