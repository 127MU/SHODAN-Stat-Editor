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
        Expanded(
          child: ListView.builder(
            itemCount:
                problems.length +
                warnings.length +
                (entries.isEmpty ? 1 : entries.length),
            itemBuilder: (context, index) {
              if (index < problems.length) {
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: SelectableText(
                    '${problems[index]}',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                );
              }
              index -= problems.length;
              if (index < warnings.length) {
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: SelectableText(
                    '${warnings[index]}',
                    style: const TextStyle(color: Colors.orange),
                  ),
                );
              }
              if (entries.isEmpty) return const Center(child: Text('没有参数变化'));
              final e = entries[index - warnings.length];
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
