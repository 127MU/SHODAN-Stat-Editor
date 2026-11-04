import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shodan_desktop/glass_theme.dart';
import 'package:shodan_desktop/third_party/liquid_glass.dart';
import 'package:shodan_desktop/window_activity.dart';
import 'package:shodan_desktop/main.dart' show ValueInput;

void main() {
  testWidgets('缩放期间暂停玻璃滤镜，输入状态保留，松开后恢复材质', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GlassPanel(
            child: ValueInput(value: '1', onSave: (_) async {}),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final before = tester.state(find.byType(LiquidGlassSurface));
    await tester.enterText(find.byType(TextField), '321');
    windowResizing.value = true;
    await tester.pump();
    expect(find.byType(BackdropFilter), findsNothing);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '321',
    );
    expect(
      identical(tester.state(find.byType(LiquidGlassSurface)), before),
      isTrue,
    );
    windowResizing.value = false;
    await tester.pumpAndSettle();
    expect(find.byType(BackdropFilter), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '321',
    );
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('弹窗和卡片接收相同的材质设置', (tester) async {
    for (final mode in ['liquid', 'frosted', 'clear']) {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(
            extensions: [
              GlassAppearance(mode: mode, dark: true, blur: 18, opacity: .3),
            ],
          ),
          home: const Scaffold(
            body: GlassDialog(
              title: Text('参数'),
              content: SizedBox(
                width: 600,
                height: 300,
                child: GlassPanel(child: Text('数值')),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final surfaces = tester.widgetList<LiquidGlassSurface>(
        find.byType(LiquidGlassSurface),
      );
      expect(surfaces.length, 2);
      for (final surface in surfaces) {
        expect(
          surface.material?.blur,
          mode == 'liquid'
              ? null
              : mode == 'frosted'
              ? 18
              : 0,
        );
      }
      expect(tester.takeException(), isNull);
    }
  });
}
