import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

class ThemeReveal extends CustomPainter {
  const ThemeReveal(
    this.image,
    this.origin,
    this.progress, {
    required this.reverse,
  });

  final ui.Image image;
  final Offset origin;
  final double progress;
  final bool reverse;

  @override
  void paint(Canvas canvas, Size size) {
    final bounds = Offset.zero & size;
    final point = Offset(
      origin.dx.clamp(0.0, size.width),
      origin.dy.clamp(0.0, size.height),
    );
    final farthest = Offset(
      math.max(point.dx, size.width - point.dx),
      math.max(point.dy, size.height - point.dy),
    );
    final mask = Path()..fillType = PathFillType.evenOdd;
    if (!reverse) mask.addRect(bounds);
    final scale = reverse ? 1 - progress : progress;
    mask.addOval(
      Rect.fromCircle(center: point, radius: farthest.distance * scale),
    );
    canvas.save();
    canvas.clipRect(bounds);
    canvas.clipPath(mask);
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      bounds,
      Paint(),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(ThemeReveal oldDelegate) =>
      image != oldDelegate.image ||
      origin != oldDelegate.origin ||
      progress != oldDelegate.progress ||
      reverse != oldDelegate.reverse;
}
