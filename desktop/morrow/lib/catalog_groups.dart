/// Group only explicit parent relationships (or an exact colon-prefix parent).
/// Do not infer families from similar names: M-10 and M-100 must remain separate.
class CatalogGroup {
  CatalogGroup(this.id, this.name);
  final String id, name;
  final entries = <Map>[];
  final matches = <Map>[];
  bool get changed => entries.any((item) => item['changed'] == true);
}

List<CatalogGroup> buildCatalogGroups(
  List items,
  String tab, {
  String query = '',
  bool onlyChanged = false,
}) {
  final noGrouping = [
    'Primary',
    'Secondary',
    'Support',
    'Throwables',
  ].contains(tab);
  final byName = {for (final item in items) '${item['name']}': item as Map};
  final groups = <String, CatalogGroup>{};
  final search = query.toLowerCase();
  final separator = RegExp('[:：]');
  for (final raw in items) {
    final item = raw as Map;
    final id = '${item['id']}';
    final name = '${item['name'] ?? ''}';
    var parents = noGrouping || item['groups'] is! List
        ? <dynamic>[]
        : item['groups'] as List;
    if (parents.isEmpty) {
      final colon = separator.firstMatch(name);
      final base = colon == null ? '' : name.substring(0, colon.start).trim();
      final root = noGrouping ? null : byName[base];
      parents = [
        {'id': root?['id'] ?? id, 'name': root?['name'] ?? name},
      ];
    }
    final matched =
        (!onlyChanged || item['changed'] == true) &&
        (search.isEmpty || item.toString().toLowerCase().contains(search));
    for (final rawParent in parents) {
      if (rawParent is! Map || rawParent['id'] == null) continue;
      final key = '${rawParent['id']}';
      final group = groups.putIfAbsent(
        key,
        () => CatalogGroup(key, '${rawParent['name'] ?? name}'),
      );
      if (!group.entries.any((entry) => '${entry['id']}' == id)) {
        group.entries.add(item);
        if (matched) group.matches.add(item);
      }
    }
  }
  return groups.values.where((group) => group.matches.isNotEmpty).toList();
}
