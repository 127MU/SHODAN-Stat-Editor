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
  });
  final Backend backend;
  final void Function(Object) onError;
  final Widget Function(Widget) surface;
  @override
  State<ArmorPage> createState() => _ArmorPageState();
}

class _ArmorPageState extends State<ArmorPage> {
  List<dynamic> passives = [];
  Map profile = {};
  bool busy = false;
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
        builder: (ctx) => GlassDialog(
          title: Text('${passive['zh']} · 被动数值'),
          content: SizedBox(
            width: 660,
            height: 440,
            child: ListView(
              children: [
                for (final row in rows)
                  ArmorValue(
                    key: ValueKey(row['key']),
                    row: row,
                    save: (value) => widget.backend.call('armor_set', [
                      passive['id'],
                      row['key'],
                      value,
                    ]),
                    onError: widget.onError,
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('关闭'),
            ),
          ],
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
  Widget build(BuildContext context) => Column(
    children: [
      Wrap(
        spacing: 16,
        runSpacing: 12,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          DropdownMenu<int>(
            initialSelection: target,
            label: const Text('应用范围'),
            dropdownMenuEntries: [
              const DropdownMenuEntry(value: 999, label: '所有护甲'),
              for (final p in passives)
                DropdownMenuEntry(value: p['id'], label: p['zh']),
            ],
            onSelected: busy
                ? null
                : (id) async {
                    if (id != null) {
                      setState(() => target = id);
                      await refresh();
                    }
                  },
          ),
          FilterChip(
            label: const Text('保留原生被动'),
            selected: profile['own'] != false,
            onSelected: busy ? null : (v) => change(null, null, own: v),
          ),
          DropdownMenu<String>(
            initialSelection: profile['conflicts'] ?? 'stack',
            label: const Text('同类效果'),
            dropdownMenuEntries: const [
              DropdownMenuEntry(value: 'stack', label: '叠加'),
              DropdownMenuEntry(value: 'strongest', label: '保留最强'),
            ],
            onSelected: busy
                ? null
                : (value) {
                    if (value != null) change(null, null, policy: value);
                  },
          ),
        ],
      ),
      if (busy) const LinearProgressIndicator(),
      const SizedBox(height: 16),
      Expanded(
        child: LayoutBuilder(
          builder: (context, box) {
            const columns = 4;
            return GridView.builder(
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: columns,
                mainAxisExtent:
                    190 * MediaQuery.textScalerOf(context).scale(14) / 14,
                crossAxisSpacing: 12,
                mainAxisSpacing: 12,
              ),
              itemCount: passives.length,
              itemBuilder: (context, i) {
                final p = passives[i] as Map;
                return KeyedSubtree(
                  key: ValueKey('passive:${p['id']}'),
                  child: widget.surface(
                    Column(
                      children: [
                        CheckboxListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text(p['zh']),
                          value: checked(p['id']),
                          onChanged: busy ? null : (v) => change(p['id'], v),
                        ),
                        const Spacer(),
                        TextButton(
                          onPressed: busy ? null : () => values(p),
                          child: const Text('修改数值'),
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

class ArmorValue extends StatefulWidget {
  const ArmorValue({
    super.key,
    required this.row,
    required this.save,
    required this.onError,
  });
  final Map row;
  final Future<dynamic> Function(double) save;
  final void Function(Object) onError;
  @override
  State<ArmorValue> createState() => _ArmorValueState();
}

class _ArmorValueState extends State<ArmorValue> {
  late final c = TextEditingController(
    text: displayNumber(widget.row['value']),
  );
  final focus = FocusNode();
  late String saved = c.text;
  bool busy = false;
  bool queued = false;
  @override
  void initState() {
    super.initState();
    focus.addListener(() {
      if (!focus.hasFocus) commit();
    });
  }

  Future<void> commit() async {
    if (busy) {
      queued = true;
      return;
    }
    if (c.text == saved) return;
    busy = true;
    do {
      queued = false;
      final text = c.text;
      final value = double.tryParse(text);
      if (value == null || !value.isFinite) {
        widget.onError(StateError('请输入有效数值'));
        break;
      }
      try {
        await widget.save(value);
        saved = text;
      } catch (e) {
        widget.onError(e);
        break;
      }
    } while (mounted && queued && c.text != saved);
    if (mounted && c.text == saved) {
      c.text = displayNumber(saved);
      saved = c.text;
    }
    busy = false;
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${widget.row['label']} · 原值 ${displayNumber(widget.row['default'])}',
        ),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: c,
                focusNode: focus,
                onSubmitted: (_) => commit(),
              ),
            ),
            TextButton(
              onPressed: () async {
                c.text = '${widget.row['default']}';
                await commit();
              },
              child: const Text('恢复'),
            ),
          ],
        ),
      ],
    ),
  );
  @override
  void dispose() {
    focus.dispose();
    c.dispose();
    super.dispose();
  }
}
