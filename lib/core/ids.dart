import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

final _rand = Random.secure();
int _counter = 0;

/// Sortable unique id: time (base36) + counter + random suffix.
String newId() {
  _counter = (_counter + 1) % 1296;
  final t = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
  final c = _counter.toRadixString(36).padLeft(2, '0');
  final r = List.generate(6, (_) => _rand.nextInt(36).toRadixString(36)).join();
  return '$t$c$r';
}

/// Normalizes scanner/user input for codes and serial numbers.
String normalizeCode(String raw) => raw.trim().toUpperCase().replaceAll(RegExp(r'\s+'), '');

/// Storage key for a barcode/QR value. Hive keys are limited to 255 chars and
/// QR codes can hold long text, so long codes are stored by their hash.
String indexKey(String normalizedCode) =>
    normalizedCode.length <= 200 ? normalizedCode : 'H:${sha256.convert(utf8.encode(normalizedCode))}';
