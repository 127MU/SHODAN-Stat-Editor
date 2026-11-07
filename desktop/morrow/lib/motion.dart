import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

abstract final class WorkbenchMotion {
  static const hover = Duration(milliseconds: 90);
  static const feedback = Duration(milliseconds: 150);
  static const settle = Duration(milliseconds: 230);
  static const page = Duration(milliseconds: 320);
  static const dialog = Duration(milliseconds: 300);
  static const reveal = Duration(milliseconds: 420);
  static const catalogEntrance = Duration(milliseconds: 490);
  static const standard = Cubic(.2, 0, 0, 1);
  static const enter = Cubic(.22, .72, .23, 1);
  static const exit = Cubic(.3, 0, 1, 1);

  static Duration duration(BuildContext context, Duration value) =>
      MediaQuery.disableAnimationsOf(context) ? Duration.zero : value;
}

/// Shares one clock across the cards already on screen when a catalog opens.
///
/// Every card also follows its own position inside the scroll viewport, so a
/// card that scrolls into view slides in from the window edge in real time
/// instead of staying put after the opening animation finished.
class CatalogEntrance extends StatefulWidget {
  const CatalogEntrance({super.key, required this.builder});
  final Widget Function(BuildContext, Animation<double>) builder;

  static Widget card(
    Animation<double> animation,
    int index,
    Widget child, {
    int columns = 1,
    Key? key,
  }) => _RevealCard(
    key: key,
    animation: animation,
    index: index,
    columns: columns,
    child: child,
  );

  @override
  State<CatalogEntrance> createState() => _CatalogEntranceState();
}

class _RevealCard extends SingleChildRenderObjectWidget {
  const _RevealCard({
    super.key,
    required this.animation,
    required this.index,
    required this.columns,
    required super.child,
  });

  final Animation<double> animation;
  final int index;
  final int columns;
  @override
  RenderObject createRenderObject(BuildContext context) => _RenderRevealCard(
    animation: animation,
    scroll: Scrollable.maybeOf(context)?.position,
    index: index,
    columns: columns,
    windowWidth: MediaQuery.sizeOf(context).width,
    reduced: MediaQuery.disableAnimationsOf(context),
  );

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderRevealCard renderObject,
  ) {
    renderObject.update(
      animation: animation,
      scroll: Scrollable.maybeOf(context)?.position,
      index: index,
      columns: columns,
      windowWidth: MediaQuery.sizeOf(context).width,
      reduced: MediaQuery.disableAnimationsOf(context),
    );
  }
}

class _RenderRevealCard extends RenderProxyBox {
  _RenderRevealCard({
    required Animation<double> animation,
    required ScrollPosition? scroll,
    required int index,
    required int columns,
    required double windowWidth,
    required bool reduced,
  }) : _animation = animation,
       _scroll = scroll,
       _index = index,
       _columns = columns,
       _windowWidth = windowWidth,
       _reduced = reduced;

  Animation<double> _animation;
  ScrollPosition? _scroll;
  int _index, _columns;
  double _windowWidth;
  bool _reduced;
  Offset _offset = Offset.zero;

  void update({
    required Animation<double> animation,
    required ScrollPosition? scroll,
    required int index,
    required int columns,
    required double windowWidth,
    required bool reduced,
  }) {
    if (attached) _listen(false);
    _animation = animation;
    _scroll = scroll;
    _index = index;
    _columns = columns;
    _windowWidth = windowWidth;
    _reduced = reduced;
    if (attached) _listen(true);
    markNeedsPaint();
  }

  void _listen(bool add) {
    if (add) {
      _animation.addListener(markNeedsPaint);
      _scroll?.addListener(markNeedsPaint);
    } else {
      _animation.removeListener(markNeedsPaint);
      _scroll?.removeListener(markNeedsPaint);
    }
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _listen(true);
  }

  @override
  void detach() {
    _listen(false);
    super.detach();
  }

  double _scrollProgress() {
    final viewport = RenderAbstractViewport.maybeOf(this);
    final area = viewport is RenderBox ? viewport as RenderBox : null;
    if (area == null || !area.hasSize) return 1;
    final origin = localToGlobal(Offset.zero, ancestor: area);
    final span = math.min(size.height, area.size.height * .6);
    if (span <= 0) return 1;
    return ((area.size.height - origin.dy) / span).clamp(0.0, 1.0);
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    // Measure after viewport layout. The proxy's position excludes the child's
    // horizontal translation, and scrolling only schedules paint, never build.
    final order = _columns <= 1 ? 0 : _columns - 1 - _index % _columns;
    final openingDelay = math.min(
      (_index ~/ _columns * _columns + order) * .06,
      .6,
    );
    final scrollDelay = order * .06;
    final opening = ((_animation.value - openingDelay) / (1 - openingDelay))
        .clamp(0.0, 1.0);
    final scrolled = _reduced
        ? 1.0
        : ((_scrollProgress() - scrollDelay) / (1 - scrollDelay)).clamp(
            0.0,
            1.0,
          );
    final eased = WorkbenchMotion.enter.transform(
      _reduced ? 1 : math.min(opening, scrolled),
    );
    _offset = Offset(_windowWidth * (1 - eased), 0);
    super.paint(context, offset + _offset);
  }

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) {
    super.applyPaintTransform(child, transform);
    transform.translateByDouble(_offset.dx, _offset.dy, 0, 1);
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      result.addWithPaintOffset(
        offset: _offset,
        position: position,
        hitTest: (result, position) =>
            super.hitTestChildren(result, position: position),
      );
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
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => widget.builder(context, _progress),
  );

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
