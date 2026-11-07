import 'dart:async';
import 'dart:io';
import 'diagnostics.dart';
import 'native_service.dart';

class Backend {
  Backend({this.runtimeDirectory, AppDiagnostics? diagnostics})
    : diagnostics = diagnostics ?? AppDiagnostics();

  final AppDiagnostics diagnostics;
  final progress = StreamController<Map<String, dynamic>>.broadcast();
  final String? runtimeDirectory;
  String get root =>
      runtimeDirectory ?? File(Platform.resolvedExecutable).parent.path;
  bool usesNativeDesktop = false;
  String? startupProblem;

  late final native = NativeService(
    root,
    diagnostics,
    onProgress: (event) {
      if (!progress.isClosed) progress.add(event);
    },
  );

  Future<dynamic> nativeCall(
    String method, [
    Map<String, dynamic> params = const {},
  ]) => native.call(method, params);

  Future<void> start() async {
    diagnostics.record('数据引擎启动');
    startupProblem = null;
    usesNativeDesktop = true;
    final opened = await native.call('game-open', {'runtime': root});
    if (opened is Map) {
      diagnostics.workspace.addAll(
        Map<String, dynamic>.from(
          diagnostics.scrub({
                'runtime': root,
                'game': opened['game'],
                'catalog': opened['catalog'],
                'startup_problems': opened['problems'],
                'migration_notes': opened['migration_notes'],
              })
              as Map,
        ),
      );
    }
    if (opened is Map &&
        opened['problems'] is List &&
        (opened['problems'] as List).isNotEmpty) {
      startupProblem = (opened['problems'] as List).first.toString();
      diagnostics.record('工作区检查：$startupProblem');
    }
    if (opened is Map && opened['migration_notes'] is List) {
      for (final note in opened['migration_notes'] as List) {
        diagnostics.record('$note');
      }
    }
    usesNativeDesktop = true;
    diagnostics.record('Rust 数据引擎已就绪');
  }

  Future<dynamic> call(String method, [List<dynamic> args = const []]) async {
    final timer = Stopwatch()..start();
    try {
      return await native.call('desktop-call', {'name': method, 'args': args});
    } catch (e) {
      diagnostics.record('接口失败 $method：$e');
      rethrow;
    } finally {
      diagnostics.record(
        '接口结束 $method；${timer.elapsedMilliseconds} ms',
        detail: true,
      );
    }
  }

  Future<String> diagnose() async {
    diagnostics.event('diagnostic', 'read_only_check', 'started');
    diagnostics.checks.clear();
    try {
      final checks = await nativeCall(
        'diagnostic-check',
      ).timeout(const Duration(seconds: 10));
      diagnostics.checks.addAll(
        (checks as List).whereType<Map>().map(Map<String, dynamic>.from),
      );
    } catch (e) {
      diagnostics.checks.add({'name': '数据引擎连接', 'ok': false, 'message': '$e'});
    }
    if (usesNativeDesktop) {
      try {
        final report = await call(
          'baseline_check',
        ).timeout(const Duration(seconds: 30));
        if (report is Map) {
          diagnostics.workspace['last_file_check'] = diagnostics.scrub(report);
          final problems = report['problems'] is List
              ? report['problems'] as List
              : [];
          diagnostics.checks.add({
            'name': '游戏文件、原值及资源补丁',
            'ok': problems.isEmpty,
            'message': problems.isEmpty ? '已逐项核对文件和补丁登记' : problems.join('\n'),
          });
        } else {
          throw StateError('文件检查未返回有效结果');
        }
      } catch (e) {
        diagnostics.checks.add({
          'name': '游戏工作区检查',
          'ok': false,
          'message': '$e',
        });
      }
    }
    final failed = diagnostics.checks.where((c) => c['ok'] != true).length;
    final result = failed == 0
        ? '只读诊断通过，未修改游戏文件。'
        : '发现 $failed 项异常，详情可导出日志查看。未修改游戏文件。';
    diagnostics.record(result);
    diagnostics.event(
      'diagnostic',
      'read_only_check',
      failed == 0 ? 'completed' : 'not_completed',
      data: {'checks': diagnostics.checks.length, 'failed': failed},
    );
    return result;
  }

  Future<Map> repair() async {
    diagnostics.record('开始自动修复');
    final report = await nativeCall('game-repair', {'runtime': root});
    if (report is! Map) throw StateError('自动修复未返回有效结果');
    final problems = report['problems'] is List
        ? report['problems'] as List
        : [];
    startupProblem = problems.isEmpty ? null : problems.first.toString();
    diagnostics.record('${report['message'] ?? '自动修复结束'}');
    diagnostics.workspace['last_repair'] = diagnostics.scrub(report);
    return report;
  }

  Future<void>? _closing;
  Future<void> close() => _closing ??= native.close();
}
