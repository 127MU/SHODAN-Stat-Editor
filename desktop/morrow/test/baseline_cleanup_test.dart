import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shodan_desktop/baseline_cleanup.dart';
import 'package:shodan_desktop/glass_theme.dart';
import 'package:shodan_desktop/group_chooser.dart';
import 'package:shodan_desktop/catalog_groups.dart';
import 'package:shodan_desktop/motion.dart';
import 'editor_test.dart' show FakeBackend;

class CleanupBackend extends FakeBackend {
  List<dynamic>? restored;
  bool stale = false;
  @override
  Future<dynamic> call(String method, [List<dynamic> args = const []]) async {
    if (method == 'baseline_cleanup_preview')
      return {
        'token': 'verified-preview',
        'preserved': 2,
        'skipped': 1,
        'entries': [
          {
            'id': 'sway-field',
            'owner': 'AR-23 解放者',
            'parameter': '武器晃动倍率',
            'key': 'sway',
            'before': 0,
            'after': 1,
            'shared': 1,
            'file': 'entities',
          },
          {
            'id': 'damage-field',
            'owner': 'AR-11 仲裁者',
            'parameter': '伤害',
            'key': 'damage',
            'before': 66,
            'after': 70,
            'shared': 7,
            'file': 'damage',
          },
        ],
      };
    if (method == 'baseline_cleanup_apply') {
      if (stale) throw StateError('数值已发生变化，请重新预览已有差异');
      restored = args;
      return {'applied': true, 'installed': false};
    }
    return super.call(method, args);
  }
}

void main() {
  testWidgets('默认只选批量晃动，勾选恢复才提交，不安装游戏', (tester) async {
    final backend = CleanupBackend();
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showMotionDialog(
                context: context,
                builder: (_) => BaselineCleanupDialog(backend: backend),
              ),
              child: const Text('整理'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('整理'));
    await tester.pumpAndSettle();
    final checks = tester
        .widgetList<CheckboxListTile>(find.byType(CheckboxListTile))
        .toList();
    expect(checks[0].value, isTrue);
    expect(checks[1].value, isFalse);
    expect(backend.restored, isNull);
    await tester.tap(find.text('暂存所选恢复'));
    await tester.pumpAndSettle();
    expect(backend.restored, [
      '',
      'verified-preview',
      ['sway-field'],
    ]);
    expect(backend.installs, 0);
    expect(tester.takeException(), isNull);
  });
  testWidgets('预览过期时保留选择并提供重新检查', (tester) async {
    final backend = CleanupBackend()..stale = true;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: BaselineCleanupDialog(backend: backend)),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('暂存所选恢复'));
    await tester.pumpAndSettle();
    expect(find.textContaining('数值已发生变化'), findsOneWidget);
    expect(find.text('重新检查'), findsOneWidget);
    expect(
      tester
          .widget<CheckboxListTile>(find.byType(CheckboxListTile).first)
          .value,
      isTrue,
    );
  });
  testWidgets('部件条目使用半透明主题色而非不透明白底', (tester) async {
    final group = CatalogGroup('exo', 'EXO-45');
    final item = {
      'id': 'body',
      'name': 'EXO-45',
      'baseline_state': 'different',
    };
    group.entries.add(item);
    group.matches.add(item);
    for (final dark in [false, true]) {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(
            brightness: dark ? Brightness.dark : Brightness.light,
            extensions: [
              GlassAppearance(
                mode: 'liquid',
                dark: dark,
                blur: 18,
                opacity: .3,
              ),
            ],
          ),
          home: Scaffold(body: GroupChooser(group: group)),
        ),
      );
      await tester.pumpAndSettle();
      final card = tester.widget<Card>(find.byType(Card));
      expect(card.color!.a, lessThan(.2));
      expect(card.elevation, 0);
      expect(find.text('已有差异（启动前存在）'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
  });
}
