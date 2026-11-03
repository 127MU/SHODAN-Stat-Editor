import 'package:flutter/material.dart';
import 'third_party/liquid_glass.dart';

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
  Widget wrap(Widget child, {Key? key}) => LiquidGlassSurface(
    key: key,
    material: mode == 'liquid'
        ? null
        : GlassMaterial(
            blur: mode == 'frosted' ? blur : 0,
            liquid: 0,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(22),
              color: (dark ? const Color(0xff20243c) : Colors.white).withValues(
                alpha: opacity,
              ),
              border: Border.all(color: dark ? Colors.white24 : Colors.white70),
            ),
          ),
    tint: dark ? const Color(0xff293044) : const Color(0xffe6ecff),
    dark: dark,
    borderRadius: BorderRadius.circular(22),
    readable: true,
    child: child,
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
    return Dialog(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.all(24),
      constraints: BoxConstraints(maxWidth: requested ?? 640),
      child: GlassAppearance.of(context).wrap(
        Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (title != null)
                DefaultTextStyle(
                  style: Theme.of(context).textTheme.titleLarge!,
                  child: title!,
                ),
              if (title != null && content != null) const SizedBox(height: 20),
              if (content != null)
                Flexible(child: BackdropGroup(child: content!)),
              if (actions?.isNotEmpty == true) ...[
                const SizedBox(height: 20),
                Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 12,
                  runSpacing: 8,
                  children: actions!,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
