import 'motion.dart';
import 'glass_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'backend.dart';
import 'review_body.dart';

class PresetPage extends StatefulWidget {
  const PresetPage({super.key, required this.backend, required this.onError});
  final Backend backend;
  final void Function(Object) onError;
  @override
  State<PresetPage> createState() => _PresetPageState();
}

class _PresetPageState extends State<PresetPage> {
  List<dynamic> presets = [];
  bool busy = false;
  bool enemy = false;
  String result = '';
  @override
  void initState() {
    super.initState();
    changeScope(false);
  }

  Future<void> changeScope(bool value) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      await widget.backend.call('editor_mode', [value]);
      if (mounted) setState(() => enemy = value);
      await refresh();
    } catch (e) {
      widget.onError(e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> refresh() async {
    try {
      final data = await widget.backend.call('full_presets');
      if (mounted) setState(() => presets = data is List ? data : []);
    } catch (e) {
      widget.onError(e);
    }
  }

  Future<String?> input(String title, [String initial = '']) async {
    final c = TextEditingController(text: initial);
    final route = MotionDialogRoute<String>(
      context: context,
      builder: (ctx) => GlassDialog(
        title: Text(title),
        content: SizedBox(
          width: 550,
          child: TextField(
            controller: c,
            autofocus: true,
            minLines: 1,
            maxLines: 8,
            onSubmitted: (v) => Navigator.pop(ctx, v),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, c.text),
            child: const Text('确认'),
          ),
        ],
      ),
    );
    try {
      return await Navigator.of(context, rootNavigator: true).push(route);
    } finally {
      await route.completed;
      c.dispose();
    }
  }

  Future<void> action(String method, List<dynamic> args) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      final data = await widget.backend.call(method, args);
      if (mounted) setState(() => result = '$data');
      await refresh();
    } catch (e) {
      widget.onError(e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> load(Map p) async {
    try {
      final review = await widget.backend.call('preset_compare', [
        'full',
        p['id'],
      ]);
      if (!mounted) return;
      final yes = await showMotionDialog<bool>(
        context: context,
        builder: (ctx) => GlassDialog(
          title: Text('读取 ${p['name']}'),
          content: SizedBox(
            width: 600,
            height: 360,
            child: ReviewBody(data: review),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('确认读取'),
            ),
          ],
        ),
      );
      if (yes == true) await action('full_preset', ['load', p['id']]);
    } catch (e) {
      widget.onError(e);
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Wrap(
        spacing: 12,
        runSpacing: 12,
        children: [
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: false, label: Text('装备预设')),
              ButtonSegment(value: true, label: Text('敌人预设')),
            ],
            selected: {enemy},
            onSelectionChanged: busy
                ? null
                : (value) => changeScope(value.single),
          ),
          if (enemy)
            OutlinedButton(
              onPressed: busy ? null : () => action('restore_examples', []),
              child: const Text('恢复内置示例'),
            ),
          FilledButton.icon(
            onPressed: busy
                ? null
                : () async {
                    final name = await input('新预设名称');
                    if (name != null && name.trim().isNotEmpty)
                      await action('full_preset', ['new', null, name]);
                  },
            icon: const Icon(Icons.add),
            label: const Text('保存当前修改为预设'),
          ),
          OutlinedButton.icon(
            onPressed: busy
                ? null
                : () async {
                    final text = await input('粘贴分享码或导出的预设');
                    if (text != null && text.trim().isNotEmpty) {
                      if (text.contains('SSEO-')) {
                        await action('preset_code_import', [text]);
                      } else {
                        await action('preset_import', ['full', null, text]);
                      }
                    }
                  },
            icon: const Icon(Icons.input),
            label: const Text('导入预设'),
          ),
        ],
      ),
      if (busy) const LinearProgressIndicator(),
      const SizedBox(height: 16),
      Expanded(
        child: CatalogEntrance(
          key: ValueKey((enemy, presets.isNotEmpty)),
          builder: (context, entrance) => ListView.separated(
            itemCount: presets.length,
            separatorBuilder: (_, i) => const SizedBox(height: 12),
            itemBuilder: (context, i) {
              final p = presets[i] as Map;
              return CatalogEntrance.card(
                entrance,
                i,
                GlassPanel(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          p['name'],
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        Text('${p['count']} 项参数'),
                        if (p['description'] is String)
                          Text(p['description'] as String),
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 8,
                          children: [
                            FilledButton.tonal(
                              onPressed: busy ? null : () => load(p),
                              child: const Text('读取'),
                            ),
                            TextButton(
                              onPressed: busy
                                  ? null
                                  : () => action('full_preset', [
                                      'save',
                                      p['id'],
                                    ]),
                              child: const Text('覆盖保存'),
                            ),
                            TextButton(
                              onPressed: busy
                                  ? null
                                  : () async {
                                      final name = await input(
                                        '修改预设名称',
                                        p['name'],
                                      );
                                      if (name != null &&
                                          name.trim().isNotEmpty)
                                        await action('preset_rename', [
                                          'full',
                                          p['id'],
                                          name,
                                        ]);
                                    },
                              child: const Text('重命名'),
                            ),
                            TextButton(
                              onPressed: busy
                                  ? null
                                  : () async {
                                      final text = await input(
                                        '预设说明',
                                        p['description'] as String? ?? '',
                                      );
                                      if (text != null)
                                        await action('preset_description', [
                                          'full',
                                          p['id'],
                                          text,
                                        ]);
                                    },
                              child: const Text('编辑说明'),
                            ),
                            TextButton(
                              onPressed: busy
                                  ? null
                                  : () async {
                                      final text = await input(
                                        '副本名称',
                                        '${p['name']} 副本',
                                      );
                                      if (text != null &&
                                          text.trim().isNotEmpty) {
                                        await action('preset_duplicate', [
                                          'full',
                                          p['id'],
                                          text,
                                        ]);
                                      }
                                    },
                              child: const Text('创建副本'),
                            ),
                            TextButton(
                              onPressed: busy
                                  ? null
                                  : () async {
                                      try {
                                        final code = await widget.backend.call(
                                          'preset_code',
                                          [p['id']],
                                        );
                                        await Clipboard.setData(
                                          ClipboardData(text: code as String),
                                        );
                                        if (mounted)
                                          setState(() => result = '分享码已复制');
                                      } catch (e) {
                                        widget.onError(e);
                                      }
                                    },
                              child: const Text('复制分享码'),
                            ),
                            TextButton(
                              onPressed: busy
                                  ? null
                                  : () async {
                                      try {
                                        final text = await widget.backend.call(
                                          'preset_export',
                                          ['full', p['id']],
                                        );
                                        await Clipboard.setData(
                                          ClipboardData(text: text as String),
                                        );
                                        if (mounted)
                                          setState(
                                            () => result = '预设已复制，可发给他人导入',
                                          );
                                      } catch (e) {
                                        widget.onError(e);
                                      }
                                    },
                              child: const Text('复制导出'),
                            ),
                            TextButton(
                              onPressed: busy
                                  ? null
                                  : () async {
                                      final yes = await showMotionDialog<bool>(
                                        context: context,
                                        builder: (ctx) => GlassDialog(
                                          title: Text('删除 ${p['name']}？'),
                                          actions: [
                                            TextButton(
                                              onPressed: () =>
                                                  Navigator.pop(ctx, false),
                                              child: const Text('取消'),
                                            ),
                                            FilledButton(
                                              onPressed: () =>
                                                  Navigator.pop(ctx, true),
                                              child: const Text('删除'),
                                            ),
                                          ],
                                        ),
                                      );
                                      if (yes == true)
                                        await action('full_preset', [
                                          'delete',
                                          p['id'],
                                        ]);
                                    },
                              child: const Text('删除'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
      Text(result),
    ],
  );
}
