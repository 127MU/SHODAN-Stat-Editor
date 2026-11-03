import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shodan_desktop/diagnostics.dart';

void main() {
  test('导出整体脱敏：用户名、嵌套错误和多种用户目录分隔符', () async {
    final dir = Directory.systemTemp.createTempSync('shodan-privacy-test-');
    final log = AppDiagnostics(directory: dir, persist: false);
    final logs = Directory('${dir.path}/Logs')..createSync();
    File('${logs.path}/startup-test.log').writeAsStringSync(
      r'C:\Users\Alice\AppData C:/Users/Bob/AppData C:\\Users\\Charlie\\AppData D:\Documents and Settings\David\file',
    );
    log.checks.add({'name': 'error', 'message': r'C:\Users\EvePrivate\Desktop\file'});
    final username = Platform.environment['USERNAME'];
    if (username != null) log.record('current username=$username');
    final report = (await log.snapshot()).toString();
    for (final private in [
      'Alice',
      'Bob',
      'Charlie',
      'David',
      'EvePrivate',
      if (username != null) username,
    ]) {
      expect(report.toLowerCase(), isNot(contains(private.toLowerCase())));
    }
    expect(report, contains('<用户>'));
    dir.deleteSync(recursive: true);
  });
  test('诊断模式控制详细记录，导出快照隐藏凭据并保留错误', () async {
    final dir = Directory.systemTemp.createTempSync('shodan-logs-test-');
    final log = AppDiagnostics(directory: dir);
    log.record('normal error');
    log.record('detailed timing', detail: true);
    expect(log.lines.length, 1);
    log.enabled = true;
    log.record('detailed timing', detail: true);
    log.record('token=example-secret Bearer example-credential');
    final report = await log.snapshot();
    final text = report.toString();
    expect(text, contains('normal error'));
    expect(text, contains('detailed timing'));
    expect(text, isNot(contains('example-secret')));
    expect(text, isNot(contains('example-credential')));
    expect(Directory('${dir.path}/Logs').listSync(), isNotEmpty);
    dir.deleteSync(recursive: true);
  });
}
