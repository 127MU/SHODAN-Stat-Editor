import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shodan_desktop/glass_theme.dart';
import 'package:shodan_desktop/third_party/liquid_glass.dart';

void main() {
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
