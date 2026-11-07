import 'package:flutter/material.dart';

abstract final class WorkbenchMotion {
  static const hover = Duration(milliseconds: 90);
  static const feedback = Duration(milliseconds: 150);
  static const settle = Duration(milliseconds: 230);
  static const page = Duration(milliseconds: 320);
  static const dialog = Duration(milliseconds: 300);
  static const reveal = Duration(milliseconds: 420);
  static const _catalogCardCount = 8;
  static const _catalogCardDelay = 40;
  static const _catalogCardTravel = 210;
  static const catalogEntrance = Duration(
    milliseconds:
        (_catalogCardCount - 1) * _catalogCardDelay + _catalogCardTravel,
  );
  static const standard = Cubic(.2, 0, 0, 1);
  static const enter = Cubic(.22, .72, .23, 1);
  static const exit = Cubic(.3, 0, 1, 1);

  static Duration duration(BuildContext context, Duration value) =>
      MediaQuery.disableAnimationsOf(context) ? Duration.zero : value;
}

/// Shares a single clock across the opening cards in a catalog.
class CatalogEntrance extends StatefulWidget {
  const CatalogEntrance({super.key, required this.builder});
  final Widget Function(BuildContext, Animation<double>) builder;

  static Widget card(
    Animation<double> animation,
    int index,
    Widget child, {
    int columns = 1,
    int? count,
    Key? key,
  }) {
    final rowStart = index - index % columns;
    final remaining = (count ?? rowStart + columns) - rowStart;
    final rowSize = remaining < columns ? remaining : columns;
    final order = rowStart + rowSize - 1 - index % columns;
    if (order >= WorkbenchMotion._catalogCardCount) {
      return key == null ? child : KeyedSubtree(key: key, child: child);
    }
    final total = WorkbenchMotion.catalogEntrance.inMilliseconds;
    final start = order * WorkbenchMotion._catalogCardDelay;
    final curve = Interval(
      start / total,
      (start + WorkbenchMotion._catalogCardTravel) / total,
      curve: WorkbenchMotion.enter,
    );
    return AnimatedBuilder(
      key: key,
      animation: animation,
      child: child,
      builder: (context, child) => Transform.translate(
        offset: Offset(
          MediaQuery.sizeOf(context).width *
              (1 - curve.transform(animation.value)),
          0,
        ),
        child: child,
      ),
    );
  }

  @override
  State<CatalogEntrance> createState() => _CatalogEntranceState();
}

class _CatalogEntranceState extends State<CatalogEntrance>
    with SingleTickerProviderStateMixin {
  late final AnimationController _progress = AnimationController(
    vsync: this,
    duration: WorkbenchMotion.catalogEntrance,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _progress.value = 1;
    } else if (_progress.isDismissed) {
      _progress.forward();
    }
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _progress);

  @override
  void dispose() {
    _progress.dispose();
    super.dispose();
  }
}

class MotionDialogRoute<T> extends DialogRoute<T> {
  MotionDialogRoute({
    required super.context,
    required super.builder,
    super.barrierDismissible,
    this.anchor = Alignment.center,
  }) : reduced = MediaQuery.disableAnimationsOf(context);

  final Alignment anchor;
  final bool reduced;
  CurvedAnimation? _curve;

  @override
  Duration get transitionDuration =>
      reduced ? Duration.zero : WorkbenchMotion.dialog;

  @override
  Duration get reverseTransitionDuration =>
      reduced ? Duration.zero : WorkbenchMotion.settle;

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (reduced) return child;
    final curve = _curve ??= CurvedAnimation(
      parent: animation,
      curve: WorkbenchMotion.enter,
      reverseCurve: WorkbenchMotion.exit.flipped,
    );
    return AnimatedBuilder(
      animation: curve,
      child: child,
      builder: (context, child) {
        final progress = curve.value;
        return Transform.translate(
          offset: Offset(anchor.x * 10, 12 + anchor.y * 8) * (1 - progress),
          child: child,
        );
      },
    );
  }

  @override
  void dispose() {
    _curve?.dispose();
    super.dispose();
  }
}

Future<T?> showMotionDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
  BuildContext? source,
}) {
  final navigator = Navigator.of(context, rootNavigator: true);
  final viewport = navigator.overlay?.context.findRenderObject();
  final trigger = source != null && source.mounted
      ? source.findRenderObject()
      : null;
  var anchor = Alignment.center;
  if (viewport is RenderBox &&
      viewport.hasSize &&
      !viewport.size.isEmpty &&
      trigger is RenderBox &&
      trigger.attached &&
      trigger.hasSize) {
    final point = viewport.globalToLocal(
      trigger.localToGlobal(trigger.size.center(Offset.zero)),
    );
    anchor = Alignment(
      (point.dx / viewport.size.width * 2 - 1).clamp(-1, 1),
      (point.dy / viewport.size.height * 2 - 1).clamp(-1, 1),
    );
  }
  return navigator.push(
    MotionDialogRoute<T>(
      context: context,
      builder: builder,
      barrierDismissible: barrierDismissible,
      anchor: anchor,
    ),
  );
}
