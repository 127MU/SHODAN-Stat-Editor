import 'motion.dart';
import 'catalog_groups.dart';
import 'group_chooser.dart';
import 'editor_tools.dart';
import 'game_tweaks.dart';
import 'glass_theme.dart';
import 'install_dialog.dart';
import 'diagnostics_ui.dart';
import 'dart:io';
import 'dart:convert';
import 'dart:async';
import 'dart:ui' as ui;
import 'package:file_selector/file_selector.dart';
import 'number_display.dart';
import 'preference_slider.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'backend.dart';
import 'desktop_frame.dart';
import 'armor_page.dart';
import 'armor_item.dart';
import 'game_text.dart';
import 'preset_page.dart';
import 'review_body.dart';
import 'release_updates.dart';
import 'app_version.dart';
import 'theme_reveal.dart';
import 'window_activity.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDesktopFrame();
  runApp(const Workbench());
}

class Workbench extends StatefulWidget {
  const Workbench({super.key, this.backend, this.persistAppearance = true});
  final bool persistAppearance;
  final Backend? backend;
  @override
  State<Workbench> createState() => _WorkbenchState();
}

class _WorkbenchState extends State<Workbench> {
  late final Backend backend = widget.backend ?? Backend();
  bool ready = false, busy = false, dark = true;
  bool diagnosing = false;
  bool checkingUpdates = false;
  bool mcpEnabled = false, mcpBusy = false;
  String updateStatus = '启动时自动检查一次正式发行版';
  bool onlyChanged = false, catalogOnlyChanged = false;
  String diagnosticResult = '';
  String status = '正在读取数据…', tab = 'Primary';
  String catalogQuery = '', parameterQuery = '';
  String get query => current == null ? catalogQuery : parameterQuery;
  set query(String value) {
    if (current == null) {
      catalogQuery = value;
    } else {
      parameterQuery = value;
    }
  }

  Map? current;
  String? activeSection;
  Object? sectionRequest;
  List<dynamic> items = [], rows = [];
  (List<dynamic>, String, String, bool)? catalogViewKey;
  List<CatalogGroup> catalogView = [];
  int epoch = 0;
  String material = 'liquid';
  double fontSize = 14, blur = 18, opacity = .3;
  double pageOffset = 0;
  static const defaultAccent = Color(0xff818cf8);
  static const accentPresets = {
    '靛蓝': defaultAccent,
    '海蓝': Color(0xff0ea5e9),
    '青绿': Color(0xff14b8a6),
    '翡翠': Color(0xff22c55e),
    '琥珀': Color(0xfff59e0b),
    '珊瑚': Color(0xfff97360),
    '玫红': Color(0xffec4899),
    '紫罗兰': Color(0xffa855f7),
  };
  Color accent = defaultAccent;
  String backgroundPath = '';
  double backgroundDim = .35;
  Timer? styleTimer;
  Future<void> styleWrite = Future.value();
  final catalogSearch = TextEditingController();
  final parameterSearch = TextEditingController();
  TextEditingController get search =>
      current == null ? catalogSearch : parameterSearch;
  final navigator = GlobalKey<NavigatorState>();
  final themeCapture = GlobalKey();
  ui.Image? themeSnapshot;
  Offset themeOrigin = Offset.zero;
  bool themeCapturing = false;
  final rowRevision = ValueNotifier<int>(0);
  static const tabs = {
    'Armor': '被动组合',
    'Armors': '护甲、头盔与披风',
    'Presets': '全局预设',
    'Settings': '设置',
    'Tweaks': '游戏参数',
    'Primary': '主武器',
    'Secondary': '副武器',
    'Support': '支援武器',
    'Throwables': '投掷物',
    'Stratagems': '战略配备',
    'Mechas': '载具与机甲',
    'Boosters': '强化增益',
    'Attachments': '配件',
    'Helldiver': '潜兵',
    'Terminids': '终结族',
    'Automatons': '机器人',
    'Illuminate': '光能族',
    'SEAF': '超级地球部队',
    'Spawning': '敌人生成',
    'Records': '数据库',
  };
  static const navigation = {
    'Primary': ('装备', Icons.gps_fixed),
    'Stratagems': ('战略配备', Icons.rocket_launch_outlined),
    'Mechas': ('载具机甲', Icons.directions_car_outlined),
    'Armors': ('护甲', Icons.shield_outlined),
    'Helldiver': ('潜兵', Icons.person_outline),
    'Terminids': ('敌人', Icons.pest_control_outlined),
    'Records': ('数据与预设', Icons.storage_outlined),
    'Tweaks': ('游戏参数', Icons.settings_outlined),
    'Settings': ('设置', Icons.tune),
  };
  List<String> peers(String key) {
    for (final group in [
      [
        'Primary',
        'Secondary',
        'Support',
        'Throwables',
        'Boosters',
        'Attachments',
      ],
      ['Armors', 'Armor'],
      ['Terminids', 'Automatons', 'Illuminate', 'SEAF', 'Spawning'],
      ['Records', 'Presets'],
    ]) {
      if (group.contains(key)) return group;
    }
    return [];
  }

  @override
  void initState() {
    super.initState();
    initialize();
  }

  Future<void> initialize() async {
    try {
      if (widget.persistAppearance) await loadStyle();
      await backend.start();
      if (!mounted) return;
      setState(() => ready = true);
      await load('Primary');
      if (mounted && backend.startupProblem != null) {
        setState(() => status = '部分数据需检查 · ${backend.startupProblem}');
      }
      if (mounted && widget.backend == null)
        unawaited(checkUpdates(automatic: true));
    } catch (e) {
      if (mounted) setState(() => status = '启动失败：$e');
    }
  }

  Future<void> checkUpdates({bool automatic = false}) async {
    if (checkingUpdates || !mounted) return;
    setState(() {
      checkingUpdates = true;
      updateStatus = '正在检查更新…';
    });
    try {
      final offer = await checkNativeRelease(backend);
      if (!mounted) return;
      setState(() {
        checkingUpdates = false;
        updateStatus = offer['newer'] == true
            ? '发现新版本 ${offer['version']}'
            : '当前已是最新正式版本';
      });
      if (offer['newer'] == true) {
        final context = navigator.currentContext;
        if (context != null && context.mounted)
          await showReleaseOffer(context, backend, offer);
      }
    } catch (e) {
      backend.diagnostics.record('原生更新检查失败：$e');
      if (mounted)
        setState(() => updateStatus = automatic ? '暂时无法检查更新，可点击重试' : '$e');
    } finally {
      if (mounted) setState(() => checkingUpdates = false);
    }
  }

  Future<void> toggleMcp(bool on) async {
    if (mcpBusy) return;
    setState(() => mcpBusy = true);
    try {
      final reply = await backend.nativeCall(on ? 'mcp-start' : 'mcp-stop');
      if (mounted)
        setState(() => mcpEnabled = reply is Map && reply['enabled'] == true);
    } catch (e) {
      if (mounted) showError(e);
    } finally {
      if (mounted) setState(() => mcpBusy = false);
    }
  }

