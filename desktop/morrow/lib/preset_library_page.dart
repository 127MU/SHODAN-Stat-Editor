import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_selector/file_selector.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'backend.dart';
import 'glass_theme.dart';
import 'motion.dart';
import 'preset_page.dart';
import 'review_body.dart';

Future<Map?> importSharedPreset(
  BuildContext context,
  Backend backend,
  String text, {
  VoidCallback? onRecognized,
}) async {
  final preview = await backend.call('library_preview', [text]) as Map;
  onRecognized?.call();
  if (!context.mounted) return null;
  bool saving = false;
  String? error;
  return showMotionDialog<Map>(
    context: context,
    builder: (dialog) => StatefulBuilder(
      builder: (dialog, update) => PopScope(
        canPop: !saving,
        child: GlassDialog(
          title: const Text('导入预设'),
          content: SizedBox(
            width: 680,
            height: 420,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text('按稳定条目标识自动匹配；保留作者的自定义名称。确认后保存到预设库，读取后再写入游戏。'),
                if (saving) const LinearProgressIndicator(),
                if (error != null)
                  Text(
                    error!,
                    style: TextStyle(color: Theme.of(dialog).colorScheme.error),
                  ),
                const SizedBox(height: 12),
                Expanded(
                  child: ListView(
                    children: [
                      for (final group in preview['groups'] as List? ?? [])
                        ListTile(
                          leading: const Icon(Icons.inventory_2_outlined),
                          title: Text('${group['name']}'),
                          subtitle: Text(
                            '${(group['targets'] as List? ?? []).join('、')} · ${group['count']} 项参数',
                          ),
                        ),
                      for (final warning in preview['warnings'] as List? ?? [])
                        Text('提示：$warning'),
                    ],
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: saving ? null : () => Navigator.pop(dialog),
              child: const Text('取消'),
            ),
            FilledButton.icon(
              onPressed: saving
                  ? null
                  : () async {
                      update(() {
                        saving = true;
                        error = null;
                      });
                      try {
                        final result =
                            await backend.call('library_import', [text]) as Map;
                        if (dialog.mounted) Navigator.pop(dialog, result);
                      } catch (e) {
                        if (dialog.mounted)
                          update(() {
                            saving = false;
                            error = '$e';
                          });
                      }
                    },
              icon: const Icon(Icons.file_download_outlined),
              label: Text(saving ? '正在导入…' : '确认导入'),
            ),
          ],
        ),
      ),
    ),
  );
}

class PresetDropZone extends StatefulWidget {
  const PresetDropZone({
    super.key,
    required this.child,
    required this.backend,
    required this.dialogContext,
    required this.onImported,
    required this.onError,
  });
  final Widget child;
  final Backend backend;
  final BuildContext Function() dialogContext;
  final void Function(Map result) onImported;
  final void Function(Object) onError;
  @override
  State<PresetDropZone> createState() => _PresetDropZoneState();
}

class _PresetDropZoneState extends State<PresetDropZone> {
  bool hovering = false, reading = false, active = false;
  Future<void> receive(List<String> paths) async {
    if (active) return;
    active = true;
    setState(() {
      hovering = false;
      reading = true;
    });
    try {
      if (paths.isEmpty || paths.length > 50)
        throw const FormatException('一次请拖入 1–50 个预设文件');
      final texts = <String>[];
      int bytes = 0;
      for (final path in paths) {
        if (!RegExp(r'\.(txt|json)$', caseSensitive: false).hasMatch(path))
          throw const FormatException('仅支持 TXT 或 JSON 预设文件');
        final file = File(path);
        bytes += await file.length();
        if (bytes > 8 * 1024 * 1024)
          throw const FormatException('预设文件合计超过 8 MB');
        texts.add(await file.readAsString());
      }
      final text = texts.length == 1
          ? texts.single
          : await widget.backend.call('library_join', [texts]) as String;
      if (!mounted) return;
      final result = await importSharedPreset(
        widget.dialogContext(),
        widget.backend,
        text,
        onRecognized: () {
          if (mounted) setState(() => reading = false);
        },
      );
      if (mounted && result != null) widget.onImported(result);
    } catch (e) {
      if (mounted) widget.onError(e);
    } finally {
      active = false;
      if (mounted) setState(() => reading = false);
    }
  }

  @override
  Widget build(BuildContext context) => DropTarget(
    enable: !active,
    onDragEntered: (_) {
      if (!reading) setState(() => hovering = true);
    },
    onDragExited: (_) {
      if (mounted) setState(() => hovering = false);
    },
    onDragDone: (details) => receive(details.files.map((f) => f.path).toList()),
    child: Stack(
      fit: StackFit.expand,
      children: [
        widget.child,
        IgnorePointer(
          child: AnimatedSwitcher(
            duration: WorkbenchMotion.duration(
              context,
              const Duration(milliseconds: 220),
            ),
            transitionBuilder: (child, animation) => FadeTransition(
              opacity: animation,
              child: ScaleTransition(
                scale: animation.drive(Tween(begin: .97, end: 1.0)),
                child: child,
              ),
            ),
            child: !hovering && !reading
                ? const SizedBox.shrink()
                : Container(
                    key: ValueKey(reading),
                    margin: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: Theme.of(
                        context,
                      ).colorScheme.surface.withValues(alpha: .94),
                      borderRadius: BorderRadius.circular(28),
                      border: Border.all(
                        color: Theme.of(context).colorScheme.primary,
                        width: 2,
                      ),
                    ),
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (reading)
                            const SizedBox(
                              width: 48,
                              height: 48,
                              child: CircularProgressIndicator(),
                            )
                          else
                            Icon(
                              Icons.file_download_outlined,
                              size: 64,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                          const SizedBox(height: 20),
                          Text(
                            reading ? '正在识别并准备导入…' : '松开以导入预设',
                            style: Theme.of(context).textTheme.headlineSmall,
                          ),
                          const SizedBox(height: 10),
                          const Text('支持 TXT / JSON，可同时拖入多个文件'),
                        ],
                      ),
                    ),
                  ),
          ),
        ),
      ],
    ),
  );
}

