import '../lib/backend.dart';

Future<void> main(List<String> args) async {
  final backend = Backend(runtimeDirectory: args.single);
  backend.diagnostics.enabled = true;
  await backend.start();
  try {
    final items = await backend.call('items', ['Primary', '']) as List;
    await backend.call('select', [items.first['id']]);
    // Opening a page simultaneously loads fields and all text properties.
    final results = await Future.wait([
      for (var i = 0; i < 20; i++)
        backend.call(
          i % 2 == 0 ? 'rows' : 'game_text',
          i % 2 == 0 ? [] : ['code'],
        ),
    ]);
    if (results.length != 20 || (results.first as List).isEmpty) {
      throw StateError('Concurrent data load failed');
    }
    print('20 concurrent reads passed; no game writes');
    await backend.diagnose();
    final report = await backend.diagnostics.snapshot();
    if ((report['checks'] as List).isEmpty || (report['events'] as List).isEmpty) {
      throw StateError('Diagnostic report is empty');
    }
    print('Diagnostic checks and export snapshot passed');
  } finally {
    await backend.close();
  }
}
