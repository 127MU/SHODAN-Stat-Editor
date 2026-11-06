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
    final opened = await native.call('game-open', {'runtime': root});
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
    final failed = diagnostics.checks.where((c) => c['ok'] != true).length;
    final result = failed == 0
        ? '只读诊断通过，未修改游戏文件。'
        : '发现 $failed 项异常，详情可导出日志查看。未修改游戏文件。';
    diagnostics.record(result);
    return result;
  }

  Future<void>? _closing;
  Future<void> close() => _closing ??= native.close();
}
