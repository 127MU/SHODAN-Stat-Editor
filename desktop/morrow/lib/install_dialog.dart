import 'dart:async';
import 'package:flutter/material.dart';
import 'backend.dart';
import 'glass_theme.dart';
import 'diagnostics_ui.dart';

class InstallDialog extends StatefulWidget {
  const InstallDialog({super.key, required this.backend, this.preview = false});
  final Backend backend;
  final bool preview;
  @override
  State<InstallDialog> createState() => _InstallDialogState();
}

class _InstallDialogState extends State<InstallDialog> {
  StreamSubscription? subscription;
  String stage = '正在准备安装', message = '';
  num done = 0, total = 0;
  bool finished = false, success = false, details = false;
  dynamic result;
  final events = <String>[];
  @override
  void initState() {
    super.initState();
    stage = widget.preview ? '正在检查修改并生成写入预览' : stage;
    subscription = widget.backend.progress.stream.listen((event) {
      if (!mounted || finished) return;
      setState(() {
        stage = '${event['stage'] ?? '正在处理'}';
        done = event['done'] is num ? event['done'] : 0;
        total = event['total'] is num ? event['total'] : 0;
        events.add('$stage${total > 0 ? ' · $done/$total' : ''}');
        if (events.length > 40) events.removeAt(0);
      });
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => run());
  }

  Future<void> run() async {
    widget.backend.diagnostics.record(widget.preview ? '开始安装预览' : '开始写入游戏');
    try {
      result = await widget.backend.call(
        widget.preview ? 'install_preview' : 'install_task',
      );
      if (!mounted) return;
      success = widget.preview || result is Map && result['ok'] == true;
      if (widget.preview) {
        Navigator.pop(context, result);
        return;
      }
      message = result is Map ? '${result['message'] ?? ''}' : '$result';
      message = message.replaceFirst(
        RegExp(
          r'Installed \((\d+) game files changed\)\. Start the game to play with your values\.',
        ),
        '已写入游戏文件，启动游戏后生效。',
      );
      widget.backend.diagnostics.record(
        '${success ? '安装完成' : '安装失败'}：$message',
      );
    } catch (e) {
      message = '$e';
      success = false;
      widget.backend.diagnostics.record('安装异常：$e');
    }
    if (mounted)
      setState(() {
        finished = true;
        stage = success ? '安装完成' : '安装未完成';
      });
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: finished,
    child: GlassDialog(
      title: Text(widget.preview ? '写入前检查' : '安装到游戏'),
      content: SizedBox(
        width: 640,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 260),
                child: finished
                    ? Icon(
                        success
                            ? Icons.check_circle_outline
                            : Icons.error_outline,
                        key: ValueKey(success),
                        size: 56,
                        color: success
                            ? Colors.green
                            : Theme.of(context).colorScheme.error,
                      )
                    : const SizedBox(
                        key: ValueKey('busy'),
                        width: 48,
                        height: 48,
                        child: CircularProgressIndicator(),
                      ),
              ),
            ),
            const SizedBox(height: 20),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 180),
              child: Text(stage, key: ValueKey(stage)),
            ),
            const SizedBox(height: 16),
            if (!finished)
              TweenAnimationBuilder<double>(
                duration: const Duration(milliseconds: 250),
                tween: Tween(
                  end: total > 0 ? (done / total).clamp(0, 1).toDouble() : 0,
                ),
                builder: (_, value, _) =>
                    LinearProgressIndicator(value: total > 0 ? value : null),
              ),
            if (!finished && total > 0) Text('当前阶段：$done / $total'),
            if (message.isNotEmpty) SelectableText(message),
            TextButton(
              onPressed: () => setState(() => details = !details),
              child: Text(details ? '收起阶段日志' : '显示阶段日志'),
            ),
            if (details)
              SizedBox(
                height: 140,
                child: SingleChildScrollView(
                  child: SelectableText(
                    events.isEmpty ? '正在等待阶段信息…' : events.join('\n'),
                  ),
                ),
              ),
          ],
        ),
      ),
      actions: [
        if (finished)
          TextButton(
            onPressed: () async {
              try {
                await exportDiagnostics(widget.backend.diagnostics);
              } catch (e) {
                if (mounted) setState(() => message = '日志导出失败：$e');
              }
            },
            child: const Text('导出日志'),
          ),
        if (finished)
          FilledButton(
            onPressed: () => Navigator.pop(context, result),
            child: const Text('关闭'),
          ),
      ],
    ),
  );
  @override
  void dispose() {
    subscription?.cancel();
    super.dispose();
  }
}
