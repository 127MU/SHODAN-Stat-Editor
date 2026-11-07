import 'dart:async';
import 'package:flutter/material.dart';
import 'backend.dart';
import 'glass_theme.dart';
import 'motion.dart';
import 'diagnostics_ui.dart';

class InstallDialog extends StatefulWidget {
  const InstallDialog({
    super.key,
    required this.backend,
    this.preview = false,
    this.restore = false,
    this.repair = false,
    this.allowFloatAdjustment = false,
  });
  final Backend backend;
  final bool preview;
  final bool restore;
  final bool repair;
  final bool allowFloatAdjustment;
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
    stage = widget.repair
        ? '正在检查并修复'
        : widget.preview
        ? '正在检查修改并生成写入预览'
        : widget.restore
        ? '正在恢复游戏文件'
        : stage;
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

  Future<void> run({bool force = false}) async {
    widget.backend.diagnostics.record(
      widget.repair
          ? '开始自动修复流程'
          : widget.preview
          ? '开始安装预览'
          : '开始写入游戏',
    );
    try {
      result = widget.repair
          ? await widget.backend.repair()
          : await widget.backend.call(
              widget.preview
                  ? 'install_preview'
                  : widget.restore
                  ? 'restore_task'
                  : 'install_task',
              [widget.allowFloatAdjustment, force],
            );
      if (!mounted) return;
      success = widget.preview || result is Map && result['ok'] == true;
      if (widget.preview) {
        Navigator.pop(context, result);
        return;
      }
      message = result is Map ? '${result['message'] ?? ''}' : '$result';
      if (widget.repair && result is Map) {
        message = [
          message,
          for (final entry in result['actions'] as List? ?? []) '• $entry',
          for (final entry in result['warnings'] as List? ?? []) '提示：$entry',
          if ((result['problems'] as List? ?? []).isNotEmpty) '仍需处理：',
          for (final entry in result['problems'] as List? ?? []) '• $entry',
          for (final action in {
            for (final issue in result['issues'] as List? ?? [])
              if (issue is Map && issue['action'] is String)
                issue['action'] as String,
          })
            '处理建议：$action',
        ].join('\n\n');
      }
      if (!widget.repair &&
          result is Map &&
          (result['warnings'] as List? ?? []).isNotEmpty) {
        message = [
          message,
          for (final entry in result['warnings'] as List) '提示：$entry',
        ].join('\n\n');
      }
      message = message.replaceFirst(
        RegExp(
          r'Installed \((\d+) game files changed\)\. Start the game to play with your values\.',
        ),
        '已写入游戏文件，启动游戏后生效。',
      );
      if (!success && !widget.repair) await explainFailure(message);
      widget.backend.diagnostics.record(
        '${widget.repair
            ? '自动修复结束'
            : success
            ? '安装完成'
            : '安装失败'}：$message',
      );
    } catch (e) {
      message = '$e';
      success = false;
      widget.backend.diagnostics.record(
        '${widget.repair ? '自动修复' : '安装'}异常：$e',
      );
      await explainFailure('$e');
    }
    if (mounted)
      setState(() {
        finished = true;
        stage = widget.repair
            ? (success ? '自动修复完成' : '自动修复仍需处理')
            : widget.restore
            ? (success ? '恢复完成' : '恢复未完成')
            : (success ? '安装完成' : '安装未完成');
      });
  }

  Future<void> explainFailure(String reason) async {
    try {
      final advice = await widget.backend
          .nativeCall('diagnostic-install-error', {'error': reason})
          .timeout(const Duration(seconds: 3));
      if (advice is Map && advice['action'] is String) {
        message += '\n\n处理建议：${advice['action']}';
        widget.backend.diagnostics.workspace['last_install_failure'] = widget
            .backend
            .diagnostics
            .scrub({'error': reason, ...advice});
      }
    } catch (_) {
      // Keep the original failure visible if the engine itself is unavailable.
    }
  }

  Future<void> forceWrite() async {
    final restore = widget.restore;
    final accepted = await showMotionDialog<bool>(
      context: context,
      builder: (ctx) => GlassDialog(
        title: Text(restore ? '确认强制恢复' : '确认强制写入'),
        content: Text(
          restore
              ? '当前游戏文件与安装记录不一致，可能已被其他工具修改。将用备份内容覆盖，并把当前文件先另存备份；原始备份本身若已变化仍会拒绝恢复。游戏版本、磁盘快照和资源补丁校验仍须通过。'
              : '按当前打开的数据写入，并接管冲突的旧数值安装记录。当前文件会先备份；之后“恢复原版”将恢复到本次写入前的文件，可能仍含其他 Mod 的修改。游戏版本、磁盘快照和资源补丁校验仍须通过。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(restore ? '备份并强制恢复' : '备份并强制写入'),
          ),
        ],
      ),
    );
    if (accepted != true || !mounted) return;
    setState(() {
      finished = false;
      success = false;
      result = null;
      message = '';
      stage = restore ? '正在备份并强制恢复' : '正在备份并强制写入';
      done = 0;
      total = 0;
      events.clear();
    });
    await run(force: true);
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: finished,
    child: GlassDialog(
      title: Text(
        widget.repair
            ? '自动修复'
            : widget.preview
            ? '写入前检查'
            : widget.restore
            ? '恢复原版'
            : '安装到游戏',
      ),
      content: SizedBox(
        width: 640,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: AnimatedSwitcher(
                duration: WorkbenchMotion.duration(
                  context,
                  WorkbenchMotion.settle,
                ),
                switchInCurve: WorkbenchMotion.enter,
                switchOutCurve: WorkbenchMotion.exit,
                transitionBuilder: (child, animation) => FadeTransition(
                  opacity: animation,
                  child: ScaleTransition(
                    scale: animation.drive(Tween(begin: .90, end: 1.0)),
                    child: child,
                  ),
                ),
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
                    : MediaQuery.disableAnimationsOf(context)
                    ? const Icon(
                        Icons.hourglass_empty,
                        key: ValueKey('busy'),
                        size: 48,
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
              duration: WorkbenchMotion.duration(
                context,
                WorkbenchMotion.feedback,
              ),
              switchInCurve: WorkbenchMotion.enter,
              switchOutCurve: WorkbenchMotion.exit,
              transitionBuilder: (child, animation) => FadeTransition(
                opacity: animation,
                child: SlideTransition(
                  position: animation.drive(
                    Tween(begin: const Offset(0, .14), end: Offset.zero),
                  ),
                  child: child,
                ),
              ),
              child: Text(stage, key: ValueKey(stage)),
            ),
            const SizedBox(height: 16),
            if (!finished &&
                (total > 0 || !MediaQuery.disableAnimationsOf(context)))
              TweenAnimationBuilder<double>(
                duration: WorkbenchMotion.duration(
                  context,
                  WorkbenchMotion.settle,
                ),
                curve: WorkbenchMotion.standard,
                tween: Tween(
                  end: total > 0 ? (done / total).clamp(0, 1).toDouble() : 0,
                ),
                builder: (_, value, _) =>
                    LinearProgressIndicator(value: total > 0 ? value : null),
              ),
            if (!finished && total > 0) Text('当前阶段：$done / $total'),
            if (message.isNotEmpty)
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.sizeOf(context).height * .35,
                ),
                child: SingleChildScrollView(child: SelectableText(message)),
              ),
            TextButton(
              onPressed: () => setState(() => details = !details),
              child: Text(details ? '收起阶段日志' : '显示阶段日志'),
            ),
            if (details)
              SizedBox(
                height: 140,
                child: SingleChildScrollView(
                  child: SelectableText(
                    events.isEmpty
                        ? (finished ? '没有额外阶段信息。' : '正在等待阶段信息…')
                        : events.join('\n'),
                  ),
                ),
              ),
          ],
        ),
      ),
      actions: [
        if (finished &&
            !success &&
            !widget.preview &&
            !widget.repair &&
            (widget.restore
                ? message.contains('的文件已变化')
                : message.contains('已被其他工具修改，已停止写入')))
          OutlinedButton.icon(
            onPressed: forceWrite,
            icon: const Icon(Icons.warning_amber_outlined),
            label: Text(widget.restore ? '强制恢复' : '强制写入'),
          ),
        if (finished)
          TextButton(
            onPressed: () async {
              try {
                await exportDiagnostics(widget.backend);
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
