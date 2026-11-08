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

class RestoredBackend extends FakeBackend {
  @override
  Future<dynamic> call(String method, [List<dynamic> args = const []]) async {
    if (method == 'items')
      return [
        {
          'id': 'changed',
          'name': 'AR-11 仲裁者',
          'changed': true,
          'baseline_state': 'different',
        },
        {
          'id': 'restored',
          'name': 'AR-23 解放者',
          'changed': true,
          'baseline_state': 'same',
        },
        {
          'id': 'vanilla',
          'name': 'AR-32 安抚者',
          'changed': false,
          'baseline_state': 'same',
        },
      ];
    return super.call(method, args);
  }
}

void main() {
  test('恢复原值的待写入记录不进入已修改筛选，仍保留恢复状态', () {
    final restored = {
      'id': 'restored',
      'name': '本体',
      'changed': true,
      'baseline_state': 'same',
    };
    final changed = {
      'id': 'changed',
      'name': '武器',
      'changed': true,
      'baseline_state': 'different',
    };
    expect(catalogItemChanged(restored), isFalse);
    expect(catalogItemChanged(changed), isTrue);
    expect(
      catalogItemChanged({'changed': true, 'baseline_state': 'unknown'}),
      isTrue,
    );
    expect(catalogItemChanged({'changed': true}), isTrue);
    final groups = buildCatalogGroups(
      [restored, changed],
      'Primary',
      onlyChanged: true,
    );
    expect(groups.single.id, 'changed');
    expect(
      buildCatalogGroups([restored], 'Primary').single.statusLabel,
      '已恢复原值',
    );
    final family = [
      {
        ...restored,
        'groups': [
          {'id': 'exo', 'name': '机甲'},
        ],
      },
      {
        ...changed,
        'groups': [
          {'id': 'exo', 'name': '机甲'},
        ],
      },
    ];
    final group = buildCatalogGroups(
      family,
      'Mechas',
      onlyChanged: true,
    ).single;
    expect(group.entries.length, 2);
    expect(group.matches.single['id'], 'changed');
    expect(
      buildCatalogGroups(family, 'Mechas', query: '本体', onlyChanged: true),
      isEmpty,
    );
  });
  testWidgets('主页仅已修改排除已恢复原值，取消筛选仍能看到恢复状态', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1480, 960));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      Workbench(backend: RestoredBackend(), persistAppearance: false),
    );
    await tester.pumpAndSettle();
    expect(find.text('已恢复原值'), findsOneWidget);
    await tester.tap(find.text('仅已修改'));
    await tester.pumpAndSettle();
    expect(find.text('AR-11 仲裁者'), findsOneWidget);
    expect(find.text('AR-23 解放者'), findsNothing);
    expect(find.text('AR-32 安抚者'), findsNothing);
    await tester.tap(find.text('仅已修改'));
    await tester.pumpAndSettle();
    expect(find.text('AR-23 解放者'), findsOneWidget);
    expect(find.text('已恢复原值'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  test('旧值与原值不同仍可筛选，缺少原值不显示未修改', () {
    final items = [
      {
        'id': 'old',
        'name': '旧修改',
        'changed': false,
        'baseline_state': 'different',
      },
      {
        'id': 'unknown',
        'name': '未知原值',
        'changed': false,
        'baseline_state': 'unknown',
      },
      {'id': 'same', 'name': '原始值', 'changed': false, 'baseline_state': 'same'},
    ];
    final groups = buildCatalogGroups(items, 'Primary');
    expect(groups[0].statusLabel, '与原值不同');
    expect(groups[1].statusLabel, '原值待核对');
    expect(groups[2].statusLabel, '未修改');
    final changed = buildCatalogGroups(items, 'Primary', onlyChanged: true);
    expect(changed.single.id, 'old');
  });
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
