import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shodan_desktop/diagnostics.dart';
import 'package:shodan_desktop/native_service.dart';

void main() {
  test('超长诊断事件有界，不累计无限错误内容', () {
    final log = AppDiagnostics(persist: false);
    log.event('rpc', 'failure', 'error', data: {'error': 'x' * 100000});
    expect(
      (log.structuredEvents.single['data']['error'] as String).length,
      lessThan(8300),
    );
    expect(log.lines.single.length, lessThan(8400));
  });
  test('结构化日志关联请求和耗时，诊断关闭时保留汇总且隐藏敏感键', () async {
    final log = AppDiagnostics(persist: false);
    log.event('rpc', 'rows', 'completed', detail: true);
    expect(log.structuredEvents, isEmpty);
    log.completed('rows', 35, failed: false);
    log.completed('rows', 75, failed: true);
    log.event(
      'rpc',
      'install',
      'error',
      requestId: 9,
      elapsedMs: 75,
      data: {
        'error': r'C:\Users\PrivateName\game',
        'Authorization': 'do-not-export',
        'refresh_token': 'private-token',
      },
    );
    log.record(
      'JSON credentials {"password":"secret with spaces", "api_key":"key-value"}',
    );
    final report = await log.snapshot();
    final stats = (report['operation_stats'] as Map)['rows'];
    expect(stats, {'calls': 2, 'failures': 1, 'total_ms': 110, 'max_ms': 75});
    expect((report['structured_events'] as List).single['request_id'], 9);
    for (final secret in [
      'PrivateName',
      'do-not-export',
      'private-token',
      'secret with spaces',
      'key-value',
    ]) {
      expect(report.toString(), isNot(contains(secret)));
    }
  });
  test('日志上下文不保留搜索文字、预设名称、参数值或 MCP 配置', () {
    expect(
      NativeService.requestContext('desktop-call', {
        'name': 'items',
        'args': ['Primary', '私人搜索词'],
      }),
      isEmpty,
    );
    expect(
      NativeService.requestContext('desktop-call', {
        'name': 'full_preset',
        'args': ['new', null, '私人预设'],
      }),
      isEmpty,
    );
    expect(
      NativeService.requestContext('desktop-call', {
        'name': 'set',
        'args': ['damage', 12345],
      }),
      {'target': 'damage'},
    );
    expect(
      NativeService.resultSummary({
        'config': {'token': 'private'},
        'notes': 'private body',
        'enabled': true,
      }),
      {'enabled': true},
    );
  });
  test('重新导出的日志包含此前会话的已脱敏日志', () async {
    final dir = Directory.systemTemp.createTempSync('shodan-log-history-');
    final logs = Directory('${dir.path}/Logs')..createSync();
    File(
      '${logs.path}/morrow-previous.log',
    ).writeAsStringSync('上次失败 C:/Users/AnotherPrivate/game');
    final report = await AppDiagnostics(
      directory: dir,
      persist: false,
    ).snapshot();
    expect(report['logs'].toString(), contains('上次失败'));
    expect(report['logs'].toString(), isNot(contains('AnotherPrivate')));
    dir.deleteSync(recursive: true);
  });
  test('导出整体脱敏：用户名、嵌套错误和多种用户目录分隔符', () async {
    final dir = Directory.systemTemp.createTempSync('shodan-privacy-test-');
    final log = AppDiagnostics(directory: dir, persist: false);
    final logs = Directory('${dir.path}/Logs')..createSync();
    File('${logs.path}/startup-test.log').writeAsStringSync(
      r'C:\Users\Alice\AppData C:/Users/Bob/AppData C:\\Users\\Charlie\\AppData D:\Documents and Settings\David\file',
    );
    log.checks.add({
      'name': 'error',
      'message': r'C:\Users\EvePrivate\Desktop\file',
    });
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
