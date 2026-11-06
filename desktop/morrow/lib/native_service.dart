import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'diagnostics.dart';

/// Transport only. Release parsing and data operations stay in Rust.
class NativeService {
  NativeService(this.root, this.diagnostics, {this.onProgress});
  final String root;
  final AppDiagnostics diagnostics;
  final void Function(Map<String, dynamic>)? onProgress;
  Process? _process;
  Future<void>? _starting;
  final _pending = <int, Completer<dynamic>>{};
  int _serial = 0;
  bool _closed = false;

  Future<void> _start() async {
    if (_closed) throw StateError('原生服务已关闭');
    final exe = File('$root/shodan-native.exe');
    if (!await exe.exists()) throw StateError('缺少原生数据服务，请使用完整程序包');
    final process = await Process.start(exe.path, [
      '--stdio',
    ], workingDirectory: root);
    if (_closed) {
      process.kill();
      throw StateError('原生服务已关闭');
    }
    _process = process;
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
              if (event is Map<String, dynamic>) onProgress?.call(event);
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
          _fail(StateError('原生服务已退出（$code）'));
        }
      }),
    );
  }

  void _fail(Object error) {
    for (final pending in _pending.values) {
      if (!pending.isCompleted) pending.completeError(error);
    }
    _pending.clear();
  }

  Future<dynamic> call(
    String method, [
    Map<String, dynamic> params = const {},
  ]) async {
    try {
      await (_starting ??= _start());
    } catch (_) {
      _starting = null;
      rethrow;
    }
    if (_process == null || _closed) throw StateError('原生服务不可用');
    final id = ++_serial;
    final pending = Completer<dynamic>();
    _pending[id] = pending;
    try {
      _process!.stdin.writeln(
        jsonEncode({'id': id, 'method': method, 'params': params}),
      );
      final args = params['name'];
      return await pending.future.timeout(
        Duration(
          minutes: method == 'desktop-call' && args == 'install_task' ? 20 : 5,
        ),
      );
    } finally {
      _pending.remove(id);
    }
  }

  Future<void> close() async {
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
