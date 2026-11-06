import 'dart:convert';
import 'dart:io';
import 'package:file_selector/file_selector.dart';
import 'backend.dart';

Future<bool> exportDiagnostics(Backend backend) async {
  final location = await getSaveLocation(
    suggestedName: 'SHODAN-诊断-${DateTime.now().millisecondsSinceEpoch}.json',
    acceptedTypeGroups: [
      const XTypeGroup(label: '诊断日志', extensions: ['json']),
    ],
  );
  if (location == null) return false;
  final report = await backend.diagnostics.snapshot();
  if (backend.usesNativeDesktop) {
    await backend.nativeCall('diagnostic-export', {
      'path': location.path,
      'report': report,
    });
    return true;
  }
  await File(location.path).writeAsString(
    const JsonEncoder.withIndent('  ').convert(report),
    flush: true,
  );
  return true;
}
