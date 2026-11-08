/// Round presentation only. Never use this to serialize game data or presets.
String displayNumber(Object? value) {
  if (value == null) return '未知';
  final text = value.toString();
  final n = num.tryParse(text);
  if (n == null || !n.isFinite) return text;
  if (n == n.truncateToDouble())
    return text.contains('.') || text.contains('e')
        ? n.toStringAsFixed(0)
        : text;
  // Keep scientific notation for values too large to format as fixed point.
  if (n.abs() >= 1e21) return n.toStringAsExponential(2);
  final rounded = n.toStringAsFixed(2).replaceFirst(RegExp(r'\.?0+$'), '');
  return rounded == '-0' ? '0' : rounded;
}

/// Keeps presentation rounding separate from explicit editing intent.
class NumericDraft {
  NumericDraft(String value) : raw = value, display = displayNumber(value);
  String raw;
  String display;
  bool edited = false;

  bool needsSave(String text) {
    if (!edited && text == display) return false;
    final before = num.tryParse(raw.trim());
    final after = num.tryParse(text.trim());
    return before == null || after == null ? text != raw : before != after;
  }

  void acknowledge(String value) {
    raw = value;
    display = displayNumber(value);
  }
}
