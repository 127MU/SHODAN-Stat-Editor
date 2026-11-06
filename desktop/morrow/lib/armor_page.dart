import 'glass_theme.dart';
import 'package:flutter/material.dart';
import 'number_display.dart';
import 'backend.dart';

class ArmorPage extends StatefulWidget {
  const ArmorPage({
    super.key,
    required this.backend,
    required this.onError,
    required this.surface,
    this.query = '',
  });
  final Backend backend;
  final String query;
  final void Function(Object) onError;
  final Widget Function(Widget) surface;
  @override
  State<ArmorPage> createState() => _ArmorPageState();
}

class _ArmorPageState extends State<ArmorPage> {
  List<dynamic> passives = [];
  Map profile = {};
  bool busy = true;
  bool onlySelected = false;
  int target = 999;
  @override
  void initState() {
    super.initState();
    init();
  }

  Future<void> init() async {
    try {
      final info = await widget.backend.call('info');
      final list = info['armor'];
      if (mounted) setState(() => passives = list is List ? list : []);
      await refresh();
    } catch (e) {
      widget.onError(e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> refresh() async {
    try {
      final data = await widget.backend.call('armor_profile', [target]);
      if (mounted) setState(() => profile = data is Map ? data : {});
    } catch (e) {
      widget.onError(e);
    }
  }

  Future<void> change(
    int? id,
    bool? enabled, {
    bool? own,
    String? policy,
  }) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      await widget.backend.call('armor_update', [
        target,
        id,
        enabled,
        own,
        policy,
      ]);
      await refresh();
    } catch (e) {
      widget.onError(e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> values(Map passive) async {
    try {
      final result = await widget.backend.call('armor_rows', [passive['id']]);
      if (!mounted) return;
      final rows = result is List ? result : [];
      await showDialog<void>(
        context: context,
        builder: (ctx) => _ArmorValuesDialog(
          name: passive['zh'],
          rows: rows.cast<Map>(),
          save: (key, value) =>
              widget.backend.call('armor_set', [passive['id'], key, value]),
        ),
      );
    } catch (e) {
      widget.onError(e);
    }
  }

  bool checked(dynamic id) {
    final enabled = profile['enabled'];
    return enabled is Map && enabled['$id'] == true;
  }

  @override
  Widget build(BuildContext context) {
    final selectedCount = passives.where((p) => checked(p['id'])).length;
    final q = widget.query.trim().toLowerCase();
    final visible = passives
        .where(
          (p) =>
              (!onlySelected || checked(p['id'])) &&
              (q.isEmpty || '${p['zh']} ${p['id']}'.toLowerCase().contains(q)),
        )
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        widget.surface(
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 16,
                runSpacing: 12,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  DropdownMenu<int>(
                    key: ValueKey('armor-target-$target'),
                    width: 220,
                    initialSelection: target,
                    label: const Text('应用到'),
                    dropdownMenuEntries: [
                      const DropdownMenuEntry(value: 999, label: '所有护甲'),
                      for (final p in passives)
                        DropdownMenuEntry(value: p['id'], label: p['zh']),
                    ],
                    onSelected: busy
                        ? null
                        : (id) async {
                            if (id == null || id == target) return;
                            setState(() {
                              target = id;
                              busy = true;
                            });
                            await refresh();
                            if (mounted) setState(() => busy = false);
                          },
                  ),
                  FilterChip(
                    label: const Text('保留原生被动'),
                    selected: profile['own'] != false,
                    onSelected: busy ? null : (v) => change(null, null, own: v),
                  ),
                  DropdownMenu<String>(
                    key: ValueKey('armor-policy-${profile['conflicts']}'),
                    width: 200,
                    initialSelection: profile['conflicts'] ?? 'stack',
                    label: const Text('同类效果处理'),
                    dropdownMenuEntries: const [
                      DropdownMenuEntry(value: 'stack', label: '叠加'),
                      DropdownMenuEntry(value: 'strongest', label: '保留最强'),
                    ],
                    onSelected: busy
                        ? null
                        : (v) {
                            if (v != null) change(null, null, policy: v);
                          },
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                '勾选要附加的被动；保留原生被动可同时保留护甲自带效果。修改数值后需写入游戏生效。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 16,
          runSpacing: 8,
          children: [
            Text(
              '已选择 $selectedCount / ${passives.length} 个被动 · 显示 ${visible.length} 项',
            ),
            FilterChip(
              label: const Text('仅看已选'),
              selected: onlySelected,
              onSelected: (v) => setState(() => onlySelected = v),
            ),
          ],
        ),
        SizedBox(
          height: 12,
          child: busy ? const LinearProgressIndicator() : null,
        ),
        Expanded(
          child: visible.isEmpty
              ? Center(
                  child: Text(onlySelected && q.isEmpty ? '尚未选择被动' : '没有匹配的被动'),
                )
              : LayoutBuilder(
                  builder: (context, box) {
                    final scale =
                        MediaQuery.textScalerOf(context).scale(14) / 14;
                    // Keep four columns on a normal desktop, reduce only when text
                    // would no longer fit at the user's chosen font size.
                    final columns = (box.maxWidth / (230 * scale))
                        .floor()
                        .clamp(1, 4);
                    return GridView.builder(
                      key: const PageStorageKey('armor-passive-grid'),
                      padding: const EdgeInsets.only(bottom: 12),
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: columns,
                        mainAxisExtent: 148 * scale,
                        crossAxisSpacing: 12,
                        mainAxisSpacing: 12,
                      ),
                      itemCount: visible.length,
                      findChildIndexCallback: (key) {
                        final i = visible.indexWhere(
                          (p) => key == ValueKey('passive:${p['id']}'),
                        );
                        return i < 0 ? null : i;
                      },
                      itemBuilder: (context, i) {
                        final p = visible[i] as Map;
                        final selected = checked(p['id']);
                        return AnimatedContainer(
                          key: ValueKey('passive:${p['id']}'),
                          duration: const Duration(milliseconds: 160),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(22),
                            border: Border.all(
                              color: selected
                                  ? Theme.of(context).colorScheme.primary
                                  : Colors.transparent,
                              width: 2,
                            ),
                          ),
                          child: widget.surface(
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                CheckboxListTile(
                                  contentPadding: EdgeInsets.zero,
                                  dense: true,
                                  visualDensity: VisualDensity.compact,
                                  title: Text(
                                    p['zh'],
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  value: selected,
                                  onChanged: busy
                                      ? null
                                      : (v) => change(p['id'], v),
                                ),
                                const Spacer(),
                                Row(
                                  children: [
                                    Text(
                                      selected ? '已加入组合' : '未选择',
                                      style: Theme.of(
                                        context,
                                      ).textTheme.bodySmall,
                                    ),
                                    const Spacer(),
                                    TextButton(
                                      onPressed: busy ? null : () => values(p),
                                      child: const Text('修改数值'),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _ArmorValuesDialog extends StatefulWidget {
  const _ArmorValuesDialog({
    required this.name,
    required this.rows,
    required this.save,
  });
  final String name;
  final List<Map> rows;
  final Future<dynamic> Function(String, double) save;
  @override
  State<_ArmorValuesDialog> createState() => _ArmorValuesDialogState();
}

class _ArmorValuesDialogState extends State<_ArmorValuesDialog> {
  late final saved = <String, String>{
    for (final row in widget.rows) row['key']: displayNumber(row['value']),
  };
  late final inputs = {
    for (final entry in saved.entries)
      entry.key: TextEditingController(text: entry.value),
  };
  Future<bool>? saving;
  bool closing = false;
  String? error;

  Future<bool> commit() =>
      saving ??= _savePending().whenComplete(() => saving = null);

  Future<bool> _savePending() async {
    while (mounted) {
      final pending = widget.rows.where((row) {
        final key = row['key'];
        return inputs[key]!.text != saved[key];
      }).firstOrNull;
      if (pending == null) {
        if (error != null) setState(() => error = null);
        return true;
      }
      final key = pending['key'] as String;
      final input = inputs[key]!;
      final text = input.text;
      try {
        final value = double.tryParse(text);
        if (value == null || !value.isFinite) {
          throw const FormatException('请输入有效数值');
        }
        await widget.save(key, value);
      } catch (e) {
        if (mounted) setState(() => error = '${pending['label']} · $e');
        return false;
      }
      if (!mounted) return false;
      saved[key] = text;
      if (input.text == text) {
        final formatted = displayNumber(text);
        if (formatted != text) input.text = formatted;
        saved[key] = formatted;
      }
    }
    return false;
  }

  Future<void> close() async {
    if (closing) return;
    setState(() => closing = true);
    final ok = await commit();
    if (!mounted) return;
    if (ok) {
      Navigator.pop(context);
    } else {
      setState(() => closing = false);
    }
  }

  Widget buildRow(Map row) {
    final input = inputs[row['key']]!;
    final original = row['default'];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${row['label']} · 原值 ${displayNumber(original)}'),
          Row(
            children: [
              Expanded(
                child: Focus(
                  canRequestFocus: false,
                  onFocusChange: (focused) {
                    if (!focused && mounted) commit();
                  },
                  child: TextField(
                    controller: input,
                    readOnly: closing,
                    onTapOutside: (_) => FocusScope.of(context).unfocus(),
                    onSubmitted: (_) => commit(),
                  ),
                ),
              ),
              TextButton(
                onPressed: closing || original == null
                    ? null
                    : () {
                        input.text = original.toString();
                        commit();
                      },
                child: const Text('恢复'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => PopScope<void>(
    canPop: false,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) close();
    },
    child: GlassDialog(
      title: Text('${widget.name} · 被动数值'),
      content: SizedBox(
        width: 660,
        height: 440,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (error case final message?)
              Text(
                message,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            Expanded(
              child: ListView(
                children: [for (final row in widget.rows) buildRow(row)],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: closing ? null : close,
          child: Text(closing ? '正在保存…' : '关闭'),
        ),
      ],
    ),
  );

  @override
  void dispose() {
    for (final input in inputs.values) {
      input.dispose();
    }
    super.dispose();
  }
}
