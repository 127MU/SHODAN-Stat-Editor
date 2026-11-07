import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shodan_desktop/main.dart';
import 'package:shodan_desktop/theme_reveal.dart';

import 'editor_test.dart' show FakeBackend;

void main() {
  testWidgets('强调色菜单支持预设和自定义颜色', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1480, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      Workbench(backend: FakeBackend(), persistAppearance: false),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('navigation-Settings')));
    await tester.pumpAndSettle();
    final menu = find.text('选择颜色');
    await tester.scrollUntilVisible(
      menu,
      240,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.pumpAndSettle();
    await tester.tap(menu);
    await tester.pumpAndSettle();
    await tester.tap(find.text('青绿'));
    await tester.pumpAndSettle();
    expect(find.text('#14B8A6'), findsOneWidget);
    await tester.tap(menu);
    await tester.pumpAndSettle();
    await tester.tap(find.text('自定义颜色…'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), '#123ABC');
    await tester.tap(find.text('应用'));
    await tester.pumpAndSettle();
    expect(find.text('#123ABC'), findsOneWidget);
  });

  testWidgets('减少动画模式立即切换主题', (tester) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await tester.pumpWidget(
      Workbench(backend: FakeBackend(), persistAppearance: false),
    );
    await tester.pumpAndSettle();
    final toggle = find.byTooltip('切换深浅色');
    await tester.tap(toggle);
    await tester.pump();
    expect(Theme.of(tester.element(toggle)).brightness, Brightness.light);
    expect(
      find.byWidgetPredicate(
        (widget) => widget is CustomPaint && widget.painter is ThemeReveal,
      ),
      findsNothing,
    );
  });

  testWidgets('主题从点击位置揭幕，动画结束后释放快照', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1100, 750));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      Workbench(backend: FakeBackend(), persistAppearance: false),
    );
    await tester.pumpAndSettle();
    final toggle = find.byTooltip('切换深浅色');
    final button = tester.getCenter(toggle);
    await tester.runAsync(() async {
      await tester.tapAt(button + const Offset(4, 0));
      await Future<void>.delayed(const Duration(milliseconds: 120));
    });
    await tester.pump();
    final reveals = find.byWidgetPredicate(
      (widget) => widget is CustomPaint && widget.painter is ThemeReveal,
    );
    expect(reveals, findsOneWidget);
    final reveal = tester.widget<CustomPaint>(reveals).painter as ThemeReveal;
    expect(reveal.reverse, isTrue);
    expect(reveal.origin.dx, closeTo(button.dx + 4, 1));
    expect(reveal.origin.dy, closeTo(button.dy, 1));
    await tester.pumpAndSettle();
    expect(reveals, findsNothing);
    expect(Theme.of(tester.element(toggle)).brightness, Brightness.light);
  });
}
