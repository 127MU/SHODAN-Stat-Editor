import 'package:flutter/foundation.dart';

/// Changes only on resize start/end, never once per WM_SIZING event.
final windowResizing = ValueNotifier<bool>(false);
