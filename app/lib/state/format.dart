// Formatting helpers shared by the UI.
//
// Copyright (c) 2026 DI JUNKUN. All Rights Reserved. Proprietary.

String formatBytes(int b) {
  const units = ['B', 'KiB', 'MiB', 'GiB', 'TiB'];
  double v = b.toDouble();
  int u = 0;
  while (v >= 1024 && u < units.length - 1) {
    v /= 1024;
    u++;
  }
  return u == 0 ? '${v.toStringAsFixed(0)} ${units[u]}' : '${v.toStringAsFixed(1)} ${units[u]}';
}

String formatRate(int bps) => '${formatBytes(bps ~/ 8)}/s';

String formatEta(int sec) {
  if (sec < 0) return '--';
  if (sec < 60) return '${sec}s';
  if (sec < 3600) return '${sec ~/ 60}m ${sec % 60}s';
  return '${sec ~/ 3600}h ${(sec % 3600) ~/ 60}m';
}

String formatPercent(double f) => '${(f * 100).toStringAsFixed(1)}%';

/// Seconds remaining until [unixSec]; negative when passed.
int secondsUntil(int unixSec) =>
    unixSec - DateTime.now().millisecondsSinceEpoch ~/ 1000;

String formatCountdown(int sec) {
  if (sec <= 0) return '0:00';
  final m = sec ~/ 60, s = sec % 60;
  return '$m:${s.toString().padLeft(2, '0')}';
}

/// Crockford Base32 as used by take-codes; normalises user input the same way
/// the core does so the UI can show a formatted preview.
const String takeCodeAlphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';

String? normalizeTakeCode(String input) {
  final buf = StringBuffer();
  for (final r in input.trim().toUpperCase().runes) {
    final c = String.fromCharCode(r);
    if (c == '-' || c == ' ' || c == '_' || c == '\t') continue;
    final mapped = c == 'O' ? '0' : (c == 'I' || c == 'L') ? '1' : c;
    if (!takeCodeAlphabet.contains(mapped)) return null;
    buf.write(mapped);
  }
  final s = buf.toString();
  return s.length == 10 ? s : null;
}

/// Extracts the code from a bare code or a https:// / crosstransfer:// link.
String? extractTakeCode(String input) {
  var s = input.trim();
  if (s.isEmpty) return null;
  final lower = s.toLowerCase();
  if (lower.startsWith('http://') ||
      lower.startsWith('https://') ||
      lower.startsWith('crosstransfer:')) {
    // Take the entire segment: never accept a valid prefix of a longer code.
    final m = RegExp(r'/r/([^/?#]+)').firstMatch(s);
    if (m == null) return null;
    s = m.group(1)!;
  }
  return normalizeTakeCode(s);
}

String formatTakeCode(String canonical) =>
    canonical.length == 10 ? '${canonical.substring(0, 5)}-${canonical.substring(5)}' : canonical;
