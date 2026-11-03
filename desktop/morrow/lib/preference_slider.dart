import 'package:flutter/material.dart';
import 'number_display.dart';

/// Drag the thumb locally; commit expensive theme/layout changes on release.
class PreferenceSlider extends StatefulWidget {
  const PreferenceSlider({
    super.key,
    required this.value,
    required this.min,
    required this.max,
    this.divisions,
    required this.onChanged,
  });
  final double value, min, max;
  final int? divisions;
  final ValueChanged<double>? onChanged;
  @override
  State<PreferenceSlider> createState() => _PreferenceSliderState();
}

class _PreferenceSliderState extends State<PreferenceSlider> {
  late double value = widget.value;
  bool dragging = false;
  @override
  void didUpdateWidget(PreferenceSlider oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!dragging) value = widget.value;
  }

  @override
  Widget build(BuildContext context) => Slider(
    value: value,
    min: widget.min,
    max: widget.max,
    divisions: widget.divisions,
    label: displayNumber(value),
    onChangeStart: widget.onChanged == null ? null : (_) => dragging = true,
    onChanged: widget.onChanged == null
        ? null
        : (v) => setState(() => value = v),
    onChangeEnd: widget.onChanged == null
        ? null
        : (v) {
            dragging = false;
            widget.onChanged!(v);
          },
  );
}
