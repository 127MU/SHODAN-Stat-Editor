import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'app_version.dart';

class AppDiagnostics {
  AppDiagnostics({this.directory, this.persist = true});
  final bool persist;
  final Directory? directory;
  bool enabled = false;
  final lines = <String>[];
  final checks = <Map<String, dynamic>>[];
  final structuredEvents = <Map<String, dynamic>>[];
  final operations = <String, Map<String, int>>{};
  final workspace = <String, dynamic>{};
  Future<void> _writes = Future.value();
  int _bytes = 0;
  final _session = DateTime.now().millisecondsSinceEpoch;
  Object? _bounded(Object? value, [int depth = 0]) {
    if (depth >= 12) return '<嵌套内容已截断>';
    if (value is String && value.length > 8192) {
      return '${value.substring(0, 8192)}…[已截断]';
    }
    if (value is List)
      return value.take(128).map((v) => _bounded(v, depth + 1)).toList();
    if (value is Map)
      return Map.fromEntries(
        value.entries
            .take(64)
            .map(
              (entry) => MapEntry(entry.key, _bounded(entry.value, depth + 1)),
            ),
      );
    return value;
  }

  Directory get home =>
      directory ??
      Directory(
        Platform.environment['SHODAN_PROFILE'] ??
            '${Platform.environment['LOCALAPPDATA'] ?? File(Platform.resolvedExecutable).parent.path}/SHODAN/StatEditor',
      );

  String redact(String text) {
    final user = Platform.environment['USERPROFILE'];
    if (user != null && user.isNotEmpty) {
      text = text
          .replaceAll(
            RegExp(RegExp.escape(user), caseSensitive: false),
            '<用户目录>',
          )
          .replaceAll(
            RegExp(
              RegExp.escape(user.replaceAll('\\', '/')),
              caseSensitive: false,
            ),
            '<用户目录>',
          );
    }
    text = text.replaceAllMapped(
      RegExp(
        r'((?:[A-Za-z]:[\\/]+)?(?:Users|Documents and Settings)[\\/]+)[^\\/\r\n"<>]+',
        caseSensitive: false,
      ),
      (m) => '${m[1]}<用户>',
    );
    final name = Platform.environment['USERNAME'];
    if (name != null && name.isNotEmpty) {
      text = text.replaceAll(
        RegExp(
          '(?<![A-Za-z0-9_])${RegExp.escape(name)}(?![A-Za-z0-9_])',
          caseSensitive: false,
        ),
        '<用户>',
      );
    }
    return text
        .replaceAll(
          RegExp(r'''Bearer\s+[^\s,;"'}\]]+''', caseSensitive: false),
          'Bearer <已隐藏>',
        )
        .replaceAllMapped(
          RegExp(
            r'''((?:["']?(?:access[_-]?token|refresh[_-]?token|token|password|secret|api[_-]?key|authorization)["']?)\s*[=:]\s*)(?:"[^"\r\n]*"|'[^'\r\n]*'|[^\s,;}\]]+)''',
            caseSensitive: false,
          ),
          (m) {
            final value = m[0]!.substring(m[1]!.length);
            final quote = value.startsWith('"')
                ? '"'
                : value.startsWith("'")
                ? "'"
                : '';
            return '${m[1]}$quote<已隐藏>$quote';
          },
        );
  }

  Object? scrub(Object? value) {
    if (value is String) return redact(value);
    if (value is List) return value.map(scrub).toList();
    if (value is Map) {
      return value.map((k, v) {
        final sensitive = const {
          'token',
          'password',
          'secret',
          'apikey',
          'authorization',
          'accesstoken',
          'refreshtoken',
        }.contains('$k'.toLowerCase().replaceAll(RegExp(r'[_-]'), ''));
        return MapEntry(redact('$k'), sensitive ? '<已隐藏>' : scrub(v));
      });
    }
    return value;
  }

