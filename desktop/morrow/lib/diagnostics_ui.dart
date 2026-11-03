import 'dart:convert';
import 'dart:io';
import 'package:file_selector/file_selector.dart';
import 'diagnostics.dart';

Future<bool> exportDiagnostics(AppDiagnostics diagnostics) async {
  final location = await getSaveLocation(
    suggestedName: 'SHODAN-诊断-${DateTime.now().millisecondsSinceEpoch}.json',
    acceptedTypeGroups: [
      const XTypeGroup(label: '诊断日志', extensions: ['json']),
    ],
  );
  if (location == null) return false;
  await File(location.path).writeAsString(
    const JsonEncoder.withIndent('  ').convert(await diagnostics.snapshot()),
    flush: true,
  );
  return true;
}
