import 'dart:convert';
import 'dart:io';
import '../lib/native_service.dart';
import '../lib/diagnostics.dart';
import '../lib/app_version.dart';

Future<void> main(List<String> args) async {
  final root = await Directory.systemTemp.createTemp('shodan-native-ui-');
  NativeService? service;
  try {
    await File(
      '${args.single}/shodan-native.exe',
    ).copy('${root.path}/shodan-native.exe');
    service = NativeService(root.path, AppDiagnostics(persist: false));
    final replies = await Future.wait([
      service.call('info'),
      service.call('info'),
    ]);
    if (replies.any((r) => r['lua'] != false))
      throw StateError('Unexpected compatibility runtime');
    if (replies.any((r) => r['version'] != appVersion))
      throw StateError('Native and UI versions disagree');
    final offer = await service.call('update-parse', {
      'current': '4.6.0',
      'json': jsonEncode({
        'tag_name': 'v4.6.1',
        'html_url':
            'https://github.com/127MU/SHODAN-Stat-Editor/releases/tag/v4.6.1',
        'body': '中文更新日志',
        'assets': [],
      }),
    });
    if (offer['notes'] != '中文更新日志' || offer['newer'] != true)
      throw StateError('Native release response mismatch');
    await service.close();
    print(
      'Flutter transport: concurrent startup, native replies, Chinese notes and close passed; no Lua files present',
    );
  } finally {
    await service?.close();
    await root.delete(recursive: true);
  }
}
