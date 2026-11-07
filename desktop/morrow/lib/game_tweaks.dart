import 'motion.dart';
import 'package:flutter/material.dart';
import 'backend.dart';
import 'glass_theme.dart';

class GameTweaksPage extends StatefulWidget {
  const GameTweaksPage({
    super.key,
    required this.backend,
    required this.onError,
    required this.surface,
  });
  final Backend backend;
  final void Function(Object) onError;
  final Widget Function(Widget) surface;
  @override
  State<GameTweaksPage> createState() => _GameTweaksPageState();
}

class _GameTweaksPageState extends State<GameTweaksPage> {
  Map tweaks = {}, ragdoll = {};
  bool loading = true, busy = false, checking = true;
  String patchStatus = '';
  @override
  void initState() {
    super.initState();
    load();
    preview();
  }

  Future<void> load() async {
    try {
      final value = await widget.backend.call('tweaks');
      if (mounted) setState(() => tweaks = value is Map ? value : {});
    } catch (e) {
      widget.onError(e);
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> preview() async {
    try {
      final value = await widget.backend.call('ragdoll_preview');
      if (mounted)
        setState(() {
          ragdoll = value is Map ? value : {};
          patchStatus = '${ragdoll['message'] ?? ''}';
        });
    } catch (e) {
      if (mounted) setState(() => patchStatus = '$e');
    } finally {
      if (mounted) setState(() => checking = false);
    }
  }

  Future<void> change(String key, bool on) async {
    setState(() => busy = true);
    try {
      final value = await widget.backend.call('tweaks', [key, on]);
      if (mounted) setState(() => tweaks = value as Map);
    } catch (e) {
      widget.onError(e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> patch(bool on) async {
    final yes = await showMotionDialog<bool>(
      context: context,
      builder: (ctx) => GlassDialog(
        title: Text(on ? '启用布娃娃优化（实验性）' : '恢复布娃娃优化'),
        content: Text('此操作会立即修改资源补丁，请先完全退出游戏。其他参数仍通过“写入游戏”生效。\n$patchStatus'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确认'),
          ),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    setState(() => checking = true);
    try {
      final message = await widget.backend.call('ragdoll_apply', [on]);
      if (!mounted) return;
      setState(() {
        ragdoll['enabled'] = on;
        patchStatus = '$message';
      });
    } catch (e) {
      widget.onError(e);
    } finally {
      if (mounted) setState(() => checking = false);
    }
  }

  @override
  Widget build(BuildContext context) => CatalogEntrance(
    builder: (context, entrance) {
      final cards = <Widget>[
        for (final entry in const [
          ('reticle', '瞄准显示', '狙击步枪第三人称准星', ''),
          (
            'bounce',
            '投掷行为',
            '策略球部署限制放宽',
            '解除部分战备只能在导航网格上部署的限制；岩石、高台及碰撞仍可能使策略球弹开，不保证任意表面粘附。',
          ),
          ('foliage', '射弹交互', '射弹穿过树冠与灌木', ''),
          ('vehicles', '载具配装', '允许携带多种同类载具', '放宽同类机甲、快速侦察车和坦克的配装数量限制。'),
        ])
          Padding(
            padding: const EdgeInsets.only(top: 16),
            child: widget.surface(
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    entry.$2,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(entry.$3),
                    subtitle: entry.$4.isEmpty ? null : Text(entry.$4),
                    value: tweaks[entry.$1] == true,
                    onChanged: loading || busy
                        ? null
                        : (on) => change(entry.$1, on),
                  ),
                ],
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.only(top: 16),
          child: widget.surface(
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (checking) const LinearProgressIndicator(),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('受击与布娃娃（实验性）'),
                  subtitle: Text(checking ? '正在核对资源与补丁…' : patchStatus),
                  value: ragdoll['enabled'] == true,
                  onChanged: checking || ragdoll['supported'] != true
                      ? null
                      : patch,
                ),
              ],
            ),
          ),
        ),
      ];
      return ListView(
        children: [
          const Text('调整普通开关后，点击“写入游戏”并重新启动游戏生效。'),
          if (loading || busy) const LinearProgressIndicator(),
          for (final (index, card) in cards.indexed)
            CatalogEntrance.card(entrance, index, card),
        ],
      );
    },
  );
}
