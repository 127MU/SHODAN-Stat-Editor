import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shodan_desktop/catalog_groups.dart';
import 'package:shodan_desktop/main.dart';
import 'editor_test.dart' show FakeBackend;

final family = <Map>[
  for (final part in ['本体', '火箭发射器', '加特林机枪'])
    {
      'id': part,
      'name': part == '本体' ? 'EXO-45 爱国者' : 'EXO-45 爱国者 $part',
      'changed': part == '火箭发射器',
      'groups': [
        {'id': 'Mechas:45', 'name': 'EXO-45 爱国者'},
      ],
    },
];

class GroupBackend extends FakeBackend {
  final selected = <String>[];
  @override
  Future<dynamic> call(String method, [List<dynamic> args = const []]) async {
    if (method == 'items') return family;
    if (method == 'select') selected.add('${args.first}');
    return super.call(method, args);
  }
}

void main() {
  test('显式父子分组保留所有部件，搜索和修改筛选匹配子条目', () {
    final groups = buildCatalogGroups(family, 'Mechas');
    expect(groups.length, 1);
    expect(groups.single.entries.length, 3);
    expect(groups.single.changed, isTrue);
    final filtered = buildCatalogGroups(
      family,
      'Mechas',
      query: '火箭',
      onlyChanged: true,
    ).single;
    expect(filtered.entries.length, 3);
    expect(filtered.matches.single['id'], '火箭发射器');
    expect(
      buildCatalogGroups(family, 'Mechas', query: '加特林', onlyChanged: true),
      isEmpty,
    );
    for (final tab in ['Primary', 'Secondary', 'Support', 'Throwables']) {
      expect(buildCatalogGroups(family, tab).length, 3);
    }
  });
  test('仅精确冒号父项可合并，相似型号和缺少父项不混合', () {
    final groups = buildCatalogGroups([
      {'id': '10', 'name': 'M-10'},
      {'id': '10w', 'name': 'M-10：左臂'},
      {'id': '100', 'name': 'M-100'},
      {'id': 'orphan', 'name': 'M-1：左臂'},
    ], 'Mechas');
    expect(groups.length, 3);
    expect(groups.first.entries.length, 2);
    expect(groups[1].entries.single['id'], '100');
  });
  testWidgets('同类卡片选择具体部件后才调用后端，取消不改变选择', (tester) async {
    final backend = GroupBackend();
    await tester.binding.setSurfaceSize(const Size(1480, 960));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      Workbench(backend: backend, persistAppearance: false),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('载具机甲'));
    await tester.pumpAndSettle();
    expect(find.text('选择打开'), findsOneWidget);
    await tester.tap(find.text('选择打开'));
    await tester.pumpAndSettle();
    expect(find.text('本体参数'), findsOneWidget);
    expect(backend.selected, isEmpty);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(backend.selected, isEmpty);
    await tester.enterText(find.byKey(const ValueKey('catalog-search')), '火箭');
    await tester.pumpAndSettle();
    await tester.tap(find.text('选择打开'));
    await tester.pumpAndSettle();
    expect(find.text('本体参数'), findsNothing);
    await tester.tap(find.text('显示全部关联条目'));
    await tester.pumpAndSettle();
    expect(find.text('本体参数'), findsOneWidget);
    await tester.tap(find.text('EXO-45 爱国者 火箭发射器'));
    await tester.pumpAndSettle();
    expect(backend.selected, ['火箭发射器']);
    expect(find.byKey(const ValueKey('parameter-search')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
