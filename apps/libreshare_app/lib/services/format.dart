/// Number and time formatting for the UI. Unit labels come from the string
/// table so they can be translated.
library;

import '../l10n_strings.dart';

/// Decimal units (1 KB = 1000 B): 1500 -> "1.50 KB", 12345678 -> "12.3 MB".
/// Whole bytes, then 2 decimals below 10 and 1 decimal from 10; a value that
/// rounds up to 1000 moves to the next unit.
String formatBytes(num bytes) {
  const keys = ['unit.b', 'unit.kb', 'unit.mb', 'unit.gb', 'unit.tb'];
  var v = bytes.toDouble();
  if (v.isNaN || v < 0) v = 0;
  var i = 0;
  while (v >= 1000 && i < keys.length - 1) {
    v /= 1000;
    i++;
  }
  if (i == 0) return '${v.round()} ${tr(keys[0])}';
  var text = v.toStringAsFixed(2);
  if (double.parse(text) >= 10) text = v.toStringAsFixed(1);
  if (double.parse(text) >= 1000 && i < keys.length - 1) {
    v /= 1000;
    i++;
    text = v.toStringAsFixed(2);
  }
  return '$text ${tr(keys[i])}';
}

/// Bytes per second -> "12.3 MB/s".
String formatSpeed(double bytesPerSecond) =>
    tr('speed.perSecond', {'size': formatBytes(bytesPerSecond)});

/// "2 min left", "45 s left", "1 h 5 min left".
String formatEta(Duration remaining) {
  final s = remaining.inSeconds;
  if (s < 60) return tr('eta.seconds', {'n': s < 1 ? 1 : s});
  final m = remaining.inMinutes;
  if (m < 60) return tr('eta.minutes', {'n': m});
  return tr('eta.hours', {'h': remaining.inHours, 'm': m % 60});
}

/// "5 h 12 min", "15 min", "40 s": a span for status lines.
String formatSpan(Duration d) {
  if (d.inSeconds < 60) {
    return tr('span.seconds', {'n': d.inSeconds < 1 ? 1 : d.inSeconds});
  }
  if (d.inMinutes < 60) return tr('span.minutes', {'n': d.inMinutes});
  final m = d.inMinutes % 60;
  return m == 0
      ? tr('span.hoursOnly', {'h': d.inHours})
      : tr('span.hours', {'h': d.inHours, 'm': m});
}

/// "just now", "12 s ago", "3 min ago", "2 h ago".
String formatAgo(DateTime then, DateTime now) {
  final d = now.difference(then);
  if (d.inSeconds < 5) return tr('ago.now');
  if (d.inSeconds < 60) return tr('ago.seconds', {'n': d.inSeconds});
  if (d.inMinutes < 60) return tr('ago.minutes', {'n': d.inMinutes});
  return tr('ago.hours', {'n': d.inHours});
}

/// "m:ss" countdown for the consent dialog.
String formatCountdown(Duration d) {
  final total = d.isNegative ? 0 : d.inSeconds;
  final m = total ~/ 60;
  final s = total % 60;
  return '$m:${s.toString().padLeft(2, '0')}';
}
