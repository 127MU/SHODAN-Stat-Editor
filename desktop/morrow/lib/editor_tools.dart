import 'dart:convert';
import 'dart:io';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'backend.dart';
import 'glass_theme.dart';

class EditorTools extends StatefulWidget {
  const EditorTools({
    super.key,
    required this.backend,
    required this.revision,
    required this.onRefresh,
    required this.onError,
    required this.onRecord,
    required this.onPresets,
    required this.onlyChanged,
    required this.onOnlyChanged,
  });
  final Backend backend;
  final ValueNotifier<int> revision;
  final Future<void> Function() onRefresh;
  final void Function(Object) onError;
  final Future<void> Function(Map) onRecord;
  final VoidCallback onPresets;
  final bool onlyChanged;
  final ValueChanged<bool> onOnlyChanged;
  @override
  State<EditorTools> createState() => _EditorToolsState();
}

class _EditorToolsState extends State<EditorTools> {
  Map history = {};
  bool busy = false;
  int request = 0;
  @override
  void initState() {
    super.initState();
    widget.revision.addListener(refreshHistory);
    refreshHistory();
  }

  Future<void> refreshHistory() async {
    final ticket = ++request;
    try {
      final data = await widget.backend.call('history');
      if (mounted && ticket == request)
        setState(() => history = data is Map ? data : {});
    } catch (e) {
      if (mounted) widget.onError(e);
    }
  }

  Future<void> replay(String method) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      await widget.backend.call(method);
      await widget.onRefresh();
      await refreshHistory();
    } catch (e) {
      widget.onError(e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> report(String method, String title) async {
    final record = await showDialog<Map>(
      context: context,
      builder: (_) =>
          EditorReport(backend: widget.backend, method: method, title: title),
    );
    if (record != null && mounted) await widget.onRecord(record);
  }

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    scrollDirection: Axis.horizontal,
    child: Row(
      spacing: 8,
      children: [
        OutlinedButton(
          onPressed: busy ? null : widget.onPresets,
          child: const Text('装备预设'),
        ),
        OutlinedButton(
          onPressed: busy ? null : () => report('history', '修改记录'),
          child: const Text('修改记录'),
        ),
        OutlinedButton(
          onPressed: busy ? null : () => report('diagnostic_chain', '射击引用链'),
          child: const Text('射击引用链'),
        ),
        OutlinedButton(
          onPressed: busy ? null : () => report('diagnostic_resources', '资源诊断'),
          child: const Text('资源诊断'),
        ),
        OutlinedButton(
          onPressed: !busy && (history['undo'] as num? ?? 0) > 0
              ? () => replay('undo')
              : null,
          child: const Text('撤销'),
        ),
        OutlinedButton(
          onPressed: !busy && (history['redo'] as num? ?? 0) > 0
              ? () => replay('redo')
              : null,
          child: const Text('重做'),
        ),
        OutlinedButton(
          onPressed: busy ? null : () => replay('reset'),
          child: const Text('恢复本项'),
        ),
        FilterChip(
          label: const Text('仅已修改'),
          selected: widget.onlyChanged,
          onSelected: widget.onOnlyChanged,
        ),
      ],
    ),
  );
  @override
  void dispose() {
    widget.revision.removeListener(refreshHistory);
    super.dispose();
  }
}

class EditorReport extends StatefulWidget {
  const EditorReport({
    super.key,
    required this.backend,
    required this.method,
    required this.title,
  });
  final Backend backend;
  final String method, title;
  @override
  State<EditorReport> createState() => _EditorReportState();
}

class _EditorReportState extends State<EditorReport> {
  Map data = {};
  bool loading = true;
  String query = '', error = '';
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    setState(() {
      loading = true;
      error = '';
    });
    try {
      final result = await widget.backend.call(widget.method);
      if (mounted) setState(() => data = result is Map ? result : {});
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> export() async {
    try {
      final file = await getSaveLocation(
        suggestedName: 'SHODAN-${widget.title}.json',
        acceptedTypeGroups: [
          const XTypeGroup(label: '诊断报告', extensions: ['json']),
        ],
      );
      if (file == null) return;
      final text = const JsonEncoder.withIndent('  ').convert(data);
      await File(
        file.path,
      ).writeAsString(widget.backend.diagnostics.redact(text));
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    }
  }

  List list(dynamic value) => value is List ? value : [];
  @override
  Widget build(BuildContext context) => GlassDialog(
    title: Text(widget.title),
    content: SizedBox(
      width: 900,
      height: MediaQuery.sizeOf(context).height * .62,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.method == 'history')
            const Text('最近 100 次参数编辑；读取预设后重新记录，资源补丁安装不参与撤销。'),
          if (data['equipment'] != null) Text('${data['equipment']}'),
          if (data['note'] != null) Text('${data['note']}'),
          if (loading) const LinearProgressIndicator(),
          if (error.isNotEmpty) SelectableText(error),
          TextField(
            decoration: const InputDecoration(
              hintText: '在当前报告中搜索',
              prefixIcon: Icon(Icons.search),
            ),
            onChanged: (value) => setState(() => query = value.toLowerCase()),
          ),
          Expanded(
            child: ListView(
              children: [
                for (final p in list(data['packages']))
                  ListTile(
                    title: Text('${p['name'] ?? p['id']}'),
                    subtitle: Text('${p['id'] ?? ''}'),
                  ),
                for (final entry in list(data['entries']))
                  if (entry.toString().toLowerCase().contains(query))
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${entry['title'] ?? entry['label'] ?? entry['type_name'] ?? entry['type'] ?? '记录'}',
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            if (entry['count'] != null)
                              Text('${entry['count']} 项字段'),
                            if (entry['via'] != null)
                              Text('来源：${entry['via']}'),
                            if (entry['parent_title'] != null)
                              Text('上级：${entry['parent_title']}'),
                            if (entry['summary'] != null)
                              Text('${entry['summary']}'),
                            if (entry['id'] != null) Text('ID：${entry['id']}'),
                            if (entry['status'] != null)
                              Text('${entry['status']}'),
                            if (entry['providers'] != null)
                              Text(
                                '来源包：${list(entry['provider_names'] ?? entry['providers']).join('、')}',
                              ),
                            if (entry['missing'] == true)
                              const Text('当前版本没有此记录'),
                            if (entry['repeated'] == true)
                              const Text('重复或循环引用，未再次展开'),
                            if (entry['record_hash'] != null &&
                                entry['missing'] != true)
                              TextButton(
                                onPressed: () => Navigator.pop(context, {
                                  'id': entry['record_hash'],
                                  'name': entry['title'],
                                }),
                                child: const Text('打开数据记录'),
                              ),
                          ],
                        ),
                      ),
                    ),
                if (!loading && list(data['entries']).isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: Text('没有可显示的记录'),
                  ),
                for (final warning in list(data['warnings'])) Text('$warning'),
              ],
            ),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(onPressed: loading ? null : load, child: const Text('重新读取')),
      TextButton(
        onPressed: loading || error.isNotEmpty ? null : export,
        child: const Text('导出报告'),
      ),
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('关闭'),
      ),
    ],
  );
}
