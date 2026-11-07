import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/glass_theme.dart';
import '../lib/motion.dart';
import '../lib/window_activity.dart';

void main() {
  testWidgets('目录卡片错峰滑入，减少动态效果时直接显示', (tester) async {
    Widget catalog({required bool reduced}) => MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(
          size: const Size(800, 600),
          disableAnimations: reduced,
        ),
        child: CatalogEntrance(
          key: ValueKey(reduced),
          builder: (context, animation) => Column(
            children: [
              CatalogEntrance.card(animation, 1, const Text('第一张'), columns: 2),
              CatalogEntrance.card(animation, 0, const Text('第二张'), columns: 2),
            ],
          ),
        ),
      ),
    );
    double first() => tester.getTopLeft(find.text('第一张')).dx;
    double second() => tester.getTopLeft(find.text('第二张')).dx;
    await tester.pumpWidget(catalog(reduced: false));
    await tester.pump();
    final firstStart = first();
    final secondStart = second();
    expect(firstStart, greaterThanOrEqualTo(800));
    await tester.pump(const Duration(milliseconds: 32));
    expect(first(), lessThan(firstStart));
    expect(second(), secondStart);
    await tester.pumpAndSettle();
    final firstRest = first();
    final secondRest = second();
    expect(secondRest, lessThan(secondStart));
    await tester.pumpWidget(catalog(reduced: true));
    expect(first(), firstRest);
    expect(second(), secondRest);
  });

  testWidgets('玻璃动画保留滤镜，缩放窗口保留输入框焦点', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BackdropGroup(
            child: Builder(
              builder: (context) => Center(
                child: SizedBox(
                  width: 320,
                  child: GlassAppearance.of(
                    context,
                  ).wrap(const TextField(), grouped: false),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final backdrop = find.byType(BackdropFilter);
    final filter = tester.widget<BackdropFilter>(backdrop).filter;
    final field = find.byType(TextField);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: tester.getCenter(field));
    await mouse.moveBy(const Offset(40, 0));
    await tester.tap(field);
    await tester.pump(const Duration(milliseconds: 80));
    expect(tester.widget<BackdropFilter>(backdrop).filter, same(filter));

    try {
      windowResizing.value = true;
      await tester.pump();
      expect(backdrop, findsNothing);
      expect(
        tester
            .widget<EditableText>(find.byType(EditableText))
            .focusNode
            .hasFocus,
        isTrue,
      );
    } finally {
      windowResizing.value = false;
    }
    await tester.pump();
    expect(backdrop, findsOneWidget);
  });
}
