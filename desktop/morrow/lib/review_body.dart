import 'package:flutter/material.dart';

class ReviewBody extends StatelessWidget {
  const ReviewBody({super.key, required this.data});
  final dynamic data;
  List<dynamic> list(String key) =>
      data is Map && data[key] is List ? data[key] as List : [];
  @override
  Widget build(BuildContext context) {
    if (data is! Map) return SelectableText('$data');
    final problems = list('problems'),
        warnings = list('warnings'),
        entries = list('entries');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${entries.length} 项变化 · 原值 → 待写入值',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        if (problems.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: SelectableText(
              problems.join('\n'),
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        if (warnings.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: SelectableText(
              warnings.join('\n'),
              style: const TextStyle(color: Colors.orange),
            ),
          ),
        Expanded(
          child: entries.isEmpty
              ? const Center(child: Text('没有参数变化'))
              : ListView.separated(
                  itemCount: entries.length,
                  separatorBuilder: (_, i) => const Divider(),
                  itemBuilder: (context, i) {
                    final e = entries[i];
                    return ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        '${e['equipment'] ?? ''} · ${e['parameter'] ?? ''}',
                      ),
                      subtitle: SelectableText(
                        '${e['before'] ?? ''} → ${e['after'] ?? ''}\n${e['file'] ?? ''}',
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}
