import '../../core/money.dart';
import '../../core/qty.dart';

DateTime parseDate(Object? v) => v == null ? DateTime.fromMillisecondsSinceEpoch(0) : DateTime.parse(v as String);
DateTime? parseDateOrNull(Object? v) => v == null ? null : DateTime.parse(v as String);
String? dateOrNull(DateTime? d) => d?.toIso8601String();
Money m(Object? v) => Money.fromJson(v);
Qty qy(Object? v) => Qty.fromJson(v);
int i(Object? v) => (v as num?)?.toInt() ?? 0;
String s(Object? v) => v as String? ?? '';
String? sn(Object? v) => v as String?;
bool b(Object? v, [bool def = false]) => v as bool? ?? def;
List<String> strList(Object? v) => (v as List?)?.map((e) => e.toString()).toList() ?? <String>[];
List<Map<String, dynamic>> mapList(Object? v) =>
    (v as List?)?.map((e) => Map<String, dynamic>.from(e as Map)).toList() ?? [];

T enumByName<T extends Enum>(List<T> values, Object? name, T fallback) {
  for (final v in values) {
    if (v.name == name) return v;
  }
  return fallback;
}

DateTime dayStart(DateTime d) => DateTime(d.year, d.month, d.day);
DateTime dayEnd(DateTime d) => DateTime(d.year, d.month, d.day, 23, 59, 59, 999);

/// Adds calendar months, clamping the day (e.g. Jan 31 + 1 month = Feb 28/29).
DateTime addMonths(DateTime d, int months) {
  final y = d.year + ((d.month - 1 + months) ~/ 12);
  final mo = (d.month - 1 + months) % 12 + 1;
  final lastDay = DateTime(y, mo + 1, 0).day;
  return DateTime(y, mo, d.day > lastDay ? lastDay : d.day, d.hour, d.minute, d.second);
}
