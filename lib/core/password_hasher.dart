import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// PBKDF2-HMAC-SHA256 password hashing. Stored format:
/// `pbkdf2-sha256$<iterations>$<saltBase64>$<hashBase64>`
class PasswordHasher {
  final int iterations;
  const PasswordHasher({this.iterations = 60000});

  String hash(String password) {
    final rnd = Random.secure();
    final salt = Uint8List.fromList(List.generate(16, (_) => rnd.nextInt(256)));
    final dk = _pbkdf2(utf8.encode(password), salt, iterations, 32);
    return 'pbkdf2-sha256\$$iterations\$${base64.encode(salt)}\$${base64.encode(dk)}';
  }

  bool verify(String password, String stored) {
    final parts = stored.split('\$');
    if (parts.length != 4 || parts[0] != 'pbkdf2-sha256') return false;
    final iter = int.tryParse(parts[1]);
    if (iter == null) return false;
    final salt = base64.decode(parts[2]);
    final expected = base64.decode(parts[3]);
    final dk = _pbkdf2(utf8.encode(password), salt, iter, expected.length);
    // constant-time compare
    var diff = 0;
    for (var i = 0; i < expected.length; i++) {
      diff |= expected[i] ^ dk[i];
    }
    return diff == 0;
  }

  static Uint8List _pbkdf2(List<int> password, List<int> salt, int iterations, int length) {
    final hmac = Hmac(sha256, password);
    final out = BytesBuilder();
    var block = 1;
    while (out.length < length) {
      final blockBytes = [
        ...salt,
        (block >> 24) & 0xff,
        (block >> 16) & 0xff,
        (block >> 8) & 0xff,
        block & 0xff,
      ];
      var u = hmac.convert(blockBytes).bytes;
      final t = List<int>.from(u);
      for (var i = 1; i < iterations; i++) {
        u = hmac.convert(u).bytes;
        for (var j = 0; j < t.length; j++) {
          t[j] ^= u[j];
        }
      }
      out.add(t);
      block++;
    }
    return Uint8List.fromList(out.toBytes().sublist(0, length));
  }
}
