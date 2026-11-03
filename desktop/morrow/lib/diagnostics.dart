import 'dart:async';
import 'dart:convert';
import 'dart:io';

class AppDiagnostics {
  AppDiagnostics({this.directory, this.persist = true});
  final bool persist;
  final Directory? directory;
  bool enabled = false;
  final lines = <String>[];
  final checks = <Map<String, dynamic>>[];
  Future<void> _writes = Future.value();
  int _bytes = 0;
  final _session = DateTime.now().millisecondsSinceEpoch;
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
          RegExp(r'Bearer\s+\S+', caseSensitive: false),
          'Bearer <已隐藏>',
        )
        .replaceAllMapped(
          RegExp(
            r'((?:token|password|secret|api[_-]?key)\s*[=:]\s*)[^\s,;]+',
            caseSensitive: false,
          ),
          (m) => '${m[1]}<已隐藏>',
        );
  }

  Object? scrub(Object? value) {
    if (value is String) return redact(value);
    if (value is List) return value.map(scrub).toList();
    if (value is Map)
      return value.map((k, v) => MapEntry(redact('$k'), scrub(v)));
    return value;
  }

  void record(String message, {bool detail = false}) {
    if (detail && !enabled) return;
    final line = '${DateTime.now().toIso8601String()} ${redact(message)}';
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
                          .startsWith('startup-')),
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
            'version': '4.6.0',
            'created': DateTime.now().toIso8601String(),
            'os': Platform.operatingSystemVersion,
            'diagnostic_mode': enabled,
            'checks': checks,
            'events': List<String>.of(lines),
            'logs': attachments,
          })
          as Map,
    );
  }
}
