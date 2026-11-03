import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'diagnostics.dart';

class Backend {
  Backend({this.runtimeDirectory, AppDiagnostics? diagnostics})
    : diagnostics = diagnostics ?? AppDiagnostics();
  final AppDiagnostics diagnostics;
  final progress = StreamController<Map<String, dynamic>>.broadcast();
  final String? runtimeDirectory;
  Process? _process;
  int _next = 0;
  String _diagnostics = "";
  Object? _failure;
  final _pending = <int, Completer<dynamic>>{};
  Future<void> start() async {
    diagnostics.record('数据引擎启动');
    final root =
        runtimeDirectory ?? File(Platform.resolvedExecutable).parent.path;
    _process = await Process.start('$root/shodan-core.exe', [
      root,
    ], workingDirectory: root);
    unawaited(_process!.stdin.done.then<void>((_) {}, onError: _fail));
    _process!.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          try {
            final message = jsonDecode(line) as Map;
            final c = _pending.remove(message['id']);
            if (c == null) return;
            if (message['error'] != null) {
              c.completeError(StateError(message['error']));
            } else {
              c.complete(message['data']);
            }
          } catch (e) {
            _fail(e);
          }
        }, onError: _fail);
    final stderrDone = Completer<void>();
    _process!.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (text) {
            if (text.startsWith('@shodan-progress ')) {
              try {
                final event = Map<String, dynamic>.from(
                  jsonDecode(text.substring(17)) as Map,
                );
                progress.add(event);
                diagnostics.record(
                  '安装阶段：${event['stage']} (${event['done']}/${event['total']})',
                );
                return;
              } catch (_) {
                diagnostics.record('无法解析安装进度事件');
              }
            }
            diagnostics.record('数据引擎：$text');
            _diagnostics += text;
            if (_diagnostics.length > 16384)
              _diagnostics = _diagnostics.substring(
                _diagnostics.length - 16384,
              );
            stderr.write(text);
          },
          onDone: () => stderrDone.complete(),
          onError: (Object e) {
            if (!stderrDone.isCompleted) stderrDone.complete();
          },
        );
    _process!.exitCode.then((code) async {
      await stderrDone.future;
      _fail(StateError('数据引擎已退出（$code）\n$_diagnostics'));
    });
    await call('info');
    diagnostics.record('数据引擎已就绪');
  }

  void _fail(Object e) {
    diagnostics.record('数据引擎异常：$e');
    _failure = e;
    for (final c in _pending.values) {
      if (!c.isCompleted) c.completeError(e);
    }
    _pending.clear();
  }

  Future<dynamic> call(String method, [List<dynamic> args = const []]) async {
    if (_failure != null) throw StateError('数据引擎连接已断开，请重新启动编辑器。\n$_failure');
    if (_process == null) throw StateError('数据引擎未启动');
    final id = ++_next;
    final timer = Stopwatch()..start();
    diagnostics.record(
      '接口开始 $method #$id；等待数 ${_pending.length}',
      detail: true,
    );
    final c = Completer<dynamic>();
    _pending[id] = c;
    try {
      _process!.stdin.writeln(
        jsonEncode({'id': id, 'method': method, 'args': args}),
      );
      return await c.future.timeout(
        Duration(
          minutes: method == 'install_task'
              ? 20
              : [
                  'install_preview',
                  'diagnostic_resources',
                  'ragdoll_apply',
                ].contains(method)
              ? 5
              : 1,
        ),
      );
    } catch (e) {
      diagnostics.record('接口失败 $method #$id：$e');
      rethrow;
    } finally {
      diagnostics.record(
        '接口结束 $method #$id；${timer.elapsedMilliseconds} ms',
        detail: true,
      );
      _pending.remove(id);
    }
  }

  Future<String> diagnose() async {
    diagnostics.checks.clear();
    final root =
        runtimeDirectory ?? File(Platform.resolvedExecutable).parent.path;
    for (final name in [
      'shodan-core.exe',
      'lua51.dll',
      'libsodium.dll',
      'shodan_hash.dll',
      'app/host.lua',
      'app/stat_editor.lua',
      'data/app.so',
    ]) {
      final f = File('$root/$name');
      final exists = await f.exists();
      final ok = exists && await f.length() > 0;
      diagnostics.checks.add({
        'name': name,
        'ok': ok,
        'message': ok ? '文件存在且非空' : '文件缺失或为空',
      });
    }
    try {
      final info = await call('info').timeout(const Duration(seconds: 10));
      diagnostics.checks.add({
        'name': '数据引擎连接',
        'ok': info is Map,
        'message': info is Map ? '响应正常' : '响应格式异常',
      });
      if (info is Map && info['game'] is String) {
        final ok = await Directory(info['game']).exists();
        diagnostics.checks.add({
          'name': '游戏数据目录',
          'ok': ok,
          'message': ok ? '已找到' : '未找到；请检查游戏路径',
        });
      }
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
  Future<void> close() async {
    try {
      await (_closing ??= _shutdown());
    } catch (_) {
      _closing = null;
      rethrow;
    }
  }

  Future<void> _shutdown() async {
    if (_process != null) {
      if (_failure != null) {
        _process = null;
        return;
      }
      await call('flush');
      _process!.stdin.writeln(jsonEncode({'method': 'shutdown'}));
      await _process!.stdin.close();
      await _process!.exitCode.timeout(const Duration(seconds: 10));
      _process = null;
    }
  }
}
