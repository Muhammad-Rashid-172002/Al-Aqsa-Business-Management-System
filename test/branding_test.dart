// The official logo is wired into the Windows exe, the installer and the app.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('app_icon.ico is a multi-size icon with 16-256 px images', () {
    final b = File('windows/runner/resources/app_icon.ico').readAsBytesSync();
    final d = ByteData.sublistView(b);
    expect(d.getUint16(0, Endian.little), 0); // reserved
    expect(d.getUint16(2, Endian.little), 1); // type: icon
    final n = d.getUint16(4, Endian.little);
    final sizes = <int>{for (var i = 0; i < n; i++) (b[6 + i * 16] == 0 ? 256 : b[6 + i * 16])};
    for (final s in [16, 32, 48, 64, 128, 256]) {
      expect(sizes.contains(s), isTrue, reason: 'missing ${s}px');
    }
  });

  test('exe, installer and Flutter assets all use the official logo files', () {
    expect(File('windows/runner/Runner.rc').readAsStringSync().contains(r'resources\\app_icon.ico'), isTrue);
    final iss = File('installer/al_aqsa_cctv.iss').readAsStringSync();
    expect(iss.contains(r'SetupIconFile=..\windows\runner\resources\app_icon.ico'), isTrue);
    expect(iss.contains('WizardImageFile=wizard_image.bmp'), isTrue);
    expect(iss.contains('WizardSmallImageFile=wizard_small.bmp'), isTrue);
    for (final f in ['installer/wizard_image.bmp', 'installer/wizard_small.bmp', 'assets/branding/al_aqsa_logo_original.jpg']) {
      expect(File(f).existsSync(), isTrue, reason: f);
    }
    final pub = File('pubspec.yaml').readAsStringSync();
    for (final a in ['assets/branding/al_aqsa_logo.png', 'assets/branding/al_aqsa_icon_square.png']) {
      expect(pub.contains(a), isTrue, reason: a);
      final png = File(a).readAsBytesSync();
      expect(png.sublist(1, 4), [0x50, 0x4E, 0x47]); // "PNG"
    }
  });
}
