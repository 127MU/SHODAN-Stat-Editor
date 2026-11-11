import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'wallpaper_engine.dart';
import 'window_activity.dart';

class WorkbenchBackground extends StatelessWidget {
  const WorkbenchBackground({
    super.key,
    required this.file,
    required this.preview,
    required this.dark,
    required this.dim,
    required this.onVideoError,
    this.onImageError,
  });

  final String file, preview;
  final bool dark;
  final double dim;
  final VoidCallback onVideoError;
  final VoidCallback? onImageError;

  Widget image(String path, {VoidCallback? onError}) => Image.file(
    File(path),
    fit: BoxFit.cover,
    errorBuilder: (_, _, _) {
      if (onError != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) => onError());
      }
      return const SizedBox.shrink();
    },
  );

  @override
  Widget build(BuildContext context) {
    final scene = isSceneBackground(file);
    final animated = scene || isVideoBackground(file);
    return RepaintBoundary(
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: dark
                ? const [
                    Color(0xff101427),
                    Color(0xff292038),
                    Color(0xff153033),
                  ]
                : const [
                    Color(0xffdce9ff),
                    Color(0xfff4dfef),
                    Color(0xffdef4ee),
                  ],
          ),
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (file.isNotEmpty)
              ColorFiltered(
                colorFilter: ColorFilter.mode(
                  (dark ? Colors.black : Colors.white).withValues(alpha: dim),
                  BlendMode.srcATop,
                ),
                child: animated
                    ? _VideoWallpaper(
                        key: ValueKey(file),
                        file: file,
                        scene: scene,
                        placeholder: preview.isEmpty
                            ? const SizedBox.shrink()
                            : image(preview),
                        onError: onVideoError,
                      )
                    : image(file, onError: onImageError),
              ),
          ],
        ),
      ),
    );
  }
}

class _VideoWallpaper extends StatefulWidget {
  const _VideoWallpaper({
    super.key,
    required this.file,
    required this.scene,
    required this.placeholder,
    required this.onError,
  });

  final String file;
  final bool scene;
  final Widget placeholder;
  final VoidCallback onError;

  @override
  State<_VideoWallpaper> createState() => _VideoWallpaperState();
}

class _VideoWallpaperState extends State<_VideoWallpaper>
    with WidgetsBindingObserver {
  static const channel = MethodChannel('shodan/wallpaper-video');
  int? textureId;
  Size? frameSize;
  Timer? pollTimer;
  bool visible = true;
  bool failed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    windowResizing.addListener(updateVisibility);
    visible = shouldPlay;
    unawaited(open());
  }

  Future<void> open() async {
    try {
      if (!Platform.isWindows) throw UnsupportedError('Windows video only');
      final engine = widget.scene ? await findWallpaperEngineInstall() : null;
      if (!mounted) return;
      if (widget.scene && engine == null) {
        throw StateError('Wallpaper Engine installation unavailable');
      }
      final id = await channel.invokeMethod<int>(
        widget.scene ? 'openScene' : 'open',
        {'path': widget.file, if (engine != null) 'engine': engine},
      );
      if (id == null) throw StateError('Video texture unavailable');
      if (!mounted) {
        await close(id);
        return;
      }
      textureId = id;
      await setVisible(id);
      await poll(id);
    } catch (_) {
      reportFailure();
    }
  }

  Future<void> poll(int id) async {
    if (!mounted || textureId != id) return;
    try {
      final state = await channel.invokeMapMethod<String, Object?>('status', {
        'id': id,
      });
      if (!mounted || textureId != id) return;
      if (state == null || state['failed'] == true) {
        reportFailure();
        return;
      }
      final width = state['width'] as int;
      final height = state['height'] as int;
      if (width > 0 && height > 0) {
        final size = Size(width.toDouble(), height.toDouble());
        if (size != frameSize) setState(() => frameSize = size);
      }
      pollTimer = Timer(
        Duration(milliseconds: frameSize == null ? 100 : 1500),
        () => unawaited(poll(id)),
      );
    } catch (_) {
      reportFailure();
    }
  }

  void reportFailure() {
    if (!mounted || failed) return;
    setState(() => failed = true);
    final id = textureId;
    textureId = null;
    pollTimer?.cancel();
    if (id != null) unawaited(close(id));
    widget.onError();
  }

  static bool _isVisible(AppLifecycleState? state) =>
      state == null ||
      state == AppLifecycleState.resumed ||
      state == AppLifecycleState.inactive;

  bool get shouldPlay =>
      !windowResizing.value &&
      _isVisible(WidgetsBinding.instance.lifecycleState);

  Future<void> setVisible(int id) async {
    try {
      await channel.invokeMethod<void>('visible', {'id': id, 'value': visible});
    } catch (_) {
      if (textureId == id) reportFailure();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) =>
      updateVisibility();

  void updateVisibility() {
    final next = shouldPlay;
    if (next == visible) return;
    visible = next;
    if (textureId case final id?) unawaited(setVisible(id));
  }

  @override
  Widget build(BuildContext context) {
    final size = frameSize;
    final id = textureId;
    if (size == null || id == null || failed) return widget.placeholder;
    return ClipRect(
      child: FittedBox(
        fit: BoxFit.cover,
        child: SizedBox(
          width: size.width,
          height: size.height,
          child: Texture(textureId: id),
        ),
      ),
    );
  }

  Future<void> close(int id) async {
    try {
      await channel.invokeMethod<void>('close', {'id': id});
    } catch (_) {
      // The engine can already be closing.
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    windowResizing.removeListener(updateVisibility);
    pollTimer?.cancel();
    if (textureId case final id?) unawaited(close(id));
    textureId = null;
    super.dispose();
  }
}
