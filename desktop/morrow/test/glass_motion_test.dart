import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter_test/flutter_test.dart';

import '../lib/glass_theme.dart';
import '../lib/motion.dart';
import '../lib/window_activity.dart';

void main() {
  testWidgets('目录卡片随时间滑入，减少动态效果时直接显示', (tester) async {
    Widget catalog({required bool reduced, int columns = 2}) => MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(
          size: const Size(800, 600),
          disableAnimations: reduced,
        ),
        child: CatalogEntrance(
          key: ValueKey((reduced, columns)),
          builder: (context, animation) => Column(
            children: [
              CatalogEntrance.card(
                animation,
                1,
                const Text('第一张'),
                columns: columns,
              ),
              CatalogEntrance.card(
                animation,
                0,
                const Text('第二张'),
                columns: columns,
              ),
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
    // 同一行的右侧卡片先动，左侧卡片略微滞后。
    expect(firstStart - first(), greaterThan(secondStart - second()));
    await tester.pumpAndSettle();
    final firstRest = first();
    final secondRest = second();
    expect(secondRest, lessThan(secondStart));
    await tester.pumpWidget(catalog(reduced: true));
    expect(first(), firstRest);
    expect(second(), secondRest);
    await tester.pumpWidget(catalog(reduced: false, columns: 1));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 32));
    expect(second(), lessThan(first()));
    await tester.pumpAndSettle();
  });

  testWidgets('滚动进入视口的卡片按实时位置滑入', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = ScrollController();
    var cardBuilds = 0;
    var clicks = 0;
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: CatalogEntrance(
          builder: (context, animation) => ListView.builder(
            controller: controller,
            scrollCacheExtent: const ScrollCacheExtent.pixels(400),
            itemCount: 20,
            itemBuilder: (context, i) => SizedBox(
              height: 200,
              child: CatalogEntrance.card(
                animation,
                i,
                Builder(
                  builder: (context) {
                    if (i == 3) cardBuilds++;
                    return Align(
                      alignment: Alignment.topLeft,
                      child: TextButton(
                        onPressed: () => clicks++,
                        child: Text('卡$i'),
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.text('卡0')).dx, lessThan(40));
    controller.jumpTo(1);
    await tester.pump();
    final far = tester.getTopLeft(find.text('卡3', skipOffstage: false)).dx;
    expect(far, greaterThan(700));
    final buildsBeforeScroll = cardBuilds;
    controller.jumpTo(100);
    await tester.pump();
    final near = tester.getTopLeft(find.text('卡3')).dx;
    expect(near, lessThan(far));
    expect(cardBuilds, buildsBeforeScroll);
    await tester.tap(find.text('卡3'));
    expect(clicks, 1);
    controller.jumpTo(300);
    await tester.pump();
    expect(tester.getTopLeft(find.text('卡3')).dx, lessThan(near));

    controller.jumpTo(1300);
    await tester.pump();
    final later = tester.getTopLeft(find.text('卡9')).dx;
    controller.jumpTo(1500);
    await tester.pump();
    expect(tester.getTopLeft(find.text('卡9')).dx, lessThan(later));
    controller.jumpTo(1300);
    await tester.pump();
    expect(tester.getTopLeft(find.text('卡9')).dx, closeTo(later, .01));
    await tester.binding.setSurfaceSize(const Size(800, 800));
    await tester.pump();
    expect(tester.getTopLeft(find.text('卡9')).dx, lessThan(later));
    expect(tester.takeException(), isNull);
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
