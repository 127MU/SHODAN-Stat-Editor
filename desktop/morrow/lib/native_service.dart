import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'diagnostics.dart';

/// Transport only. Release parsing and data operations stay in Rust.
class NativeService {
  NativeService(
    this.root,
    this.diagnostics, {
    this.onProgress,
    this.processFactory,
  });
  final Future<Process> Function(
    String executable,
    List<String> arguments,
    String directory,
  )?
  processFactory;
  final String root;
  final AppDiagnostics diagnostics;
  final void Function(Map<String, dynamic>)? onProgress;
  Process? _process;
  Future<void>? _starting;
  final _pending = <int, Completer<dynamic>>{};
  int _serial = 0;
  bool _closed = false;

  static Map<String, dynamic> resultSummary(dynamic result) {
    if (result is List) return {'items': result.length};
    if (result is! Map) return {'type': result.runtimeType.toString()};
    final summary = <String, dynamic>{};
    for (final key in [
      'ok',
      'pending',
      'idle',
      'enabled',
      'dirty',
      'newer',
      'version',
      'current',
      'count',
      'files_changed',
    ]) {
      if (result[key] is bool ||
          result[key] is num ||
          (['version', 'current'].contains(key) && result[key] is String)) {
        summary[key] = result[key];
      }
    }
    for (final key in ['problems', 'warnings', 'migration_notes', 'actions']) {
      if (result[key] is List) {
        final entries = result[key] as List;
        summary['${key}_count'] = entries.length;
        summary[key] = entries.take(20).map((entry) {
          final text = '$entry';
          return text.length > 512 ? '${text.substring(0, 512)}…' : text;
        }).toList();
      }
    }
    for (final key in ['files', 'entries', 'adjusted', 'groups']) {
      if (result[key] is List)
        summary['${key}_count'] = (result[key] as List).length;
    }
    return summary;
  }

  static Map<String, dynamic> requestContext(
    String method,
    Map<String, dynamic> params,
  ) {
    final result = <String, dynamic>{};
    if (method == 'desktop-call' && params['args'] is List) {
      final args = params['args'] as List;
      if (const {
            'select',
            'set',
            'reset',
            'choose',
            'rows_delta',
            'rows_section',
            'armor_set',
            'armor_rows',
            'armor_reset',
            'tweaks',
          }.contains(params['name']) &&
          args.isNotEmpty &&
          args.first is String &&
          RegExp(r'^[A-Za-z0-9_:.-]{1,128}$').hasMatch(args.first as String)) {
        result['target'] = args.first;
      }
      if (const {
        'install_task',
        'restore_task',
        'install_preview',
      }.contains(params['name'])) {
        if (args.isNotEmpty && args[0] is bool)
          result['allow_float_adjustment'] = args[0];
        if (args.length > 1 && args[1] is bool) result['force'] = args[1];
      }
    }
    return result;
  }

