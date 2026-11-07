import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shodan_desktop/desktop_frame.dart';

void main() {
  testWidgets('窗口顶栏在内容切换、主题变化和缩放后保持显示', (tester) async {
    const channel = MethodChannel('window_manager');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => call.method == 'isMaximized' ? false : null);
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
      tester.binding.setSurfaceSize(null);
    });
    for (final dark in [false, true, false]) {
      await tester.binding.setSurfaceSize(Size(dark ? 1100 : 1360, 850));
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData(brightness: dark ? Brightness.dark : Brightness.light),
        home: DesktopFrame(onClose: () async {}, onCloseError: (error) => fail('$error'),
          child: Scaffold(body: Center(child: Text(dark ? '参数页' : '目录页')))),
      ));
      await tester.pumpAndSettle();
      expect(find.text('SHODAN 数值编辑器'), findsOneWidget);
      expect(find.byTooltip('最小化'), findsOneWidget);
      expect(find.byTooltip('关闭'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
  }, skip: !Platform.isWindows);
}