class PresetLibraryPage extends StatefulWidget {
  const PresetLibraryPage({
    super.key,
    required this.backend,
    required this.onError,
    this.initialSelection,
  });
  final Backend backend;
  final void Function(Object) onError;
  final String? initialSelection;
  @override
  State<PresetLibraryPage> createState() => _PresetLibraryPageState();
}

class _PresetLibraryPageState extends State<PresetLibraryPage> {
  List<Map> items = [];
  String? selected;
  bool busy = false;
  Map? preview;
  String message = '';
  @override
  void initState() {
    super.initState();
    selected = widget.initialSelection;
    refresh();
  }

  Future<void> refresh() async {
    try {
      final data = await widget.backend.call('library_list');
      if (!mounted) return;
      setState(() {
        items = [for (final item in data as List? ?? []) Map.from(item)];
        if (!items.any((i) => i['id'] == selected))
          selected = items.firstOrNull?['id'];
      });
      if (selected != null) await select(selected!);
    } catch (e) {
      widget.onError(e);
    }
  }

  Future<void> select(String id) async {
    setState(() {
      selected = id;
      busy = true;
      preview = null;
    });
    try {
      final data = await widget.backend.call('library_preview', [id]);
      if (mounted && selected == id) setState(() => preview = data as Map);
    } catch (e) {
      widget.onError(e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<String?> input(
    String title, {
    String initial = '',
    bool multiline = false,
  }) async {
    final c = TextEditingController(text: initial);
    final result = await showMotionDialog<String>(
      context: context,
      builder: (dialog) => GlassDialog(
        title: Text(title),
        content: SizedBox(
          width: 600,
          child: TextField(
            controller: c,
            autofocus: true,
            minLines: multiline ? 6 : 1,
            maxLines: multiline ? 12 : 1,
            onSubmitted: multiline
                ? null
                : (_) => Navigator.pop(dialog, c.text),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, c.text),
            child: const Text('确认'),
          ),
        ],
      ),
    );
    c.dispose();
    return result;
  }

  Future<void> imported(String text) async {
    final result = await importSharedPreset(context, widget.backend, text);
    if (!mounted || result == null) return;
    selected = result['selected'];
    setState(() => message = '${result['message']}');
    await refresh();
  }

  Future<void> export({bool all = false}) async {
    try {
      final text =
          await widget.backend.call('library_export', [all ? null : selected])
              as String;
      if (!mounted) return;
      await showMotionDialog<void>(
        context: context,
        builder: (dialog) => GlassDialog(
          title: Text(all ? '导出全部预设' : '导出当前预设'),
          content: const Text('TXT 包含自定义名称和稳定条目标识。对方拖入窗口或粘贴文本后即可自动识别。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialog),
              child: const Text('关闭'),
            ),
            OutlinedButton.icon(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: text));
                if (dialog.mounted) Navigator.pop(dialog);
              },
              icon: const Icon(Icons.copy),
              label: const Text('复制文本'),
            ),
            FilledButton.icon(
              onPressed: () async {
                final file = await getSaveLocation(
                  suggestedName:
                      'SHODAN-${(all ? '全部预设' : '${items.firstWhere((i) => i['id'] == selected)['name']}').replaceAll(RegExp(r'[<>:"/\\|?*]'), '_')}.txt',
                  acceptedTypeGroups: const [
                    XTypeGroup(label: '预设文本', extensions: ['txt']),
                  ],
                );
                if (file != null) await File(file.path).writeAsString(text);
                if (dialog.mounted && file != null) Navigator.pop(dialog);
              },
              icon: const Icon(Icons.save_outlined),
              label: const Text('保存 TXT'),
            ),
          ],
        ),
      );
    } catch (e) {
      widget.onError(e);
    }
  }

  Future<void> capture({bool choose = false}) async {
    try {
      List<String>? ids;
      if (choose) {
        final data =
            await widget.backend.call('items', ['Stratagems', '']) as List;
        if (!mounted) return;
        ids = await showMotionDialog<List<String>>(
          context: context,
          builder: (dialog) => _SelectStratagems(items: data),
        );
        if (ids == null) return;
      }
      if (!mounted) return;
      final name = await input('自定义预设名称');
      if (name == null || name.trim().isEmpty) return;
      setState(() => busy = true);
      final result =
          await widget.backend.call('library_capture', [name, ids]) as Map;
      if (!mounted) return;
      selected = result['id'];
      setState(() => message = '${result['message']}');
      await refresh();
    } catch (e) {
      widget.onError(e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Wrap(
        spacing: 10,
        runSpacing: 10,
        children: [
          FilledButton.icon(
            onPressed: busy ? null : () => capture(),
            icon: const Icon(Icons.add),
            label: const Text('保存整套修改'),
          ),
          OutlinedButton.icon(
            onPressed: busy ? null : () => capture(choose: true),
            icon: const Icon(Icons.playlist_add),
            label: const Text('保存单件 / 多件战备'),
          ),
          OutlinedButton.icon(
            onPressed: busy
                ? null
                : () async {
                    try {
                      final files = await openFiles(
                        acceptedTypeGroups: const [
                          XTypeGroup(
                            label: '预设文件',
                            extensions: ['txt', 'json'],
                          ),
                        ],
                      );
                      if (files.isEmpty) return;
                      final texts = <String>[];
                      int size = 0;
                      for (final f in files) {
                        size += await f.length();
                        if (size > 8 * 1024 * 1024)
                          throw const FormatException('预设文件超过 8 MB');
                        texts.add(await f.readAsString());
                      }
                      final text = texts.length == 1
                          ? texts.single
                          : await widget.backend.call('library_join', [texts])
                                as String;
                      if (mounted) await imported(text);
                    } catch (e) {
                      widget.onError(e);
                    }
                  },
            icon: const Icon(Icons.file_open_outlined),
            label: const Text('导入文件'),
          ),
          OutlinedButton.icon(
            onPressed: busy
                ? null
                : () async {
                    final data = await Clipboard.getData('text/plain');
                    if (!mounted) return;
                    final text = await input(
                      '粘贴预设文本或分享码',
                      initial: data?.text ?? '',
                      multiline: true,
                    );
                    if (text != null && text.trim().isNotEmpty) {
                      try {
                        await imported(text);
                      } catch (e) {
                        widget.onError(e);
                      }
                    }
                  },
            icon: const Icon(Icons.content_paste),
            label: const Text('粘贴导入'),
          ),
          TextButton(
            onPressed: busy || items.isEmpty ? null : () => export(all: true),
            child: const Text('导出全部预设'),
          ),
          TextButton(
            onPressed: () => showMotionDialog<void>(
              context: context,
              builder: (_) => GlassDialog(
                title: const Text('原全局预设'),
                content: SizedBox(
                  width: 950,
                  height: 560,
                  child: PresetPage(
                    backend: widget.backend,
                    onError: widget.onError,
                  ),
                ),
                actions: [
                  Builder(
                    builder: (dialog) => TextButton(
                      onPressed: () => Navigator.pop(dialog),
                      child: const Text('关闭'),
                    ),
                  ),
                ],
              ),
            ),
            child: const Text('原全局预设'),
          ),
        ],
      ),
      const SizedBox(height: 16),
      if (busy) const LinearProgressIndicator(),
      if (message.isNotEmpty) Text(message),
      if (items.isEmpty)
        const Expanded(
          child: Center(
            child: Text(
              '预设库为空\n保存当前修改，或将别人分享的 TXT 拖入窗口。',
              textAlign: TextAlign.center,
            ),
          ),
        )
      else ...[
        DropdownMenu<String>(
          key: ValueKey((selected, items.length)),
          initialSelection: selected,
          expandedInsets: EdgeInsets.zero,
          enableFilter: true,
          menuHeight: 320,
          label: const Text('切换预设'),
          dropdownMenuEntries: [
            for (final p in items)
              DropdownMenuEntry(
                value: '${p['id']}',
                label: '${p['name']} · ${p['count']} 项参数',
              ),
          ],
          onSelected: busy
              ? null
              : (id) {
                  if (id != null) select(id);
                },
        ),
        const SizedBox(height: 12),
        Expanded(
          child: GlassPanel(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    '${items.firstWhere((i) => i['id'] == selected)['name']}',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    (items.firstWhere((i) => i['id'] == selected)['targets']
                            as List)
                        .join('、'),
                  ),
                  const SizedBox(height: 12),
                  Expanded(
                    child: preview == null
                        ? const SizedBox.shrink()
                        : ReviewBody(data: preview),
                  ),
                  Wrap(
                    spacing: 12,
                    children: [
                      FilledButton.icon(
                        onPressed: busy
                            ? null
                            : () async {
                                setState(() => busy = true);
                                try {
                                  final result =
                                      await widget.backend.call(
                                            'library_load',
                                            [selected],
                                          )
                                          as Map;
                                  if (mounted)
                                    setState(
                                      () => message =
                                          '预设已读取到编辑区，点击“写入游戏”生效。${(result['warnings'] as List? ?? []).join('；')}',
                                    );
                                  await refresh();
                                } catch (e) {
                                  widget.onError(e);
                                } finally {
                                  if (mounted) setState(() => busy = false);
                                }
                              },
                        icon: const Icon(Icons.check),
                        label: const Text('读取预设'),
                      ),
                      OutlinedButton(
                        onPressed: busy ? null : () => export(),
                        child: const Text('导出当前预设'),
                      ),
                      if (!(selected ?? '').startsWith('legacy:'))
                        TextButton(
                          onPressed: busy
                              ? null
                              : () async {
                                  final name = await input(
                                    '重命名预设',
                                    initial:
                                        '${items.firstWhere((i) => i['id'] == selected)['name']}',
                                  );
                                  if (name == null) return;
                                  try {
                                    await widget.backend.call(
                                      'library_rename',
                                      [selected, name],
                                    );
                                    await refresh();
                                  } catch (e) {
                                    widget.onError(e);
                                  }
                                },
                          child: const Text('重命名'),
                        ),
                      if (!(selected ?? '').startsWith('legacy:'))
                        TextButton(
                          onPressed: busy
                              ? null
                              : () async {
                                  try {
                                    await widget.backend.call(
                                      'library_delete',
                                      [selected],
                                    );
                                    await refresh();
                                  } catch (e) {
                                    widget.onError(e);
                                  }
                                },
                          child: const Text('删除'),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    ],
  );
}

class _SelectStratagems extends StatefulWidget {
  const _SelectStratagems({required this.items});
  final List items;
  @override
  State<_SelectStratagems> createState() => _SelectStratagemsState();
}

class _SelectStratagemsState extends State<_SelectStratagems> {
  final selected = <String>{};
  String query = '';
  @override
  Widget build(BuildContext context) {
    final items = widget.items
        .where(
          (p) => '${p['name']} ${p['id']}'.toLowerCase().contains(
            query.toLowerCase(),
          ),
        )
        .toList();
    return GlassDialog(
      title: const Text('选择一件或多件战备'),
      content: SizedBox(
        width: 680,
        height: 440,
        child: Column(
          children: [
            TextField(
              onChanged: (v) => setState(() => query = v),
              decoration: const InputDecoration(
                hintText: '搜索战备名称或 ID',
                prefixIcon: Icon(Icons.search),
              ),
            ),
            Row(
              children: [
                TextButton(
                  onPressed: () => setState(
                    () => selected.addAll(items.map((p) => '${p['id']}')),
                  ),
                  child: const Text('全选当前搜索'),
                ),
                TextButton(
                  onPressed: () => setState(selected.clear),
                  child: const Text('清空'),
                ),
                Text('已选 ${selected.length} 件'),
              ],
            ),
            Expanded(
              child: ListView.builder(
                itemCount: items.length,
                itemBuilder: (context, i) {
                  final p = items[i];
                  final id = '${p['id']}';
                  return CheckboxListTile(
                    value: selected.contains(id),
                    title: Text('${p['name']}'),
                    subtitle: Text(id),
                    onChanged: (on) => setState(
                      () => on == true ? selected.add(id) : selected.remove(id),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: selected.isEmpty
              ? null
              : () => Navigator.pop(context, selected.toList()),
          child: const Text('继续命名'),
        ),
      ],
    );
  }
}
