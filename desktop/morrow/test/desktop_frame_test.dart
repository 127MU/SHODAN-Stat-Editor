import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shodan_desktop/desktop_frame.dart';

void main() {
  testWidgets('窗口按钮在弹窗打开时仍然可见且可操作', (tester) async {
    const channel = MethodChannel('window_manager');
    final messenger = tester.binding.defaultBinaryMessenger;
    final calls = <String>[];
    var maximized = false;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      switch (call.method) {
        case 'isMaximized':
          return maximized;
        case 'maximize':
          maximized = true;
        case 'unmaximize':
          maximized = false;
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    Future<void> windowEvent(String event) async {
      await messenger.handlePlatformMessage(
        channel.name,
        channel.codec.encodeMethodCall(
          MethodCall('onEvent', {'eventName': event}),
        ),
        (_) {},
      );
      await tester.pumpAndSettle();
    }

    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => DesktopFrame(
          onClose: () async {},
          onCloseError: (error) => fail('$error'),
          child: child!,
        ),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => const AlertDialog(title: Text('编辑参数')),
              ),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    expect(find.text('编辑参数'), findsOneWidget);
    expect(find.byTooltip('最小化').hitTestable(), findsOneWidget);
    expect(find.byTooltip('关闭').hitTestable(), findsOneWidget);
    await tester.tap(find.byTooltip('最大化'));
    await windowEvent('maximize');
    await tester.tap(find.byTooltip('还原窗口'));
    await windowEvent('unmaximize');
    expect(calls, containsAllInOrder(['maximize', 'unmaximize']));
    expect(find.byTooltip('最大化').hitTestable(), findsOneWidget);
    expect(find.text('编辑参数'), findsOneWidget);
    expect(tester.takeException(), isNull);
  }, skip: !Platform.isWindows);
}