  Future<void> _start() async {
    if (_closed) throw StateError('原生服务已关闭');
    final exe = File('$root/shodan-native.exe');
    if (!await exe.exists()) throw StateError('缺少原生数据服务，请使用完整程序包');
    final process =
        await (processFactory?.call(exe.path, ['--stdio'], root) ??
            Process.start(exe.path, ['--stdio'], workingDirectory: root));
    if (_closed) {
      process.kill();
      throw StateError('原生服务已关闭');
    }
    _process = process;
    diagnostics.event('engine', 'start', 'ready', data: {'pid': process.pid});
    unawaited(process.stdin.done.then<void>((_) {}, onError: _fail));
    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          try {
            final response = jsonDecode(line) as Map;
            final completer = _pending.remove(response['id']);
            if (completer == null) return;
            if (response['ok'] == true) {
              completer.complete(response['result']);
            } else {
              completer.completeError(StateError('${response['error']}'));
            }
          } catch (e) {
            _fail(e);
          }
        }, onError: _fail);
    process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          const prefix = '@shodan-progress ';
          if (line.startsWith(prefix)) {
            try {
              final event = jsonDecode(line.substring(prefix.length));
              if (event is Map<String, dynamic>) {
                diagnostics.event(
                  'installation',
                  'progress',
                  'running',
                  data: {
                    'stage': event['stage'],
                    'done': event['done'],
                    'total': event['total'],
                    'pending_requests': _pending.keys.toList(),
                  },
                );
                onProgress?.call(event);
              }
            } catch (_) {
              diagnostics.record('原生服务：无法解析安装进度');
            }
          } else {
            diagnostics.record('原生服务：$line', detail: true);
          }
        }, onError: _fail);
    unawaited(
      process.exitCode.then((code) {
        if (identical(_process, process)) {
          _process = null;
          _starting = null;
          diagnostics.event(
            'engine',
            'exit',
            'error',
            data: {
              'exit_code': code,
              'pending_requests': _pending.keys.toList(),
            },
          );
          _fail(StateError('原生服务已退出（$code）'));
        }
      }),
    );
  }

  void _fail(Object error) {
    diagnostics.event(
      'engine',
      'transport',
      _closed ? 'closed' : 'error',
      data: {'error': '$error', 'pending_requests': _pending.keys.toList()},
    );
    for (final pending in _pending.values) {
      if (!pending.isCompleted) pending.completeError(error);
    }
    _pending.clear();
  }

  Future<dynamic> call(
    String method, [
    Map<String, dynamic> params = const {},
  ]) async {
    final id = ++_serial;
    final timer = Stopwatch()..start();
    final operation = method == 'desktop-call'
        ? 'desktop:${params['name']}'
        : method;
    final critical = const {
      'game-open',
      'game-repair',
      'game-install',
      'game-restore',
      'desktop:install_preview',
      'desktop:install_task',
      'desktop:restore_task',
      'mcp-start',
      'mcp-stop',
      'update-start',
    }.contains(operation);
    final context = requestContext(method, params);
    diagnostics.event(
      'rpc',
      operation,
      'started',
      requestId: id,
      data: context,
      detail: !critical,
    );
    try {
      try {
        await (_starting ??= _start());
      } catch (_) {
        _starting = null;
        rethrow;
      }
      if (_process == null || _closed) throw StateError('原生服务不可用');
      final pending = Completer<dynamic>();
      _pending[id] = pending;
      _process!.stdin.writeln(
        jsonEncode({'id': id, 'method': method, 'params': params}),
      );
      final args = params['name'];
      final result = await pending.future.timeout(
        Duration(
          minutes: method == 'desktop-call' && args == 'install_task' ? 20 : 5,
        ),
      );
      final failed = result is Map && result['ok'] == false;
      diagnostics.completed(
        operation,
        timer.elapsedMilliseconds,
        failed: failed,
      );
      diagnostics.event(
        'rpc',
        operation,
        failed ? 'not_completed' : 'completed',
        requestId: id,
        elapsedMs: timer.elapsedMilliseconds,
        data: {...context, ...resultSummary(result)},
        detail: !critical && !failed && timer.elapsedMilliseconds < 1000,
      );
      return result;
    } catch (error) {
      diagnostics.completed(operation, timer.elapsedMilliseconds, failed: true);
      diagnostics.event(
        'rpc',
        operation,
        error is TimeoutException ? 'timeout' : 'error',
        requestId: id,
        elapsedMs: timer.elapsedMilliseconds,
        data: {
          ...context,
          'error': '$error',
          'engine_running': _process != null,
          'pending_count': _pending.length,
        },
      );
      rethrow;
    } finally {
      _pending.remove(id);
    }
  }

  Future<void> close() async {
    diagnostics.event(
      'engine',
      'close',
      'requested',
      data: {'pending_count': _pending.length},
    );
    _closed = true;
    // No data is owned by this transport. UI shutdown never starts a save.
    final process = _process;
    _process = null;
    _fail(StateError('原生服务已关闭'));
    if (process != null) {
      try {
        await process.stdin.close();
        await process.exitCode.timeout(const Duration(seconds: 2));
      } catch (_) {
        process.kill();
      }
    }
  }
}
