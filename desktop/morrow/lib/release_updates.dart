import 'dart:async';
import 'package:flutter/material.dart';
import 'backend.dart';
import 'glass_theme.dart';
import 'app_version.dart';

Future<Map<String, dynamic>> checkNativeRelease(Backend backend) async {
  await backend.nativeCall('update-start', {'current': appVersion});
  for (var attempt = 0; attempt < 180; attempt++) {
    final response = await backend.nativeCall('update-poll') as Map;
    if (response['pending'] != true) {
      final offer = response['offer'];
      if (offer is! Map) throw StateError('更新检查未返回发行版信息');
      return Map<String, dynamic>.from(offer);
    }
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }
  throw TimeoutException('更新检查超时，请稍后重试');
}

Future<void> showReleaseOffer(
  BuildContext context,
  Backend backend,
  Map offer,
) => showDialog<void>(
  context: context,
  builder: (context) => GlassDialog(
    title: Text('发现新版本 ${offer['version']}'),
    content: SizedBox(
      width: 680,
      height: 360,
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('当前版本：${offer['current']}'),
            const SizedBox(height: 16),
            SelectableText(
              (offer['notes'] as String?)?.isNotEmpty == true
                  ? offer['notes'] as String
                  : '此发行版没有填写更新日志，可点击“查看发行版”了解详情。',
            ),
            if (offer['mirror_notice'] is String) ...[
              const SizedBox(height: 16),
              Text(offer['mirror_notice'] as String),
            ],
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('稍后再说'),
      ),
      _ReleaseLink(
        backend: backend,
        url: offer['url'] as String?,
        label: '查看发行版',
      ),
      _ReleaseLink(
        backend: backend,
        url: offer['download_url'] as String?,
        label: '直接下载',
        primary: true,
      ),
    ],
  ),
);

class _ReleaseLink extends StatefulWidget {
  const _ReleaseLink({
    required this.backend,
    required this.url,
    required this.label,
    this.primary = false,
  });
  final Backend backend;
  final String? url;
  final String label;
  final bool primary;
  @override
  State<_ReleaseLink> createState() => _ReleaseLinkState();
}

class _ReleaseLinkState extends State<_ReleaseLink> {
  bool busy = false;
  String? error;
  Future<void> open() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.backend.nativeCall('update-open-link', {'url': widget.url});
    } catch (_) {
      if (mounted) setState(() => error = '链接打开失败，请稍后重试');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      if (widget.primary)
        FilledButton(
          onPressed: busy || widget.url == null ? null : open,
          child: Text(widget.label),
        )
      else
        OutlinedButton(
          onPressed: busy || widget.url == null ? null : open,
          child: Text(widget.label),
        ),
      if (error != null)
        Text(error!, style: Theme.of(context).textTheme.bodySmall),
    ],
  );
}
