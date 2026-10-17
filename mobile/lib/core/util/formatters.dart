import 'package:intl/intl.dart';

final _grouped = NumberFormat('#,##0', 'en_US');

/// Minor units (paisa) to display: 450000 -> "PKR 4,500.00". Integer math only.
String formatMoney(int minor, [String currency = 'PKR']) {
  final negative = minor < 0;
  final abs = minor.abs();
  final whole = _grouped.format(abs ~/ 100);
  final cents = (abs % 100).toString().padLeft(2, '0');
  return '${negative ? '-' : ''}$currency $whole.$cents';
}

/// Contract timestamp "YYYY-MM-DDTHH:MM:SSZ" for now, in UTC.
String utcTimestamp([DateTime? at]) {
  final t = (at ?? DateTime.now()).toUtc();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${t.year.toString().padLeft(4, '0')}-${two(t.month)}-${two(t.day)}'
      'T${two(t.hour)}:${two(t.minute)}:${two(t.second)}Z';
}

/// Contract date "YYYY-MM-DD".
String isoDate(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

String formatKickoff(DateTime? utc) {
  if (utc == null) return 'Time to be confirmed';
  return DateFormat('EEE d MMM · HH:mm').format(utc.toLocal());
}

String formatDateTime(String? raw) {
  final t = raw == null ? null : DateTime.tryParse(raw);
  if (t == null) return raw ?? '—';
  return DateFormat('d MMM yyyy, HH:mm').format(t.toLocal());
}

String formatDate(String? raw) {
  final t = raw == null ? null : DateTime.tryParse(raw);
  if (t == null) return raw ?? '—';
  return DateFormat('d MMM yyyy').format(t);
}

/// "updated 5 min ago" for cached data.
String relativeAge(DateTime when, {DateTime? now}) {
  final diff = (now ?? DateTime.now().toUtc()).difference(when.toUtc());
  if (diff.inSeconds < 60) return 'just now';
  if (diff.inMinutes < 60) return '${diff.inMinutes} min ago';
  if (diff.inHours < 24) return '${diff.inHours} h ago';
  return '${diff.inDays} d ago';
}

String humanize(String raw) {
  final words = raw.replaceAll('_', ' ').trim();
  if (words.isEmpty) return raw;
  return words[0].toUpperCase() + words.substring(1);
}
