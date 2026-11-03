import 'glass_theme.dart';
import 'package:flutter/material.dart';
import 'backend.dart';

class GameTextPanel extends StatefulWidget {
  const GameTextPanel({
    super.key,
    required this.backend,
    required this.onError,
  });
  final Backend backend;
  final void Function(Object) onError;
  @override
  State<GameTextPanel> createState() => _GameTextPanelState();
}

class _GameTextPanelState extends State<GameTextPanel> {
  Map<String, dynamic> fields = {};
  bool busy = false;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      final data = <String, dynamic>{};
      for (final field in ['name', 'code', 'desc']) {
        final result = await widget.backend.call('game_text', [field]);
        if (result is Map && result['available'] == true) data[field] = result;
      }
      if (mounted) setState(() => fields = data);
    } catch (e) {
      widget.onError(e);
    }
  }

  Future<void> edit(String field) async {
    final value = fields[field];
    final c = TextEditingController(
      text: '${value['value']}'.replaceAll('|', '\n'),
    );
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => GlassDialog(
        title: Text({'name': '游戏内名称', 'code': '型号', 'desc': '游戏内说明'}[field]!),
        content: SizedBox(
          width: 600,
          child: TextField(
            controller: c,
            autofocus: true,
            minLines: field == 'desc' ? 5 : 1,
            maxLines: field == 'desc' ? 10 : 1,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, ''),
            child: const Text('恢复原文'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, c.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    c.dispose();
    if (result == null) return;
    setState(() => busy = true);
    try {
      await widget.backend.call('game_text', [
        field,
        result.replaceAll('\r\n', '\n').replaceAll('\n', '|'),
      ]);
      await load();
    } catch (e) {
      widget.onError(e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => fields.isEmpty
      ? const SizedBox.shrink()
      : GlassPanel(
          child: ExpansionTile(
            // Do not share the parent scroll offset's PageStorage slot (double)
            // with ExpansionTile's persisted expansion state (bool).
            key: const PageStorageKey('game-text-expansion'),
            title: const Text('游戏内名称与说明'),
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    for (final field in fields.keys)
                      OutlinedButton.icon(
                        onPressed: busy ? null : () => edit(field),
                        icon: const Icon(Icons.edit_outlined, size: 18),
                        label: Text(
                          {
                            'name': '修改名称',
                            'code': '修改型号',
                            'desc': '修改说明',
                          }[field]!,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        );
}