  Future<void> copyMcp() async {
    try {
      final config = await backend.nativeCall('mcp-config');
      await Clipboard.setData(
        ClipboardData(text: const JsonEncoder.withIndent('  ').convert(config)),
      );
      if (mounted) setState(() => status = '已复制 MCP 配置');
    } catch (e) {
      if (mounted) showError(e);
    }
  }

  Future<void> load(String key) async {
    final ticket = ++epoch;
    setState(() => busy = true);
    void showTab(List<dynamic> entries) {
      setState(() {
        final order = tabs.keys.toList();
        pageOffset = key == tab ? 0 : order.indexOf(key) > order.indexOf(tab) ? 20 : -20;
        tab = key;
        current = null;
        catalogOnlyChanged = false;
        catalogQuery = '';
        parameterQuery = '';
        catalogSearch.clear();
        parameterSearch.clear();
        items = entries;
        status = key == 'Armor'
            ? '选择被动后，点击写入游戏生效'
            : entries.isEmpty && ['Presets', 'Settings', 'Tweaks'].contains(key)
            ? '数据已就绪'
            : '${entries.length} 个条目';
      });
    }
    try {
      if (['Armor', 'Presets', 'Settings', 'Tweaks'].contains(key)) {
        showTab([]);
        return;
      }
      await backend.call('editor_mode', [
        [
          'Terminids',
          'Automatons',
          'Illuminate',
          'SEAF',
          'Spawning',
        ].contains(key),
      ]);
      final result = await backend.call('items', [key, '']);
      if (mounted && ticket == epoch) showTab(result is List ? result : []);
      if (mounted &&
          ticket == epoch &&
          key == 'Helldiver' &&
          items.length == 1) {
        await select(items.single as Map);
      }
    } catch (e) {
      showError(e);
    } finally {
      if (mounted && ticket == epoch) setState(() => busy = false);
    }
  }

  Future<void> openCatalogGroup(CatalogGroup group, BuildContext source) async {
    if (busy) return;
    if (group.entries.length == 1) {
      await select(group.entries.single);
      return;
    }
    final entry = await showMotionDialog<Map>(
      context: navigator.currentContext!,
      source: source,
      builder: (_) => GroupChooser(group: group),
    );
    if (entry != null && mounted) await select(entry);
  }

  Future<void> select(Map item) async {
    final ticket = ++epoch;
    setState(() => busy = true);
    try {
      await backend.call('select', [item['id']]);
      final result = await backend.call('rows_fast');
      if (mounted && ticket == epoch) {
        setState(() {
          pageOffset = 24;
          current = item;
          activeSection = null;
          parameterQuery = '';
          parameterSearch.clear();
          onlyChanged = false;
          rows = result is List ? result : [];
        });
      }
    } catch (e) {
      showError(e);
    } finally {
      if (mounted && ticket == epoch) setState(() => busy = false);
    }
  }

  Future<void> backToCatalog() async {
    if (busy) return;
    final ticket = ++epoch;
    setState(() => busy = true);
    try {
      final result = await backend.call('items', [tab, '']);
      if (mounted && ticket == epoch)
        setState(() {
          pageOffset = -24;
          items = result is List ? result : [];
          current = null;
          activeSection = null;
          status =
              '${items.where((item) => item['changed'] == true).length} 项已修改 / 共 ${items.length} 项';
        });
    } catch (e) {
      showError(e);
    } finally {
      if (mounted && ticket == epoch) setState(() => busy = false);
    }
  }

  Future<void> refreshCurrent() async {
    final ticket = epoch;
    var result = await backend.call('rows_fast');
    if (activeSection != null && mounted && ticket == epoch) {
      final updated = await backend.call('rows_section', [activeSection]);
      if (result is List && updated is List) {
        final byId = {for (final row in updated) row['id']: row};
        result = [for (final row in result) byId[row['id']] ?? row];
      }
    }
    if (mounted && ticket == epoch) {
      setState(() => rows = result is List ? result : []);
      rowRevision.value++;
    }
  }

  Future<bool> edit(String method, List<dynamic> args) async {
    final ticket = epoch;
    try {
      await backend.call(method, args);
      await refreshCurrent();
      if (mounted && ticket == epoch) setState(() => status = '修改已保存，写入游戏后生效');
      return true;
    } catch (e) {
      showError(e);
      return false;
    }
  }

