import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shodan_desktop/glass_theme.dart';
import 'package:shodan_desktop/motion.dart';

class _PaintProbe extends CustomPainter {
  int paints = 0;
  @override
  void paint(Canvas canvas, Size size) {
    paints++;
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.blue);
  }

  @override
  bool shouldRepaint(covariant _PaintProbe oldDelegate) => false;
}

void main() {
  test('圆形扩散从触发位置开始，完全展开后覆盖全部窗口', () {
    const size = Size(1200, 800);
    for (final anchor in [
      Alignment.center,
      Alignment.topLeft,
      Alignment.bottomRight,
    ]) {
      final origin = anchor.alongSize(size);
      final hidden = DialogApertureClipper(
        progress: const AlwaysStoppedAnimation(0),
        anchor: anchor,
      ).getClip(size);
      expect(hidden.computeMetrics().isEmpty, isTrue);
      final partial = DialogApertureClipper(
        progress: const AlwaysStoppedAnimation(.01),
        anchor: anchor,
      ).getClip(size);
      expect(partial.contains(origin), isTrue);
      expect(partial.getBounds().width, lessThan(size.width));
      final full = DialogApertureClipper(
        progress: const AlwaysStoppedAnimation(1),
        anchor: anchor,
      ).getClip(size);
      expect(full.getBounds(), Offset.zero & size);
    }
  });

  testWidgets('关闭时缓存内容绘制，退场结束后才交回结果', (tester) async {
    final painter = _PaintProbe();
    var returned = false;
    var closing = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                final result = await showMotionDialog<int>(
                  context: context,
                  onDismissStart: () => closing++,
                  builder: (ctx) => GlassDialog(
                    title: const Text('参数'),
                    content: SizedBox(
                      width: 500,
                      height: 240,
                      child: CustomPaint(painter: painter),
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(ctx, 7),
                        child: const Text('关闭'),
                      ),
                    ],
                  ),
                );
                expect(result, 7);
                returned = true;
              },
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('关闭'));
    await tester.pump();
    expect(closing, 1);
    expect(returned, isFalse);
    // The first reverse frame may replace the resting glass filter. Once it
    // settles, the panel should paint once and retain its contents, not repaint
    // a full parameter grid at every transform tick.
    await tester.pump(const Duration(milliseconds: 16));
    final paints = painter.paints;
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(painter.paints, paints);
    expect(returned, isFalse);
    await tester.pumpAndSettle();
    expect(returned, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('减少动态效果时关闭不等待动画', (tester) async {
    var returned = false;
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  await showMotionDialog<void>(
                    context: context,
                    builder: (ctx) => GlassDialog(
                      title: const Text('参数'),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(ctx),
                          child: const Text('关闭'),
                        ),
                      ],
                    ),
                  );
                  returned = true;
                },
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(returned, isTrue);
    expect(tester.takeException(), isNull);
  });
}
