import 'package:flutter/material.dart';
import 'backend.dart';
import 'glass_theme.dart';
import 'number_display.dart';

class BaselineCleanupDialog extends StatefulWidget {
  const BaselineCleanupDialog({super.key, required this.backend});
  final Backend backend;
  @override
  State<BaselineCleanupDialog> createState() => _BaselineCleanupDialogState();
}

class _BaselineCleanupDialogState extends State<BaselineCleanupDialog> {
  Map? preview;
  String? error;
  bool busy = true;
  final selected = <String>{};

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      final result = await widget.backend.call('baseline_cleanup_preview', [
        '',
      ]);
      if (result is! Map || result['entries'] is! List) {
        throw StateError('已有差异预览格式错误');
      }
      if (!mounted) return;
      setState(() {
        preview = result;
        error = null;
        selected.clear();
        // Offer the known bulk sway issue separately, rather than silently
        // selecting every untracked modification on the user's installation.
        selected.addAll(
          (result['entries'] as List)
              .where((e) => e['key'] == 'sway')
              .map((e) => e['id'] as String),
        );
      });
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> apply() async {
    if (busy || selected.isEmpty || preview == null) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.backend.call('baseline_cleanup_apply', [
        '',
        preview!['token'],
        selected.toList(),
      ]);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final entries = preview?['entries'] is List
        ? preview!['entries'] as List
        : const [];
    return PopScope(
      canPop: !busy,
      child: GlassDialog(
        title: const Text('整理已有差异'),
        content: SizedBox(
          width: 920,
          height: MediaQuery.sizeOf(context).height * .65,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                '这些数值在打开编辑器之前就与可信原版不同，不代表本次逐项修改。勾选要恢复的参数；已记录的修改、预设及外观设置会保留。',
              ),
              const SizedBox(height: 8),
              const Text('恢复会暂存为一次可撤销的修改。确认后仍需点击“写入游戏”；共享参数可能同时影响多件装备。'),
              if (preview != null) ...[
                const SizedBox(height: 8),
                Text(
                  '${entries.length} 项可恢复 · 保留 ${preview!['preserved']} 项已记录修改 · 跳过 ${preview!['skipped']} 项无可信原值或需专用恢复的参数',
                ),
                Wrap(
                  spacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    TextButton(
                      onPressed: busy
                          ? null
                          : () => setState(() {
                              selected
                                ..clear()
                                ..addAll(
                                  entries
                                      .where((e) => e['key'] == 'sway')
                                      .map((e) => e['id'] as String),
                                );
                            }),
                      child: const Text('只选武器晃动'),
                    ),
                    TextButton(
                      onPressed: busy
                          ? null
                          : () => setState(
                              () => selected.addAll(
                                entries.map((e) => e['id'] as String),
                              ),
                            ),
                      child: const Text('全选'),
                    ),
                    TextButton(
                      onPressed: busy ? null : () => setState(selected.clear),
                      child: const Text('清空'),
                    ),
                    Text('已选 ${selected.length} 项'),
                  ],
                ),
              ],
              if (error != null)
                SelectableText(
                  error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              if (busy) const LinearProgressIndicator(),
              Expanded(
                child: entries.isEmpty
                    ? Center(child: Text(busy ? '正在核对可信原值…' : '没有可安全恢复的已有数值差异'))
                    : ListView.builder(
                        itemCount: entries.length,
                        itemBuilder: (context, index) {
                          final entry = entries[index] as Map;
                          final id = entry['id'] as String;
                          return CheckboxListTile(
                            value: selected.contains(id),
                            onChanged: busy
                                ? null
                                : (value) => setState(() {
                                    value == true
                                        ? selected.add(id)
                                        : selected.remove(id);
                                  }),
                            title: Text(
                              '${entry['owner']} · ${entry['parameter']}',
                            ),
                            subtitle: Text(
                              '${displayNumber(entry['before'])} → ${displayNumber(entry['after'])}'
                              '${(entry['shared'] as num? ?? 0) > 1 ? ' · 共享影响 ${entry['shared']} 项' : ''}\n${entry['file']}',
                            ),
                            controlAffinity: ListTileControlAffinity.leading,
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: busy ? null : () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          if (error != null)
            TextButton(
              onPressed: busy ? null : load,
              child: const Text('重新检查'),
            ),
          FilledButton(
            onPressed: busy || selected.isEmpty ? null : apply,
            child: const Text('暂存所选恢复'),
          ),
        ],
      ),
    );
  }
}
