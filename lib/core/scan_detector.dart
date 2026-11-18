/// Recognises input from USB barcode / QR scanners in keyboard (HID "wedge")
/// mode. Such scanners need no driver or internet: the operating system sees
/// them as a keyboard that types the code very fast and usually ends it with
/// Enter (sometimes Tab, sometimes nothing).
///
/// The detector is pure logic (no Flutter) so it can be tested exactly: it is
/// fed each typed character and suffix key with its time, and reports a code
/// only for a fast burst — so normal typing is never mistaken for a scan.
library;

/// Which key the scanner sends after the code.
enum ScanSuffix {
  /// Enter or Tab (the default; covers almost all scanners).
  auto,
  enter,
  tab,

  /// No suffix: the code ends when the fast typing stops.
  none;

  String get label => switch (this) {
        ScanSuffix.auto => 'Enter or Tab (automatic)',
        ScanSuffix.enter => 'Enter only',
        ScanSuffix.tab => 'Tab only',
        ScanSuffix.none => 'No suffix (end on pause)',
      };

  static ScanSuffix parse(Object? v) => ScanSuffix.values.firstWhere((e) => e.name == v, orElse: () => ScanSuffix.auto);
}

/// The two keys a scanner can end a code with.
enum SuffixKey { enter, tab }

class ScannerConfig {
  final ScanSuffix suffix;

  /// Largest gap between two characters of one scan. Scanners type a
  /// character every 1-15 ms; people rarely type faster than 60-100 ms.
  final Duration maxKeyGap;

  /// Shorter bursts are treated as typing, not as a scan.
  final int minLength;

  /// The same code again within this time is ignored (a scanner reading the
  /// label twice). Zero turns the check off.
  final Duration duplicateWindow;

  const ScannerConfig({
    this.suffix = ScanSuffix.auto,
    this.maxKeyGap = const Duration(milliseconds: 40),
    this.minLength = 4,
    this.duplicateWindow = const Duration(milliseconds: 700),
  });

  bool accepts(SuffixKey k) => switch (suffix) {
        ScanSuffix.auto => true,
        ScanSuffix.enter => k == SuffixKey.enter,
        ScanSuffix.tab => k == SuffixKey.tab,
        ScanSuffix.none => false,
      };

  /// The suffix may come a little later than the characters.
  Duration get suffixGap => maxKeyGap * 2;

  /// With no suffix, a scan is complete after this pause.
  Duration get endPause => maxKeyGap * 2 + const Duration(milliseconds: 20);
}

class ScanDetector {
  ScannerConfig config;
  ScanDetector([this.config = const ScannerConfig()]);

  final StringBuffer _buf = StringBuffer();
  Duration? _last;

  /// Characters of the current (latest) fast burst.
  String get pending => _buf.toString();
  bool get isEmpty => _buf.isEmpty;

  /// Adds a typed character. Returns true when it starts a new burst (the
  /// previous character was too long ago, or there was none).
  bool addChar(String ch, Duration at) {
    final last = _last;
    final started = _buf.isEmpty || last == null || at - last > config.maxKeyGap || at < last;
    if (started) _buf.clear();
    _buf.write(ch);
    _last = at;
    return started;
  }

  bool _scanLike(Duration at, Duration allowed) {
    final last = _last;
    return _buf.length >= config.minLength && last != null && at - last <= allowed && at >= last;
  }

  /// Enter or Tab pressed. Returns the scanned code when the burst before it
  /// was a scan and this suffix is accepted; otherwise null (normal key).
  /// The burst is finished either way.
  String? suffix(SuffixKey key, Duration at) {
    final code = config.accepts(key) && _scanLike(at, config.suffixGap) ? pending : null;
    reset();
    return code;
  }

  /// Called after [ScannerConfig.endPause] without a key. In "no suffix" mode returns the code when the
  /// burst was a scan. Returns null otherwise; the burst is finished.
  String? pause() {
    // Every character of the burst was fast (a slow gap starts a new burst),
    // so only the length decides.
    final code = config.suffix == ScanSuffix.none && _buf.length >= config.minLength ? pending : null;
    reset();
    return code;
  }

  void reset() {
    _buf.clear();
    _last = null;
  }
}

/// Ignores the same code arriving again within [ScannerConfig.duplicateWindow].
class DuplicateScanGuard {
  Duration window;
  DuplicateScanGuard(this.window);

  String? _code;
  DateTime? _at;

  /// True when [code] should be used; false when it repeats the previous
  /// code too soon. Codes are compared ignoring case and spaces.
  bool accept(String code, DateTime now) {
    final c = code.trim().toUpperCase().replaceAll(RegExp(r'\s+'), '');
    final at = _at;
    final dup = window > Duration.zero && c == _code && at != null && now.difference(at) >= Duration.zero && now.difference(at) < window;
    if (!dup) {
      _code = c;
      _at = now;
    }
    return !dup;
  }

  void reset() {
    _code = null;
    _at = null;
  }
}
