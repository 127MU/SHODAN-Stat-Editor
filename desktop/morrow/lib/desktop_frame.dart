import 'window_activity.dart';
// Adapted from Morrow's desktop_frame.dart (AGPL-3.0); see MORROW-LICENSE.
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

Future<void> initializeDesktopFrame() async {
  if (!Platform.isWindows) return;
  await windowManager.ensureInitialized();
  await windowManager.setAsFrameless();
  await windowManager.setResizable(true);
  await windowManager.setMaximizable(true);
  await windowManager.setMinimizable(true);
  await windowManager.setMinimumSize(const Size(1000, 700));
  await windowManager.setSize(const Size(1360, 900));
  await windowManager.center();
  await windowManager.setAlwaysOnTop(false);
  await windowManager.setPreventClose(true);
}

class DesktopFrame extends StatefulWidget {
  const DesktopFrame({
    super.key,
    required this.child,
    required this.onClose,
    required this.onCloseError,
    this.enabled = true,
  });
  final Widget child;
  final Future<void> Function() onClose;
  final void Function(Object) onCloseError;
  final bool enabled;
  @override
  State<DesktopFrame> createState() => _DesktopFrameState();
}

class _DesktopFrameState extends State<DesktopFrame> with WindowListener {
  bool closing = false, maximized = false;
  int maximizeRevision = 0;
  @override
  void initState() {
    super.initState();
    if (widget.enabled && Platform.isWindows) {
      windowManager.addListener(this);
      refreshMaximized();
    }
  }

  Future<void> refreshMaximized() async {
    final revision = ++maximizeRevision;
    final value = await windowManager.isMaximized();
    if (mounted && revision == maximizeRevision && value != maximized) {
      setState(() => maximized = value);
    }
  }

  @override
  void onWindowMaximize() {
    windowResizing.value = false;
    maximizeRevision++;
    if (mounted) setState(() => maximized = true);
  }

  @override
  void onWindowUnmaximize() {
    windowResizing.value = false;
    maximizeRevision++;
    if (mounted) setState(() => maximized = false);
  }

  @override
  void onWindowRestore() {
    windowResizing.value = false;
    refreshMaximized();
  }

  @override
  void onWindowResize() {
    if (!windowResizing.value) windowResizing.value = true;
  }

  @override
  void onWindowResized() {
    if (windowResizing.value) windowResizing.value = false;
  }

  @override
  void onWindowClose() async {
    if (closing) return;
    closing = true;
    FocusManager.instance.primaryFocus?.unfocus();
    try {
      const channel = MethodChannel('shodan/window');
      await channel.invokeMethod<void>('hideNow');
      // Only drain work already scheduled by auto-save. No new save or full
      // engine flush is started from the close action.
      try {
        await widget.onClose().timeout(const Duration(seconds: 1));
      } catch (e) {
        stderr.writeln('退出清理：$e');
      }
      await Future<void>.delayed(const Duration(milliseconds: 16));
      await channel.invokeMethod<void>('closeNow');
    } catch (e) {
      if (mounted) {
        setState(() => closing = false);
        widget.onCloseError(e);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled || !Platform.isWindows) return widget.child;
    return Overlay.wrap(
      child: DragToResizeArea(
        resizeEdgeSize: maximized ? 0 : 7,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(maximized ? 0 : 14),
          child: Column(
            children: [
              Material(
                color: Theme.of(
                  context,
                ).colorScheme.surface.withValues(alpha: .58),
                child: SizedBox(
                  height: 44,
                  child: Row(
                    children: [
                      Expanded(
                        child: DragToMoveArea(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            child: Row(
                              children: [
                                Image.asset(
                                  'assets/shodan.png',
                                  width: 24,
                                  height: 24,
                                ),
                                const SizedBox(width: 10),
                                const Text('SHODAN 数值编辑器'),
                                if (closing)
                                  const Padding(
                                    padding: EdgeInsets.only(left: 16),
                                    child: Text('正在退出…'),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: '最小化',
                        onPressed: closing
                            ? null
                            : () => windowManager.minimize(),
                        icon: const Icon(Icons.remove),
                      ),
                      IconButton(
                        tooltip: maximized ? '还原窗口' : '最大化',
                        onPressed: closing
                            ? null
                            : () async {
                                if (await windowManager.isMaximized()) {
                                  await windowManager.unmaximize();
                                } else {
                                  await windowManager.maximize();
                                }
                              },
                        icon: Icon(
                          maximized ? Icons.filter_none : Icons.crop_square,
                          size: 20,
                        ),
                      ),
                      IconButton(
                        tooltip: '关闭',
                        onPressed: closing ? null : () => windowManager.close(),
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                ),
              ),
              Expanded(child: widget.child),
            ],
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    windowResizing.value = false;
    if (widget.enabled && Platform.isWindows)
      windowManager.removeListener(this);
    super.dispose();
  }
}
