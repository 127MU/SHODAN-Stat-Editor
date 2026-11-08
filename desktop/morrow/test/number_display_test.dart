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
  testWidgets('浮点显示为2仍可回车提交2，不重复提交', (tester) async {
    final saved = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ValueInput(
            value: '1.9999999403953552',
            onSave: (v) async {
              saved.add(v);
            },
          ),
        ),
      ),
    );
    expect(find.text('2'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '2');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(saved, ['2']);
    await tester.tap(find.byType(TextField));
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(saved, ['2']);
  });
  testWidgets('编辑回相同显示值，离焦仍提交完整精度变化', (tester) async {
    final saved = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              ValueInput(
                value: '2.000000238418579',
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
    await tester.enterText(find.byType(TextField).first, '3');
    await tester.enterText(find.byType(TextField).first, '2');
    await tester.tap(find.byType(TextField).last);
    await tester.pumpAndSettle();
    expect(saved, ['2']);
  });
  test('保存判断覆盖正负整数、小数和科学计数', () {
    for (final raw in [
      '1.9999999403953552',
      '-1.9999999403953552',
      '0.0001',
      '1.2999999523162842',
    ]) {
      final draft = NumericDraft(raw);
      expect(draft.needsSave(draft.display), false);
      draft.edited = true;
      expect(draft.needsSave(draft.display), true);
    }
    final exact = NumericDraft('2')..edited = true;
    expect(exact.needsSave('2.0'), false);
    expect(exact.needsSave('2e0'), false);
    expect(exact.needsSave('2.000000001'), true);
    expect(exact.needsSave(''), true);
  });
}