  void event(
    String category,
    String operation,
    String status, {
    int? requestId,
    int? elapsedMs,
    Map<String, dynamic> data = const {},
    bool detail = false,
  }) {
    if (detail && !enabled) return;
    final entry = Map<String, dynamic>.from(
      scrub({
            'time': DateTime.now().toIso8601String(),
            'category': category,
            'operation': operation,
            'status': status,
            if (requestId != null) 'request_id': requestId,
            if (elapsedMs != null) 'elapsed_ms': elapsedMs,
            if (data.isNotEmpty) 'data': _bounded(data),
          })
          as Map,
    );
    structuredEvents.add(entry);
    if (structuredEvents.length > 1200) structuredEvents.removeAt(0);
    record('诊断事件 ${jsonEncode(entry)}');
  }

  void completed(String operation, int elapsedMs, {required bool failed}) {
    // Aggregate even when detailed logging is off; never retain user input.
    if (!operations.containsKey(operation) && operations.length >= 128) return;
    final stats = operations.putIfAbsent(
      operation,
      () => {'calls': 0, 'failures': 0, 'total_ms': 0, 'max_ms': 0},
    );
    stats['calls'] = stats['calls']! + 1;
    stats['failures'] = stats['failures']! + (failed ? 1 : 0);
    stats['total_ms'] = stats['total_ms']! + elapsedMs;
    if (elapsedMs > stats['max_ms']!) stats['max_ms'] = elapsedMs;
  }

  void record(String message, {bool detail = false}) {
    if (detail && !enabled) return;
    final clean = redact(message);
    final bounded = clean.length > 8192
        ? '${clean.substring(0, 8192)}…[已截断]'
        : clean;
    final line = '${DateTime.now().toIso8601String()} $bounded';
    lines.add(line);
    if (lines.length > 500) lines.removeAt(0);
    if (!persist) return;
    if (_bytes >= 2 * 1024 * 1024) return;
    _bytes += utf8.encode(line).length + 1;
    _writes = _writes.catchError((_) {}).then((_) async {
      try {
        final log = File('${home.path}/Logs/morrow-$_session.log');
        await log.parent.create(recursive: true);
        await log.writeAsString('$line\n', mode: FileMode.append);
      } catch (_) {
        /* The diagnostic logger must never stop editing. */
      }
    });
  }

  Future<Map<String, dynamic>> snapshot() async {
    await _writes;
    final attachments = <String, String>{};
    try {
      final logs = Directory('${home.path}/Logs');
      if (await logs.exists()) {
        final files = await logs
            .list()
            .where(
              (f) =>
                  f is File &&
                  (f.path.endsWith('SHODANStatEditorHost.log') ||
                      f.path
                          .split(RegExp(r'[/\\]'))
                          .last
                          .startsWith('startup-') ||
                      f.path
                          .split(RegExp(r'[/\\]'))
                          .last
                          .startsWith('morrow-')),
            )
            .cast<File>()
            .toList();
        files.sort(
          (a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()),
        );
        for (final file in files.take(3)) {
          final handle = await file.open();
          try {
            final length = await handle.length();
            await handle.setPosition(length > 65536 ? length - 65536 : 0);
            attachments[file.uri.pathSegments.last] = redact(
              utf8.decode(await handle.read(65536), allowMalformed: true),
            );
          } finally {
            await handle.close();
          }
        }
      }
    } catch (e) {
      attachments['读取说明'] = '$e';
    }
    return Map<String, dynamic>.from(
      scrub({
            'version': appVersion,
            'schema_version': 2,
            'session_id': _session,
            'created': DateTime.now().toIso8601String(),
            'os': Platform.operatingSystemVersion,
            'diagnostic_mode': enabled,
            'checks': checks,
            'events': List<String>.of(lines),
            'structured_events': List<Map<String, dynamic>>.of(
              structuredEvents,
            ),
            'operation_stats': operations,
            'workspace': workspace,
            'logs': attachments,
          })
          as Map,
    );
  }
}
