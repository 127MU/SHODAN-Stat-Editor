import 'package:flutter/material.dart';
import 'catalog_groups.dart';
import 'glass_theme.dart';

class GroupChooser extends StatefulWidget {
  const GroupChooser({super.key, required this.group});
  final CatalogGroup group;
  @override
  State<GroupChooser> createState() => _GroupChooserState();
}

class _GroupChooserState extends State<GroupChooser> {
  bool all = false;
  String query = '';
  @override
  Widget build(BuildContext context) {
    final group = widget.group;
    final entries = (all ? group.entries : group.matches)
        .where((item) => item.toString().toLowerCase().contains(query))
        .toList();
    return GlassDialog(
      title: Text(group.name),
      content: SizedBox(
        width: 680,
        height: 420,
        child: Column(
          children: [
            TextField(
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: '查找本体、部件或武器',
              ),
              onChanged: (value) => setState(() => query = value.toLowerCase()),
            ),
            if (group.matches.length != group.entries.length)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('显示全部关联条目'),
                subtitle: Text(
                  '当前筛选匹配 ${group.matches.length} 项，共 ${group.entries.length} 项',
                ),
                value: all,
                onChanged: (value) => setState(() => all = value),
              ),
            Expanded(
              child: ListView(
                children: [
                  for (final item in entries)
                    Card(
                      child: ListTile(
                        title: Text(
                          item['name'] == group.name
                              ? '本体参数'
                              : '${item['name']}',
                        ),
                        subtitle: Text(
                          item['changed'] == true ? '已修改' : '未修改',
                        ),
                        trailing: const Icon(Icons.arrow_forward),
                        onTap: () => Navigator.pop(context, item),
                      ),
                    ),
                  if (entries.isEmpty) const ListTile(title: Text('没有匹配的关联条目')),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}
