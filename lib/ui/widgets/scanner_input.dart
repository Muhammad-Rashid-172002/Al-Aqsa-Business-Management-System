import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../core/scan_detector.dart';

/// Test hook: when set, used instead of key-event time stamps.
@visibleForTesting
Duration Function()? debugScannerClock;

/// Captures USB barcode / QR scanners in keyboard mode anywhere on its page,
/// whichever field (or none) has focus:
///
/// * a fast burst ending with the configured suffix (or a pause, with
///   "no suffix") is reported once through [onScan], and its characters are
///   taken back out of whatever text field they were typed into;
/// * ordinary typing is left alone. Typing while no text field has focus goes
///   into the scan field ([scanController]/[scanFocus]) so search keeps
///   working without clicking the field first.
///
/// Only active while its page is the visible, top-most route (not under a
/// dialog, not an inactive tab).
class ScannerKeyboardListener extends StatefulWidget {
  final ScannerConfig config;
  final void Function(String code) onScan;
  final TextEditingController scanController;
  final FocusNode scanFocus;

  /// Called after text was put into the scan field by this listener.
  final ValueChanged<String>? onScanFieldChanged;
  final Widget child;

  const ScannerKeyboardListener({
    super.key,
    required this.config,
    required this.onScan,
    required this.scanController,
    required this.scanFocus,
    this.onScanFieldChanged,
    required this.child,
  });

  @override
  State<ScannerKeyboardListener> createState() => _ScannerKeyboardListenerState();
}

class _ScannerKeyboardListenerState extends State<ScannerKeyboardListener> {
  late final ScanDetector _det = ScanDetector(widget.config);
  final Stopwatch _sw = Stopwatch()..start();
  ModalRoute<dynamic>? _route;
  bool _visible = true;

  /// Characters consumed because no text field had focus.
  final StringBuffer _held = StringBuffer();

  /// Text field the current burst is going into, and its text before it.
  TextEditingController? _target;
  TextEditingValue? _before;
  Timer? _pause;
  Timer? _echo;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  @override
  void didUpdateWidget(ScannerKeyboardListener old) {
    super.didUpdateWidget(old);
    _det.config = widget.config;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route = ModalRoute.of(context);
    _visible = TickerMode.valuesOf(context).enabled;
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    _pause?.cancel();
    _echo?.cancel();
    super.dispose();
  }

  bool get _active {
    if (!mounted) return false;
    final r = _route;
    if (r != null && !r.isCurrent) return false;
    return _visible;
  }

  Duration _time(KeyEvent e) {
    final c = debugScannerClock;
    if (c != null) return c();
    return e.timeStamp > Duration.zero ? e.timeStamp : _sw.elapsed;
  }

  /// Controller of the focused text field, if a text field has focus.
  TextEditingController? _focusedField() {
    final ctx = FocusManager.instance.primaryFocus?.context;
    if (ctx == null) return null;
    if (ctx.widget is EditableText) return (ctx.widget as EditableText).controller;
    return ctx.findAncestorStateOfType<EditableTextState>()?.widget.controller;
  }

  bool _onKey(KeyEvent e) {
    if (e is! KeyDownEvent || !_active) return false;
    final kb = HardwareKeyboard.instance;
    if (kb.isControlPressed || kb.isAltPressed || kb.isMetaPressed) {
      _endBurst();
      return false;
    }
    final at = _time(e);
    final k = e.logicalKey;
    final sfx = (k == LogicalKeyboardKey.enter || k == LogicalKeyboardKey.numpadEnter)
        ? SuffixKey.enter
        : k == LogicalKeyboardKey.tab
            ? SuffixKey.tab
            : null;
    if (sfx != null) {
      final code = _det.suffix(sfx, at);
      if (code == null) {
        _endBurst();
        return false; // a normal Enter / Tab
      }
      _complete(code);
      return true; // the suffix is not passed on (no submit, no focus move)
    }
    final ch = e.character;
    if (ch == null || ch.isEmpty || ch.runes.length != 1 || ch.codeUnitAt(0) < 32 || ch.codeUnitAt(0) == 127) {
      if (k != LogicalKeyboardKey.shiftLeft && k != LogicalKeyboardKey.shiftRight && k != LogicalKeyboardKey.capsLock) {
        _endBurst(); // arrows, Backspace, F-keys ...
      }
      return false;
    }
    final field = _focusedField();
    if (_det.addChar(ch, at)) {
      // A new burst: whatever was held from an earlier burst was typing. It
      // goes into the scan field, which gets focus, so the rest of this burst
      // lands there too and is what to take back if this burst is a scan.
      final hadHeld = _held.isNotEmpty;
      _flushHeld();
      final f = field ?? (hadHeld ? widget.scanController : null);
      _target = f;
      _before = f?.value;
    } else if (field != null && _held.isNotEmpty) {
      _flushHeld(); // the scan field just got focus: keep the typing order
    }
    _pause?.cancel();
    _pause = Timer(widget.config.endPause, _onPause);
    if (field != null) return false; // the field shows it; taken back if it is a scan
    if (ch == ' ' && _held.isEmpty) {
      _det.reset();
      return false; // Space on a focused button keeps working
    }
    _held.write(ch);
    return true;
  }

  void _onPause() {
    if (!mounted) return;
    final code = _det.pause();
    if (code != null) {
      _complete(code);
    } else {
      _flushHeld();
      _target = null;
      _before = null;
    }
  }

  void _endBurst() {
    _pause?.cancel();
    _det.reset();
    _flushHeld();
    _target = null;
    _before = null;
  }

  /// Typing that started while no field had focus goes into the scan field.
  void _flushHeld() {
    if (_held.isEmpty) return;
    final text = _held.toString();
    _held.clear();
    final ctl = widget.scanController;
    final v = ctl.value;
    final sel = v.selection.isValid ? v.selection : TextSelection.collapsed(offset: v.text.length);
    final next = v.text.replaceRange(sel.start, sel.end, text);
    ctl.value = TextEditingValue(text: next, selection: TextSelection.collapsed(offset: sel.start + text.length));
    widget.scanFocus.requestFocus();
    widget.onScanFieldChanged?.call(next);
  }

  void _complete(String code) {
    _pause?.cancel();
    _det.reset();
    _held.clear();
    final ctl = _target;
    final before = _before;
    _target = null;
    _before = null;
    if (ctl != null && before != null) {
      // Take the scanned characters back out of the field they went into.
      ctl.value = before;
      if (identical(ctl, widget.scanController)) widget.onScanFieldChanged?.call(before.text);
      // On some systems the last characters reach the field just after the
      // suffix key; remove them too if they arrive.
      _echo?.cancel();
      _echo = Timer(const Duration(milliseconds: 60), () {
        if (!mounted) return;
        try {
          final extra = ctl.text.length - before.text.length;
          if (extra > 0 && extra <= code.length) {
            ctl.value = before;
            if (identical(ctl, widget.scanController)) widget.onScanFieldChanged?.call(before.text);
          }
        } catch (_) {
          // The field was closed meanwhile: nothing to clean up.
        }
      });
    }
    widget.onScan(code);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
