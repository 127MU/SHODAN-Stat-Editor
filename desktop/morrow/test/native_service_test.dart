import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shodan_desktop/diagnostics.dart';
import 'package:shodan_desktop/native_service.dart';

class _Input implements StreamConsumer<List<int>> {
  _Input(this.onLine);
  final void Function(String) onLine;
  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await for (final line
        in stream.transform(utf8.decoder).transform(const LineSplitter())) {
      onLine(line);
    }
  }

  @override
  Future<void> close() async {}
}

class _Engine implements Process {
  _Engine(this.pid) {
    stdin = IOSink(
      _Input((line) {
        final request = jsonDecode(line) as Map;
        output.add(
          utf8.encode(
            '${jsonEncode({
              'id': request['id'],
              'ok': true,
              'result': {'lua': false},
            })}\n',
          ),
        );
      }),
    );
  }
  final output = StreamController<List<int>>();
  final errors = StreamController<List<int>>();
  final exited = Completer<int>();
  @override
  final int pid;
  @override
  late final IOSink stdin;
  @override
  Stream<List<int>> get stdout => output.stream;
  @override
  Stream<List<int>> get stderr => errors.stream;
  @override
  Future<int> get exitCode => exited.future;
  void finish(int code) {
    if (exited.isCompleted) return;
    exited.complete(code);
    unawaited(output.close());
    unawaited(errors.close());
  }

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    finish(-1);
    return true;
  }
}

void main() {
  test('原生服务退出后重新建立连接，关联记录异常与新请求', () async {
    final directory = Directory.systemTemp.createTempSync(
      'shodan-native-transport-',
    );
    File('${directory.path}/shodan-native.exe').writeAsBytesSync([0]);
    final log = AppDiagnostics(persist: false)..enabled = true;
    final engines = <_Engine>[];
    final service = NativeService(
      directory.path,
      log,
      processFactory: (_, _, _) async {
        final process = _Engine(100 + engines.length);
        engines.add(process);
        return process;
      },
    );
    try {
      expect(await service.call('info'), {'lua': false});
      engines.single.finish(17);
      await Future<void>.delayed(Duration.zero);
      expect(await service.call('info'), {'lua': false});
      expect(engines.length, 2);
      expect(
        log.structuredEvents.any(
          (event) =>
              event['operation'] == 'exit' && event['data']['exit_code'] == 17,
        ),
        isTrue,
      );
      expect(log.operations['info']!['calls'], 2);
    } finally {
      for (final process in engines) process.finish(0);
      await service.close();
      directory.deleteSync(recursive: true);
    }
  });
}
