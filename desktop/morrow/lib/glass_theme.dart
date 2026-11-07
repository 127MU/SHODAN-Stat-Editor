import 'package:flutter/material.dart';
import 'motion.dart';
import 'third_party/liquid_glass.dart';
import 'window_activity.dart';

@immutable
class GlassAppearance extends ThemeExtension<GlassAppearance> {
  const GlassAppearance({
    required this.mode,
    required this.dark,
    required this.blur,
    required this.opacity,
  });
  final String mode;
  final bool dark;
  final double blur, opacity;
  static GlassAppearance of(BuildContext context) =>
      Theme.of(context).extension<GlassAppearance>() ??
      GlassAppearance(
        mode: 'liquid',
        dark: Theme.of(context).brightness == Brightness.dark,
        blur: 18,
        opacity: .3,
      );
  Widget wrap(
    Widget child, {
    Key? key,
    bool grouped = true,
    bool inTransition = false,
  }) => ValueListenableBuilder<bool>(
    key: key,
    valueListenable: windowResizing,
    child: child,
    builder: (context, resizing, child) {
      return LiquidGlassSurface(
        liveResize: resizing,
        grouped: grouped,
        inTransition:
            inTransition ||
            (_DialogPaintMode.maybeOf(context)?.moving ?? false),
        material: mode == 'liquid'
            ? null
            : GlassMaterial(
                blur: mode == 'frosted' ? blur : 0,
                liquid: 0,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(22),
                  color: (dark ? const Color(0xff20243c) : Colors.white)
                      .withValues(alpha: opacity),
                  border: Border.all(
                    color: dark ? Colors.white24 : Colors.white70,
                  ),
                ),
              ),
        tint: dark ? const Color(0xff293044) : const Color(0xffe6ecff),
        dark: dark,
        borderRadius: BorderRadius.circular(22),
        readable: true,
        child: child!,
      );
    },
  );
  @override
  GlassAppearance copyWith({
    String? mode,
    bool? dark,
    double? blur,
    double? opacity,
  }) => GlassAppearance(
    mode: mode ?? this.mode,
    dark: dark ?? this.dark,
    blur: blur ?? this.blur,
    opacity: opacity ?? this.opacity,
  );
  @override
  GlassAppearance lerp(covariant GlassAppearance? other, double t) =>
      other == null
      ? this
      : t < .5
      ? this
      : other;
}

class GlassPanel extends StatelessWidget {
  const GlassPanel({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => GlassAppearance.of(context).wrap(child);
}

class GlassDialog extends StatelessWidget {
  const GlassDialog({super.key, this.title, this.content, this.actions});
  final Widget? title, content;
  final List<Widget>? actions;
  @override
  Widget build(BuildContext context) {
    final requested = content is SizedBox ? (content as SizedBox).width : null;
    final animation =
        ModalRoute.of(context)?.animation ?? kAlwaysCompleteAnimation;
    final animate = !MediaQuery.disableAnimationsOf(context);
    Widget reveal(Widget child, double start, double end, double distance) {
      if (!animate) return child;
      return AnimatedBuilder(
        animation: animation,
        child: child,
        builder: (context, child) {
          final progress = Interval(
            start,
            end,
            curve: WorkbenchMotion.enter,
          ).transform(animation.value);
          return Transform.translate(
            offset: Offset(0, (1 - progress) * distance),
            child: child,
          );
        },
      );
    }

    return Dialog(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.all(24),
      constraints: BoxConstraints(maxWidth: requested ?? 640),
      child: _DialogGlass(
        animation: animation,
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (title != null)
                reveal(
                  DefaultTextStyle(
                    style: Theme.of(context).textTheme.titleLarge!,
                    child: title!,
                  ),
                  0,
                  .65,
                  7,
                ),
              if (title != null && content != null) const SizedBox(height: 20),
              if (content != null)
                Flexible(
                  child: reveal(BackdropGroup(child: content!), .08, .82, 10),
                ),
              if (actions?.isNotEmpty == true) ...[
                const SizedBox(height: 20),
                reveal(
                  Wrap(
                    alignment: WrapAlignment.end,
                    spacing: 12,
                    runSpacing: 8,
                    children: actions!,
                  ),
                  .16,
                  .94,
                  12,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _DialogGlass extends StatusTransitionWidget {
  const _DialogGlass({required super.animation, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final moving = animation.status != AnimationStatus.completed;
    return _DialogPaintMode(
      moving: moving,
      child: CustomPaint(
        foregroundPainter: moving && !MediaQuery.disableAnimationsOf(context)
            ? _DialogOutline(animation, Theme.of(context).colorScheme.primary)
            : null,
        child: GlassAppearance.of(
          context,
        ).wrap(child, grouped: false, inTransition: moving),
      ),
    );
  }
}

class _DialogPaintMode extends InheritedWidget {
  const _DialogPaintMode({required this.moving, required super.child});
  final bool moving;
  static _DialogPaintMode? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_DialogPaintMode>();
  @override
  bool updateShouldNotify(_DialogPaintMode oldWidget) =>
      moving != oldWidget.moving;
}

class _DialogOutline extends CustomPainter {
  _DialogOutline(this.progress, this.color) : super(repaint: progress);
  final Animation<double> progress;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty || progress.value <= 0 || progress.value >= 1) return;
    final border = Path()
      ..addRRect(
        RRect.fromRectAndRadius(
          (Offset.zero & size).deflate(1),
          const Radius.circular(21),
        ),
      );
    final outline = border.computeMetrics().first;
    final t = progress.value;
    final travel = const Interval(
      0,
      .8,
      curve: Curves.easeOutCubic,
    ).transform(t);
    final fade = 1 - const Interval(.38, 1, curve: Curves.easeIn).transform(t);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 1.5;
    final half = outline.length / 2;
    final reach = half * travel;
    paint.color = color.withValues(alpha: .48 * fade);
    canvas.drawPath(outline.extractPath(0, reach), paint);
    canvas.drawPath(
      outline.extractPath(outline.length - reach, outline.length),
      paint,
    );

    // Bright leading tips follow both traces and dissolve where they meet.
    final tipLength = (size.shortestSide * .14).clamp(8.0, 36.0);
    final tail = (reach - tipLength).clamp(0.0, reach);
    paint
      ..strokeWidth = 2.5
      ..color = Color.lerp(
        color,
        Colors.white,
        .45,
      )!.withValues(alpha: .9 * fade * (1 - travel));
    canvas.drawPath(outline.extractPath(tail, reach), paint);
    canvas.drawPath(
      outline.extractPath(outline.length - reach, outline.length - tail),
      paint,
    );
  }

  @override
  bool shouldRepaint(_DialogOutline oldDelegate) =>
      color != oldDelegate.color || progress != oldDelegate.progress;
}