  void showError(Object e) {
    if (!mounted) return;
    setState(() => status = e.toString());
    showMotionDialog<void>(
      context: navigator.currentContext ?? context,
      builder: (ctx) => GlassDialog(
        title: const Text('操作未完成'),
        content: SelectableText(e.toString()),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  Future<void> choices(Map row) async {
    try {
      final response = await backend.call('choices', [row['id']]);
      if (!mounted) return;
      final options = response is List ? response : [];
      String filter = '';
      final choice = await showMotionDialog<Map>(
        context: navigator.currentContext ?? context,
        builder: (ctx) => StatefulBuilder(
          builder: (ctx, update) => GlassDialog(
            title: Text(row['label']),
            content: SizedBox(
              width: 620,
              height: 450,
              child: Column(
                children: [
                  TextField(
                    autofocus: true,
                    decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.search),
                      hintText: '搜索名称或 ID',
                    ),
                    onChanged: (v) => update(() => filter = v.toLowerCase()),
                  ),
                  Expanded(
                    child: ListView(
                      children: [
                        for (final option in options)
                          if (option.toString().toLowerCase().contains(filter))
                            ListTile(
                              title: Text(
                                '${option['name'] ?? option['label'] ?? option['id']}',
                              ),
                              subtitle: Text(
                                '#${option['id']} · ${option['description'] ?? ''}',
                              ),
                              enabled: option['disabled'] != true,
                              onTap: () => Navigator.pop(ctx, option as Map),
                            ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('取消'),
              ),
            ],
          ),
        ),
      );
      if (choice != null) {
        if (['resomode', 'smmode'].contains(row['choice_kind'])) {
          if (choice['id'] == 0) return;
          if (!mounted) return;
          final yes = await showMotionDialog<bool>(
            context: navigator.currentContext ?? context,
            builder: (ctx) => GlassDialog(
              title: const Text('确认修改资源补丁'),
              content: const Text('此操作会立即写入或移除游戏资源补丁。请先关闭游戏，完成后重启生效。'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('继续'),
                ),
              ],
            ),
          );
          if (yes != true) return;
        }
        await edit('choose', [row['id'], choice['id']]);
      }
    } catch (e) {
      showError(e);
    }
  }

  Future<void> restoreGame() async {
    final yes = await showMotionDialog<bool>(
      context: navigator.currentContext!,
      builder: (ctx) => GlassDialog(
        title: const Text('恢复原版'),
        content: const Text('请先完全退出游戏。恢复编辑器管理的游戏文件；修改配置和预设仍保留。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确认恢复'),
          ),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    setState(() => busy = true);
    try {
      await showMotionDialog<dynamic>(
        context: navigator.currentContext!,
        barrierDismissible: false,
        builder: (_) => InstallDialog(backend: backend, restore: true),
      );
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> inspectCatalog({required bool attachments}) async {
    final request = backend.call(attachments ? 'attachment_options' : 'baseline_check');
    var query = '';
    await showMotionDialog<void>(
      context: navigator.currentContext ?? context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, update) => GlassDialog(
          title: Text(attachments ? '武器配件选项目录' : '游戏文件与补丁检查'),
          content: SizedBox(
            width: 660,
            height: 450,
            child: FutureBuilder<dynamic>(
              future: request,
              builder: (context, result) {
                if (result.hasError) return SelectableText('${result.error}');
                if (!result.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (attachments) {
                  final options = result.data is List
                      ? (result.data as List).whereType<Map>()
                          .where((row) => row.toString().toLowerCase().contains(query)).toList()
                      : <Map>[];
                  return Column(
                    children: [
                      const Text('此目录显示游戏定义的选项和槽位。具体武器可用哪些配件由游戏决定。'),
                      TextField(
                        autofocus: true,
                        decoration: const InputDecoration(
                          prefixIcon: Icon(Icons.search),
                          hintText: '搜索配件名、槽位、十六进制或数字 ID',
                        ),
                        onChanged: (value) => update(() => query = value.trim().toLowerCase()),
                      ),
                      const SizedBox(height: 8),
                      Expanded(
                        child: ListView.builder(
                          itemCount: options.length,
                          itemBuilder: (context, i) {
                            final item = options[i];
                            return ListTile(
                              title: Text('${item['name']}'),
                              subtitle: SelectableText(
                                '${(item['slots'] as List).join('、')} · ${item['hex']} · #${item['id']}',
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                  );
                }
                final data = result.data as Map;
                return ListView(
                  children: [
                    for (final problem in data['problems'] as List)
                      ListTile(
                        leading: const Icon(Icons.error_outline),
                        title: SelectableText('$problem'),
                      ),
                    for (final item in data['entries'] as List)
                      ListTile(
                        title: Text('${item['parameter']}'),
                        subtitle: Text('${item['after']}'),
                      ),
                  ],
                );
              },
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('关闭')),
          ],
        ),
      ),
    );
  }

  Future<void> install(BuildContext source) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      final preview = await showMotionDialog<dynamic>(
        context: navigator.currentContext!,
        source: source,
        barrierDismissible: false,
        builder: (_) => InstallDialog(backend: backend, preview: true),
      );
      if (preview == null) return;
      if (!mounted) return;
      setState(() => busy = false);
      final problems = preview is Map && preview['problems'] is List
          ? preview['problems'] as List
          : [];
      final yes = await showMotionDialog<bool>(
        context: navigator.currentContext ?? context,
        builder: (ctx) => GlassDialog(
          title: const Text('写入前预览'),
          content: SizedBox(
            width: 640,
            height: 400,
            child: ReviewBody(data: preview),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: problems.isEmpty
                  ? () => Navigator.pop(ctx, true)
                  : null,
              child: const Text('确认写入'),
            ),
          ],
        ),
      );
      if (mounted && yes == true) {
        setState(() => busy = true);
        final result = await showMotionDialog<dynamic>(
          context: navigator.currentContext!,
          barrierDismissible: false,
          builder: (_) => InstallDialog(
            backend: backend,
            allowFloatAdjustment:
                preview is Map && preview['allow_float_adjustment'] == true,
          ),
        );
        if (mounted)
          setState(
            () => status = result is Map
                ? '${result['message'] ?? ''}'
                : '安装窗口已关闭',
          );
      }
    } catch (e) {
      showError(e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> code(Map row) async {
    final arrows = <int>[];
    final result = await showMotionDialog<List<int>>(
      context: navigator.currentContext ?? context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, update) => GlassDialog(
          title: const Text('录入战备指令'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                arrows.map((x) => ['', '↑', '→', '↓', '←'][x]).join(' '),
                style: const TextStyle(fontSize: 28),
              ),
              Wrap(
                children: [
                  for (int i = 1; i <= 4; i++)
                    IconButton(
                      onPressed: arrows.length >= 9
                          ? null
                          : () => update(() => arrows.add(i)),
                      icon: Icon(
                        [
                          Icons.error,
                          Icons.arrow_upward,
                          Icons.arrow_forward,
                          Icons.arrow_downward,
                          Icons.arrow_back,
                        ][i],
                      ),
                    ),
                  IconButton(
                    onPressed: arrows.isEmpty
                        ? null
                        : () => update(() => arrows.removeLast()),
                    icon: const Icon(Icons.backspace_outlined),
                  ),
                ],
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: arrows.isEmpty
                  ? null
                  : () => Navigator.pop(ctx, arrows),
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    if (result != null) await edit('code_set', [row['id'], result]);
  }

  Future<void> equipmentPresets() async {
    final ticket = epoch;
    int slot = 1;
    var loading = false;
    Map info = {};
    Future<void> refresh() async {
      final x = await backend.call('preset_info', [slot]);
      info = x as Map;
    }

    try {
      await refresh();
      if (!mounted || ticket != epoch) return;
      await showMotionDialog<void>(
        context: navigator.currentContext ?? context,
        builder: (ctx) => StatefulBuilder(
          builder: (ctx, update) => GlassDialog(
            title: Text('${current?['name']} · 装备预设'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SegmentedButton<int>(
                  segments: [
                    for (int i = 1; i <= 5; i++)
                      ButtonSegment(value: i, label: Text('$i')),
                  ],
                  selected: {slot},
                  onSelectionChanged: loading ? null : (values) async {
                    update(() {
                      slot = values.first;
                      loading = true;
                    });
                    try {
                      await refresh();
                    } catch (e) {
                      info = {};
                      if (ctx.mounted) showError(e);
                    } finally {
                      if (ctx.mounted) update(() => loading = false);
                    }
                  },
                ),
                const SizedBox(height: 16),
                Text(
                  loading ? '正在读取预设…' : '${info['name'] ?? '预设 $slot'} · ${info['saved'] == true ? '已保存' : '空预设'}',
                ),
              ],
            ),
            actions: [
              for (final op in {
                'save': '保存',
                'load': '读取',
                'clear': '清空',
              }.entries)
                TextButton(
                  onPressed: loading || (op.key != 'save' && info['saved'] != true)
                      ? null
                      : () async {
                          update(() => loading = true);
                          try {
                            await backend.call('preset', [op.key, slot]);
                            if (mounted && ticket == epoch && op.key == 'load') {
                              await refreshCurrent();
                            }
                            if (ctx.mounted && ticket == epoch) await refresh();
                          } catch (e) {
                            showError(e);
                          } finally {
                            if (ctx.mounted) update(() => loading = false);
                          }
                        },
                  child: Text(op.value),
                ),
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('关闭'),
              ),
            ],
          ),
        ),
      );
    } catch (e) {
      showError(e);
    }
  }

  File get styleFile {
    final env = Platform.environment;
    final base =
        env['SHODAN_PROFILE'] ??
        '${env['LOCALAPPDATA'] ?? File(Platform.resolvedExecutable).parent.path}/SHODAN/StatEditor';
    return File('$base/morrow-ui.json');
  }

  Future<void> loadStyle() async {
    try {
      if (!await styleFile.exists()) return;
      final v = jsonDecode(await styleFile.readAsString());
      if (!mounted || v is! Map) return;
      setState(() {
        dark = v['dark'] is bool ? v['dark'] : dark;
        final savedAccent = v['accent'];
        if (savedAccent is int && savedAccent >= 0xff000000 && savedAccent <= 0xffffffff) {
          accent = Color(savedAccent);
        }
        backend.diagnostics.enabled = v['diagnosticMode'] == true;
        backgroundPath = v['backgroundPath'] is String
            ? v['backgroundPath']
            : '';
        backgroundDim = v['backgroundDim'] is num
            ? (v['backgroundDim'] as num).toDouble().clamp(0, .9)
            : backgroundDim;
        material = ['liquid', 'frosted', 'clear'].contains(v['material'])
            ? v['material']
            : material;
        fontSize = v['fontSize'] is num
            ? (v['fontSize'] as num).toDouble().clamp(12, 24)
            : fontSize;
        blur = v['blur'] is num
            ? (v['blur'] as num).toDouble().clamp(0, 40)
            : blur;
        opacity = v['opacity'] is num
            ? (v['opacity'] as num).toDouble().clamp(.08, .85)
            : opacity;
      });
    } catch (_) {
      if (mounted) setState(() => status = '外观设置无法读取，已使用默认外观');
    }
  }

  void saveStyle() {
    if (!widget.persistAppearance) return;
    {
      final text = jsonEncode({
        'dark': dark,
        'accent': accent.toARGB32(),
        'material': material,
        'fontSize': fontSize,
        'blur': blur,
        'opacity': opacity,
        'backgroundPath': backgroundPath,
        'backgroundDim': backgroundDim,
        'diagnosticMode': backend.diagnostics.enabled,
      });
      styleWrite = styleWrite.catchError((_) {}).then((_) async {
        try {
          final f = styleFile;
          await f.parent.create(recursive: true);
          await f.writeAsString(text, flush: true);
        } catch (_) {
          if (mounted) setState(() => status = '外观设置保存失败，请检查配置目录权限');
        }
      });
    }
  }

  Future<void> shutdown() async {
    // All settings are queued at the time of the operation, not on close.
    await styleWrite;
  }

  Future<void> changeTheme(bool value, BuildContext source, {
    Offset? pointer, bool trailing = false,
  }) async {
    if (value == dark || themeCapturing || themeSnapshot != null) return;
    final boundary = themeCapture.currentContext?.findRenderObject();
    if (boundary is RenderRepaintBoundary && boundary.hasSize && !boundary.size.isEmpty &&
        !windowResizing.value && !MediaQuery.disableAnimationsOf(source)) {
      final control = source.findRenderObject();
      var origin = boundary.size.center(Offset.zero);
      if (control is RenderBox && control.hasSize) {
        final local = trailing
            ? Offset(control.size.width - 26, control.size.height / 2)
            : control.size.center(Offset.zero);
        origin = boundary.globalToLocal(control.localToGlobal(local));
      }
      themeCapturing = true;
      try {
        final scale = (1920 / boundary.size.longestSide).clamp(.25, 1.0);
        final image = await boundary.toImage(pixelRatio: scale);
        if (!mounted || windowResizing.value) {
          image.dispose();
        } else {
          themeSnapshot = image;
          themeOrigin = pointer == null ? origin : boundary.globalToLocal(pointer);
        }
      } catch (_) {
        // A frame that cannot be captured still permits the theme change.
      } finally {
        themeCapturing = false;
      }
    }
    if (!mounted) return;
    setState(() => dark = value);
    saveStyle();
  }

  Widget themeControl(Widget Function(ValueChanged<bool>) build, {bool trailing = false}) =>
      Builder(builder: (context) {
        Offset? pointer;
        return Listener(
          onPointerDown: (event) => pointer = event.position,
          onPointerCancel: (_) => pointer = null,
          child: build((value) {
            changeTheme(value, context, pointer: pointer, trailing: trailing);
            pointer = null;
          }),
        );
      });

  void finishThemeReveal() {
    final snapshot = themeSnapshot;
    if (!mounted || snapshot == null) return;
    setState(() => themeSnapshot = null);
    WidgetsBinding.instance.addPostFrameCallback((_) => snapshot.dispose());
  }

  String accentHex(Color color) =>
      '#${(color.toARGB32() & 0xffffff).toRadixString(16).padLeft(6, '0').toUpperCase()}';

  void setAccent(Color color) {
    if (!mounted || color == accent) return;
    setState(() => accent = color);
    saveStyle();
  }

  Widget accentMenu() => Builder(builder: (source) => PopupMenuButton<int>(
    tooltip: '选择强调色',
    position: PopupMenuPosition.under,
    onSelected: (value) {
      if (value == -1) {
        editAccent(source);
      } else {
        setAccent(Color(value));
      }
    },
    itemBuilder: (_) => [
      for (final entry in accentPresets.entries)
        PopupMenuItem(
          value: entry.value.toARGB32(),
          child: Row(spacing: 12, children: [
            CircleAvatar(backgroundColor: entry.value, radius: 8),
            Expanded(child: Text(entry.key)),
            if (accent == entry.value) const Icon(Icons.check, size: 16),
          ]),
        ),
      const PopupMenuDivider(),
      const PopupMenuItem(value: -1, child: Text('自定义颜色…')),
    ],
    child: const Padding(
      padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Text('选择颜色'), Icon(Icons.arrow_drop_down),
      ]),
    ),
  ));

  Future<void> editAccent(BuildContext source) async {
    final form = GlobalKey<FormState>();
    Color? parse(String? value) {
      final hex = value?.trim().replaceFirst(RegExp(r'^#'), '') ?? '';
      if (!RegExp(r'^[0-9a-fA-F]{6}$').hasMatch(hex)) return null;
      return Color(0xff000000 | int.parse(hex, radix: 16));
    }

    final color = await showMotionDialog<Color>(
      context: source,
      source: source,
      builder: (context) => GlassDialog(
        title: const Text('自定义强调色'),
        content: Form(
          key: form,
          child: TextFormField(
            initialValue: accentHex(accent),
            autofocus: true,
            decoration: const InputDecoration(
              labelText: '强调色',
              hintText: '#818CF8',
              helperText: '输入六位十六进制颜色值',
            ),
            validator: (value) => parse(value) == null ? '请输入有效的六位颜色值' : null,
            onSaved: (value) => Navigator.pop(context, parse(value)),
            onFieldSubmitted: (_) {
              if (form.currentState!.validate()) form.currentState!.save();
            },
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(context, defaultAccent), child: const Text('恢复默认')),
          FilledButton(onPressed: () {
            if (form.currentState!.validate()) form.currentState!.save();
          }, child: const Text('应用')),
        ],
      ),
    );
    if (color != null) setAccent(color);
  }

  Widget settingsPage() => CatalogEntrance(
    builder: (context, entrance) {
    final cards = <Widget>[
      if (backend.usesNativeDesktop)
        Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: surface(
            ListTile(
              title: const Text('游戏文件与补丁检查'),
              subtitle: const Text('核对游戏版本、原值参考和已登记补丁的完整性。'),
              trailing: OutlinedButton(
                onPressed: ready && !busy ? () => inspectCatalog(attachments: false) : null,
                child: const Text('检查'),
              ),
            ),
          ),
        ),
      surface(
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '版本更新 · $appVersion',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 12),
            Text(updateStatus),
            const SizedBox(height: 12),
            FilledButton.tonalIcon(
              onPressed: checkingUpdates ? null : () => checkUpdates(),
              icon: const Icon(Icons.system_update_alt),
              label: Text(checkingUpdates ? '正在检查' : '检查更新'),
            ),
            if (checkingUpdates)
              const Padding(
                padding: EdgeInsets.only(top: 12),
                child: LinearProgressIndicator(),
              ),
          ],
        ),
      ),
      const SizedBox(height: 16),
      if (backend.usesNativeDesktop)
        surface(
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('MCP 接口'),
                subtitle: const Text('开启后可通过本机连接读取和编辑当前会话。连接配置包含本次会话的访问凭据。'),
                value: mcpEnabled,
                onChanged: mcpBusy ? null : toggleMcp,
              ),
              OutlinedButton.icon(
                onPressed: mcpEnabled && !mcpBusy ? copyMcp : null,
                icon: const Icon(Icons.copy_outlined),
                label: const Text('复制 MCP 配置'),
              ),
            ],
          ),
        ),
      if (backend.usesNativeDesktop) const SizedBox(height: 16),
      surface(
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '日志与诊断',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('诊断模式'),
              subtitle: const Text('额外记录接口耗时和安装阶段；不记录输入的文字或预设内容。设置在重启后保留。'),
              value: backend.diagnostics.enabled,
              onChanged: (v) {
                setState(() => backend.diagnostics.enabled = v);
                backend.diagnostics.record('诊断模式${v ? '开启' : '关闭'}');
                saveStyle();
              },
            ),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              children: [
                FilledButton.tonalIcon(
                  onPressed: diagnosing
                      ? null
                      : () async {
                          setState(() => diagnosing = true);
                          try {
                            final text = await backend.diagnose();
                            if (mounted)
                              setState(() => diagnosticResult = text);
                          } catch (e) {
                            showError(e);
                          } finally {
                            if (mounted) setState(() => diagnosing = false);
                          }
                        },
                  icon: const Icon(Icons.health_and_safety_outlined),
                  label: const Text('运行只读诊断'),
                ),
                OutlinedButton.icon(
                  onPressed: () async {
                    try {
                      final saved = await exportDiagnostics(backend);
                      if (saved && mounted)
                        setState(() => diagnosticResult = '诊断日志已导出。');
                    } catch (e) {
                      showError('日志导出失败：$e');
                    }
                  },
                  icon: const Icon(Icons.download_outlined),
                  label: const Text('导出诊断日志'),
                ),
              ],
            ),
            if (diagnosing) const LinearProgressIndicator(),
            if (diagnosticResult.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(diagnosticResult),
              ),
            const SizedBox(height: 8),
            const Text('检查运行文件、数据引擎和游戏目录，不写入游戏。导出内容含运行环境、错误和最近启动日志，不会自动上传。'),
          ],
        ),
      ),
      const SizedBox(height: 16),
      surface(
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '自定义背景',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 12),
            const Text('选择本地图片，裁剪填满工作台；浅色模式使用浅色遮罩，深色模式使用深色遮罩，保持文字清晰。'),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              children: [
                FilledButton.tonalIcon(
                  onPressed: () async {
                    try {
                      final image = await openFile(
                        acceptedTypeGroups: [
                          const XTypeGroup(
                            label: '背景图片',
                            extensions: ['png', 'jpg', 'jpeg', 'webp', 'bmp'],
                          ),
                        ],
                      );
                      if (image == null || !mounted) return;
                      // Decode before accepting, so an invalid file cannot blank the background.
                      final bytes = await image.readAsBytes();
                      final codec = await ui.instantiateImageCodec(bytes);
                      final frame = await codec.getNextFrame();
                      frame.image.dispose();
                      codec.dispose();
                      if (!mounted) return;
                      setState(() => backgroundPath = image.path);
                      saveStyle();
                    } catch (e) {
                      showError('图片读取失败：$e');
                    }
                  },
                  icon: const Icon(Icons.image_outlined),
                  label: const Text('选择图片'),
                ),
                OutlinedButton(
                  onPressed: backgroundPath.isEmpty
                      ? null
                      : () {
                          setState(() => backgroundPath = '');
                          saveStyle();
                        },
                  child: const Text('恢复默认背景'),
                ),
              ],
            ),
            if (backgroundPath.isNotEmpty)
              Text(
                backgroundPath,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            Text('背景遮罩 · ${(backgroundDim * 100).round()}%'),
            PreferenceSlider(
              value: backgroundDim,
              min: 0,
              max: .9,
              onChanged: (v) {
                setState(() => backgroundDim = v);
                saveStyle();
              },
            ),
          ],
        ),
      ),
      const SizedBox(height: 16),
      surface(
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '外观与阅读',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 16),
            themeControl((onChange) => SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('深色模式'),
              subtitle: const Text('切换整个工作台的背景和文字颜色'),
              value: dark,
              onChanged: onChange,
            ), trailing: true),
            const SizedBox(height: 16),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('强调色'),
              subtitle: Text(accentHex(accent)),
              leading: CircleAvatar(backgroundColor: accent, radius: 12),
              trailing: accentMenu(),
            ),
            const SizedBox(height: 16),
            const Text('卡片材质'),
            const SizedBox(height: 8),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'liquid', label: Text('液态玻璃')),
                ButtonSegment(value: 'frosted', label: Text('磨砂')),
                ButtonSegment(value: 'clear', label: Text('通透')),
              ],
              selected: {material},
              onSelectionChanged: (v) {
                setState(() => material = v.first);
                saveStyle();
              },
            ),
            const SizedBox(height: 16),
            Text('字体大小 · ${fontSize.round()}'),
            PreferenceSlider(
              value: fontSize,
              min: 12,
              max: 24,
              divisions: 12,
              onChanged: (v) {
                setState(() => fontSize = v);
                saveStyle();
              },
            ),
            Text('磨砂模糊 · ${blur.round()}'),
            PreferenceSlider(
              value: blur,
              min: 0,
              max: 40,
              onChanged: material == 'frosted'
                  ? (v) {
                      setState(() => blur = v);
                      saveStyle();
                    }
                  : null,
            ),
            Text('卡片底色不透明度 · ${(opacity * 100).round()}%'),
            PreferenceSlider(
              value: opacity,
              min: .08,
              max: .85,
              onChanged: material != 'liquid'
                  ? (v) {
                      setState(() => opacity = v);
                      saveStyle();
                    }
                  : null,
            ),
            const Text('松开滑条应用外观，设置自动保存，重启后保留。'),
          ],
        ),
      ),
      const SizedBox(height: 16),
      surface(
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '程序与游戏路径',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 12),
            const Text('$appVersion · Rust 数据引擎'),
            const Text('界面字体：MiSans（小米），保留中英文及常用符号。'),
            const Text('游戏路径由现有核心自动检测，不固定其他人的安装目录。'),
            const SizedBox(height: 8),
            const SelectableText('https://github.com/127MU/SHODAN-Stat-Editor'),
          ],
        ),
      ),
    ];
    var index = 0;
    return ListView(children: [
      for (final card in cards)
        card is SizedBox ? card : CatalogEntrance.card(entrance, index++, card),
    ]);
    },
  );
  GlassAppearance get appearance =>
      GlassAppearance(mode: material, dark: dark, blur: blur, opacity: opacity);
  Widget surface(Widget child, {Key? key, bool grouped = true}) => appearance.wrap(
    Padding(padding: const EdgeInsets.all(20), child: child),
    key: key,
    grouped: grouped,
  );

  Widget field(Map row) => surface(
    Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                row['label'] ?? '',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            if (row['help'] is List && (row['help'] as List).isNotEmpty)
              Tooltip(
                message: (row['help'] as List).join('\n'),
                child: const Icon(Icons.help_outline, size: 18),
              ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          '原值 ${displayNumber(row['default_text'])}',
          style: TextStyle(
            fontSize: 12,
            color: dark ? Colors.white70 : Colors.black54,
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: row['code'] == true
                  ? OutlinedButton(
                      onPressed: () => code(row),
                      child: Text('${row['text']} · 录入指令'),
                    )
                  : row['flag'] == true
                  ? SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(row['value'] == 1 ? '开' : '关'),
                      value: (row['value'] as num? ?? 0) >= .5,
                      onChanged: (on) =>
                          edit('set', [row['id'], on ? '1' : '0']),
                    )
                  : row['choice'] == true
                  ? OutlinedButton(
                      onPressed: () => choices(row),
                      child: Text(row['choice_name'] ?? '选择条目'),
                    )
                  : ValueInput(
                      key: ValueKey('${current?['id']}:${row['id']}'),
                      value: '${row['text'] ?? row['value']}',
                      onSave: (value) async {
                        if (!await edit('set', [row['id'], value]))
                          throw StateError('保存失败');
                      },
                    ),
            ),
            const SizedBox(width: 8),
            IconButton(
              tooltip: '恢复原值',
              onPressed: () => edit('reset', [row['id']]),
              icon: const Icon(Icons.restore),
            ),
          ],
        ),
        if ((row['inline_note'] ?? '').toString().isNotEmpty)
          Text(row['inline_note']),
        if (row['changed'] == true) const Text('已修改'),
        if (row['shared_pending'] == true ||
            (row['shared'] is List && (row['shared'] as List).isNotEmpty))
          TextButton(
            onPressed: () async {
              List shared;
              try {
                final result = row['shared_pending'] == true
                    ? await backend.call('shared', [row['id']])
                    : row['shared'];
                shared = result is List ? result : [];
                if (!mounted) return;
              } catch (e) {
                showError(e);
                return;
              }
              final item = await showMotionDialog<Map>(
                context: navigator.currentContext!,
                builder: (ctx) => GlassDialog(
                  title: const Text('共享影响'),
                  content: SizedBox(
                    width: 600,
                    height: 360,
                    child: ListView(
                      children: [
                        if (shared.isEmpty)
                          const ListTile(title: Text('未发现其他共享此参数的条目')),
                        for (final owner in shared)
                          ListTile(
                            title: Text('${owner['name'] ?? owner['id']}'),
                            onTap: () => Navigator.pop(ctx, owner),
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
              if (item != null && mounted) {
                Navigator.pop(navigator.currentContext!);
                await select(item);
              }
            },
            child: Text(
              row['shared_pending'] == true
                  ? '查看共享影响'
                  : '共享影响 ${(row['shared'] as List).length} 项',
            ),
          ),
      ],
    ),
  );
  Widget parameterPage(Animation<double> entrance) {
    final sections = <String, int>{};
    for (final r in rows.where(matchesParameter)) {
      sections.update(
        '${r['section'] ?? '参数'}',
        (count) => count + 1,
        ifAbsent: () => 1,
      );
    }
    final categories = sections.keys.toList();
    return CustomScrollView(
      key: PageStorageKey('parameter-categories:${current?['id']}'),
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: EditorTools(
              key: ValueKey('editor-tools:${current?['id']}'),
              backend: backend,
              revision: rowRevision,
              onRefresh: refreshCurrent,
              onError: showError,
              onRecord: select,
              onPresets: equipmentPresets,
              onlyChanged: onlyChanged,
              onOnlyChanged: (value) => setState(() => onlyChanged = value),
            ),
          ),
        ),
        if (tab == 'Armors')
          SliverToBoxAdapter(
            child: ArmorItem(
              key: ValueKey(current?['id']),
              backend: backend,
              hash: current!['id'],
              onError: showError,
            ),
          ),
        SliverToBoxAdapter(
          child: GameTextPanel(
            key: ValueKey('text:${current?['id']}'),
            backend: backend,
            onError: showError,
          ),
        ),
        SliverGrid(
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 4,
            mainAxisSpacing: 16,
            crossAxisSpacing: 16,
            mainAxisExtent: 190 * fontSize / 14,
          ),
          delegate: SliverChildListDelegate([
            for (final (index, section) in categories.indexed)
              CatalogEntrance.card(
                entrance,
                index,
                columns: 4,
                count: categories.length,
                surface(
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '$section',
                      style: const TextStyle(
                        fontSize: 19,
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 8),
                    Text('${sections[section]} 项参数'),
                    const Spacer(),
                    Align(
                      alignment: Alignment.centerRight,
                      child: Builder(builder: (source) => FilledButton.tonal(
                        onPressed: () => openSection('$section', source),
                        child: const Text('打开'),
                      )),
                    ),
                  ],
                ),
                key: ValueKey('section:$section'),
                ),
              ),
          ]),
        ),
      ],
    );
  }

  bool matchesParameter(dynamic row) =>
      (!onlyChanged || row['changed'] == true || row['patch_pending'] == true) &&
      (parameterQuery.isEmpty ||
          row.toString().toLowerCase().contains(parameterQuery));

  List<CatalogGroup> visibleCatalog() {
    final key = (items, tab, catalogQuery, catalogOnlyChanged);
    if (catalogViewKey != key) {
      catalogViewKey = key;
      catalogView = buildCatalogGroups(
        items,
        tab,
        query: catalogQuery,
        onlyChanged: catalogOnlyChanged,
      );
    }
    return catalogView;
  }

  Future<void> openSection(String section, BuildContext source) async {
    if (busy || activeSection != null) return;
    final ticket = epoch;
    activeSection = section;
    final token = sectionRequest = Object();
    final request = WidgetsBinding.instance.endOfFrame.then((_) async {
      if (!mounted || ticket != epoch || sectionRequest != token) return;
      final result = await backend.call('rows_section', [section]);
      if (!mounted || ticket != epoch || sectionRequest != token) return;
      if (result is! List) throw StateError('参数分类响应格式错误');
      final updated = {for (final row in result) row['id']: row};
      rows = [for (final row in rows) updated[row['id']] ?? row];
    });
    await showMotionDialog<void>(
      context: navigator.currentContext!,
      source: source,
      builder: (ctx) => GlassDialog(
        title: Text('${current?['name']} · $section'),
        content: SizedBox(
          width: 1300,
          height: MediaQuery.sizeOf(ctx).height * .65,
          child: FutureBuilder<void>(future: request, builder: (context, snapshot) {
            if (snapshot.hasError) return SelectableText('${snapshot.error}');
            if (snapshot.connectionState != ConnectionState.done) {
              return const Align(alignment: Alignment.topLeft, child: Text('正在读取参数…'));
            }
            return ValueListenableBuilder<int>(
            valueListenable: rowRevision,
            builder: (context, _, _) {
              const columns = 4;
              final visible = rows
                  .where((r) =>
                      (r['section'] ?? '参数') == section && matchesParameter(r))
                  .toList();
              return ListView.builder(
                itemCount: (visible.length + columns - 1) ~/ columns,
                itemBuilder: (context, index) => Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Row(
                    spacing: 16,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: List.generate(columns, (column) {
                      final i = index * columns + column;
                      return Expanded(
                        key: i < visible.length
                            ? ValueKey(visible[i]['id'])
                            : null,
                        child: i < visible.length
                            ? field(visible[i] as Map)
                            : const SizedBox.shrink(),
                      );
                    }),
                  ),
                ),
              );
            },
            );
          }),
        ),
        actions: [
          TextButton(
            onPressed: () {
              FocusScope.of(ctx).unfocus();
              Navigator.pop(ctx);
            },
            child: const Text('关闭'),
          ),
        ],
      ),
    );
    if (sectionRequest == token) {
      sectionRequest = null;
      activeSection = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = ThemeData(
      useMaterial3: true,
      brightness: dark ? Brightness.dark : Brightness.light,
      colorSchemeSeed: accent,
      fontFamily: 'MiSans',
      extensions: [appearance],
    );
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: theme.copyWith(textTheme: theme.textTheme),
      themeAnimationDuration: Duration.zero,
      navigatorKey: navigator,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(fontSize / 14)),
        child: Stack(
          fit: StackFit.expand,
          children: [
            RepaintBoundary(
              key: themeCapture,
              child: BackdropGroup(
          child: Stack(
            fit: StackFit.expand,
            children: [
              RepaintBoundary(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    image: backgroundPath.isEmpty
                        ? null
                        : DecorationImage(
                            image: FileImage(File(backgroundPath)),
                            fit: BoxFit.cover,
                            colorFilter: ColorFilter.mode(
                              (dark ? Colors.black : Colors.white).withValues(
                                alpha: backgroundDim,
                              ),
                              BlendMode.srcOver,
                            ),
                            onError: (_, _) {
                              if (mounted)
                                setState(() {
                                  backgroundPath = '';
                                  status = '背景图片无法读取，已使用默认背景';
                                });
                            },
                          ),
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: dark
                          ? [
                              const Color(0xff101427),
                              const Color(0xff292038),
                              const Color(0xff153033),
                            ]
                          : [
                              const Color(0xffdce9ff),
                              const Color(0xfff4dfef),
                              const Color(0xffdef4ee),
                            ],
                    ),
                  ),
                ),
              ),
              DesktopFrame(
                enabled: widget.persistAppearance,
                onClose: shutdown,
                onCloseError: showError,
                child: child!,
              ),
            ],
          ),
              ),
            ),
            if (themeSnapshot case final snapshot?)
              IgnorePointer(
                child: TweenAnimationBuilder<double>(
                  tween: Tween(begin: 0, end: 1),
                  duration: WorkbenchMotion.reveal,
                  curve: dark ? Curves.easeInOutQuart : Curves.easeInOutQuint,
                  onEnd: finishThemeReveal,
                  builder: (_, progress, _) => CustomPaint(
                    painter: ThemeReveal(snapshot, themeOrigin, progress, reverse: !dark),
                  ),
                ),
              ),
          ],
        ),
      ),
      home: Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
                child: Row(
                  children: [
                    SizedBox(
                      width: 220 + (fontSize - 14).clamp(0, 10) * 5,
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: surface(
                          Column(
                            children: [
                              Image.asset(
                                'assets/shodan.png',
                                width: 48,
                                height: 48,
                              ),
                              const Text(
                                'SHODAN',
                                style: TextStyle(
                                  fontSize: 25,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const Text(appVersion),
                              const SizedBox(height: 20),
                              Expanded(
                                child: ListView(
                                  children: [
                                    for (final entry in navigation.entries)
                                      ListTile(
                                        key: ValueKey(
                                          'navigation-${entry.key}',
                                        ),
                                        selected:
                                            tab == entry.key ||
                                            peers(entry.key).contains(tab),
                                        visualDensity: VisualDensity.compact,
                                        contentPadding:
                                            const EdgeInsets.symmetric(
                                              horizontal: 10,
                                            ),
                                        minLeadingWidth: 24,
                                        horizontalTitleGap: 8,
                                        leading: Icon(entry.value.$2, size: 20),
                                        title: Text(
                                          entry.value.$1,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                        onTap: ready && !busy
                                            ? () => load(entry.key)
                                            : null,
                                      ),
                                  ],
                                ),
                              ),
                              themeControl((onChange) => IconButton(
                                tooltip: '切换深浅色',
                                onPressed: () => onChange(!dark),
                                icon: AnimatedSwitcher(
                                  duration: WorkbenchMotion.duration(context, WorkbenchMotion.feedback),
                                  switchInCurve: WorkbenchMotion.standard,
                                  switchOutCurve: WorkbenchMotion.exit,
                                  transitionBuilder: (child, animation) => FadeTransition(
                                    opacity: animation,
                                    child: RotationTransition(
                                      turns: animation.drive(Tween(begin: -.10, end: 0.0)),
                                      child: child,
                                    ),
                                  ),
                                  child: Icon(
                                    dark ? Icons.light_mode : Icons.dark_mode,
                                    key: ValueKey(dark),
                                  ),
                                ),
                              )),
                            ],
                          ),
                          grouped: false,
                        ),
                      ),
                    ),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                if (current != null)
                                  IconButton(
                                    onPressed: busy ? null : backToCatalog,
                                    icon: const Icon(Icons.arrow_back),
                                  ),
                                Expanded(
                                  child: Text(
                                    current?['name'] ?? tabs[tab]!,
                                    style: const TextStyle(
                                      fontSize: 28,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                                Builder(builder: (source) => FilledButton.icon(
                                  onPressed: ready && !busy ? () => install(source) : null,
                                  icon: const Icon(Icons.save_outlined),
                                  label: const Text('写入游戏'),
                                )),
                                const SizedBox(width: 8),
                                OutlinedButton(
                                  onPressed: ready && !busy
                                      ? restoreGame
                                      : null,
                                  child: const Text('恢复原版'),
                                ),
                              ],
                            ),
                            const SizedBox(height: 20),
                            if (current == null && peers(tab).length > 1)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 16),
                                child: Wrap(
                                  spacing: 8,
                                  runSpacing: 8,
                                  children: [
                                    for (final key in peers(tab))
                                      ChoiceChip(
                                        label: Text(
                                          key == 'Armors' ? '护甲装备' : tabs[key]!,
                                        ),
                                        selected: tab == key,
                                        onSelected: busy
                                            ? null
                                            : (_) => load(key),
                                      ),
                                    if (tab == 'Attachments' && backend.usesNativeDesktop)
                                      OutlinedButton.icon(
                                        onPressed: busy ? null : () => inspectCatalog(attachments: true),
                                        icon: const Icon(Icons.search),
                                        label: const Text('配件选项目录'),
                                      ),
                                  ],
                                ),
                              ),
                            if (![
                              'Settings',
                              'Tweaks',
                              'Presets',
                            ].contains(tab))
                              TextField(
                                key: ValueKey(
                                  current == null
                                      ? 'catalog-search'
                                      : 'parameter-search',
                                ),
                                controller: search,
                                decoration: InputDecoration(
                                  prefixIcon: const Icon(Icons.search),
                                  hintText: current == null
                                      ? '搜索名称、型号或 ID'
                                      : '查找参数',
                                ),
                                onChanged: (value) =>
                                    setState(() => query = value.toLowerCase()),
                              ),
                            if (current == null &&
                                ![
                                  'Settings',
                                  'Tweaks',
                                  'Presets',
                                  'Armor',
                                ].contains(tab))
                              Padding(
                                padding: const EdgeInsets.only(top: 12),
                                child: Align(
                                  alignment: Alignment.centerLeft,
                                  child: FilterChip(
                                    label: const Text('仅已修改'),
                                    selected: catalogOnlyChanged,
                                    onSelected: busy
                                        ? null
                                        : (value) => setState(
                                            () => catalogOnlyChanged = value,
                                          ),
                                  ),
                                ),
                              ),
                            const SizedBox(height: 20),
                            if (busy) const LinearProgressIndicator(),
                            Expanded(
                              child: ClipRect(
                                child: TweenAnimationBuilder<double>(
                                  key: ValueKey(
                                    '$tab:${current?["id"] ?? "catalog"}',
                                  ),
                                  duration: WorkbenchMotion.duration(context, WorkbenchMotion.page),
                                  curve: WorkbenchMotion.enter,
                                  tween: Tween(begin: pageOffset, end: 0),
                                  builder: (context, dy, child) =>
                                      child is CatalogEntrance ? child : Transform.translate(
                                        offset: Offset(dy, dy.abs() * .22),
                                        child: child,
                                      ),
                                  child: tab == 'Settings'
                                      ? settingsPage()
                                      : tab == 'Tweaks'
                                      ? GameTweaksPage(
                                          backend: backend,
                                          onError: showError,
                                          surface: (child) => surface(child),
                                        )
                                      : tab == 'Armor'
                                      ? ArmorPage(
                                          query: query,
                                          backend: backend,
                                          onError: showError,
                                          surface: (child) => surface(child),
                                        )
                                      : tab == 'Presets'
                                      ? PresetPage(
                                          backend: backend,
                                          onError: showError,
                                        )
                                      : current == null
                                      ? CatalogEntrance(
                                          key: ValueKey(items.isNotEmpty),
                                          builder: (context, entrance) {
                                            const columns = 4;
                                            final visible = visibleCatalog();
                                            return GridView.builder(
                                              gridDelegate:
                                                  SliverGridDelegateWithFixedCrossAxisCount(
                                                    crossAxisCount: columns,
                                                    mainAxisExtent:
                                                        170 * (fontSize / 14),
                                                    crossAxisSpacing: 16,
                                                    mainAxisSpacing: 16,
                                                  ),
                                              itemCount: visible.length,
                                              itemBuilder: (context, i) {
                                                final group = visible[i];
                                                return CatalogEntrance.card(
                                                  entrance,
                                                  i,
                                                  columns: columns,
                                                  count: visible.length,
                                                  surface(
                                                  Column(
                                                    crossAxisAlignment:
                                                        CrossAxisAlignment
                                                            .start,
                                                    children: [
                                                      Text(
                                                        group.name,
                                                        style: const TextStyle(
                                                          fontSize: 19,
                                                          fontWeight:
                                                              FontWeight.w600,
                                                        ),
                                                        maxLines: 2,
                                                        overflow: TextOverflow
                                                            .ellipsis,
                                                      ),
                                                      Text(
                                                        group.entries.length > 1
                                                            ? '${group.entries.length} 个关联条目${group.changed ? ' · 含修改' : ''}'
                                                            : group.changed
                                                            ? '已修改'
                                                            : '未修改',
                                                      ),
                                                      const Spacer(),
                                                      Align(
                                                        alignment: Alignment
                                                            .centerRight,
                                                        child: FilledButton.tonal(
                                                          onPressed: busy
                                                              ? null
                                                              : () =>
                                                                    openCatalogGroup(
                                                                      group,
                                                                      context,
                                                                    ),
                                                          child: Text(
                                                            group
                                                                        .entries
                                                                        .length >
                                                                    1
                                                                ? '选择打开'
                                                                : '打开',
                                                          ),
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                                  key: ValueKey(
                                                    'item:${group.id}',
                                                  ),
                                                  ),
                                                );
                                              },
                                            );
                                          },
                                        )
                                      : CatalogEntrance(
                                          builder: (context, entrance) => parameterPage(entrance),
                                        ),
                                ),
                              ),
                            ),
                            const SizedBox(height: 12),
                            Text(
                              status,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    styleTimer?.cancel();
    themeSnapshot?.dispose();
    rowRevision.dispose();
    catalogSearch.dispose();
    parameterSearch.dispose();
    backend.close().catchError((_) {});
    super.dispose();
  }
}

class ValueInput extends StatefulWidget {
  const ValueInput({super.key, required this.value, required this.onSave});
  final String value;
  final Future<void> Function(String) onSave;
  @override
  State<ValueInput> createState() => _ValueInputState();
}

class _ValueInputState extends State<ValueInput> {
  late final c = TextEditingController(text: displayNumber(widget.value));
  final focus = FocusNode();
  String saved = '';
  bool saving = false;
  bool queued = false;
  @override
  void initState() {
    super.initState();
    saved = c.text;
    focus.addListener(() {
      if (!focus.hasFocus) save();
    });
  }

  Future<void> save() async {
    if (saving) {
      queued = true;
      return;
    }
    if (c.text == saved) return;
    saving = true;
    do {
      queued = false;
      final value = c.text;
      try {
        await widget.onSave(value);
        saved = value;
      } catch (_) {
        if (mounted) c.text = saved;
        queued = false;
        break;
      }
    } while (mounted && queued && c.text != saved);
    if (mounted && c.text == saved) {
      c.text = displayNumber(saved);
      saved = c.text;
    }
    saving = false;
  }

  @override
  void didUpdateWidget(covariant ValueInput old) {
    super.didUpdateWidget(old);
    if (!saving && !focus.hasFocus && widget.value != old.value) {
      c.text = displayNumber(widget.value);
      saved = c.text;
    }
  }

  @override
  Widget build(BuildContext context) => TextField(
    controller: c,
    focusNode: focus,
    onSubmitted: (_) => save(),
    decoration: const InputDecoration(
      border: OutlineInputBorder(),
      isDense: true,
    ),
  );
  @override
  void dispose() {
    focus.dispose();
    c.dispose();
    super.dispose();
  }
}
