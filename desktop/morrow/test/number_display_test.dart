import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shodan_desktop/main.dart';
import 'package:shodan_desktop/number_display.dart';

void main() {
  test('显示最多两位小数，整数ID不变', () {
    expect(displayNumber('1.2999999523162842'), '1.3');
    expect(displayNumber('1.236'), '1.24');
    expect(displayNumber('-2.567'), '-2.57');
    expect(displayNumber('4294967295'), '4294967295');
    expect(displayNumber('EXO-45'), 'EXO-45');
  });
  testWidgets('仅查看或离焦不会将原始精度写回', (tester) async {
    final saved = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              ValueInput(
                value: '1.2999999523162842',
                onSave: (v) async {
                  saved.add(v);
                },
              ),
              const TextField(),
            ],
          ),
        ),
      ),
    );
    expect(find.text('1.3'), findsOneWidget);
    await tester.tap(find.byType(TextField).first);
    await tester.tap(find.byType(TextField).last);
    await tester.pumpAndSettle();
    expect(saved, isEmpty);
    await tester.enterText(find.byType(TextField).first, '1.4567');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(saved, ['1.4567']);
    expect(find.text('1.46'), findsOneWidget);
  });
}
