import 'glass_theme.dart';
import 'package:flutter/material.dart';
import 'backend.dart';

class ArmorItem extends StatefulWidget {
  const ArmorItem({
    super.key,
    required this.backend,
    required this.hash,
    required this.onError,
  });
  final Backend backend;
  final String hash;
  final void Function(Object) onError;
  @override
  State<ArmorItem> createState() => _ArmorItemState();
}

class _ArmorItemState extends State<ArmorItem> {
  Map data = {};
  bool busy = false;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load([List<int>? selected]) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      final result = await widget.backend.call('armor_item', [
        widget.hash,
        if (selected != null) selected,
      ]);
      if (mounted) setState(() => data = result as Map);
    } catch (e) {
      widget.onError(e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (data['available'] != true) return const SizedBox.shrink();
    final selected = data['selected'] is List
        ? List<int>.from(data['selected'])
        : <int>[];
    return GlassPanel(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '这件护甲的被动 · ${selected.length}/14',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const Text('只影响当前护甲；取消全部勾选可移除全部被动。'),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final choice in data['choices'] ?? [])
                  FilterChip(
                    label: Text(choice['name']),
                    selected: selected.contains(choice['id']),
                    onSelected: busy
                        ? null
                        : (on) {
                            final next = [...selected];
                            if (on) {
                              if (next.length >= 14) {
                                widget.onError(StateError('最多选择 14 个被动'));
                                return;
                              }
                              next.add(choice['id']);
                            } else {
                              next.remove(choice['id']);
                            }
                            load(next);
                          },
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
