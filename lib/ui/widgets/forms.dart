import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../../core/money.dart';
import '../../core/qty.dart';
import '../theme.dart';

final moneyInput = [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))];
final qtyInput = [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))];
final intInput = [FilteringTextInputFormatter.digitsOnly];

String? moneyValidator(String? v, {bool required = true, bool allowZero = true}) {
  if ((v ?? '').trim().isEmpty) return required ? 'Required' : null;
  final m0 = Money.tryParse(v!);
  if (m0 == null) return 'Enter a valid amount';
  if (m0.isNegative) return 'Cannot be negative';
  if (!allowZero && m0.isZero) return 'Must be more than zero';
  return null;
}

String? qtyValidator(String? v, {bool allowDecimal = true}) {
  final q = Qty.tryParse(v ?? '');
  if (q == null || !q.isPositive) return 'Enter a quantity';
  if (!allowDecimal && !q.isWhole) return 'Whole numbers only';
  return null;
}

final dateFmt = DateFormat('dd/MM/yyyy');
final dateTimeFmt = DateFormat('dd/MM/yyyy  h:mm a');

/// Labeled text field (stacked label, used across forms).
class LabeledField extends StatelessWidget {
  final String label;
  final TextEditingController controller;
  final String? Function(String?)? validator;
  final List<TextInputFormatter>? formatters;
  final String? hint;
  final int maxLines;
  final bool autofocus;
  final bool obscure;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final Widget? prefix;
  final FocusNode? focusNode;
  final bool enabled;
  const LabeledField(this.label, this.controller,
      {super.key,
      this.validator,
      this.formatters,
      this.hint,
      this.maxLines = 1,
      this.autofocus = false,
      this.obscure = false,
      this.onChanged,
      this.onSubmitted,
      this.prefix,
      this.focusNode,
      this.enabled = true});

  @override
  Widget build(BuildContext context) => TextFormField(
        controller: controller,
        validator: validator,
        inputFormatters: formatters,
        maxLines: maxLines,
        autofocus: autofocus,
        obscureText: obscure,
        onChanged: onChanged,
        onFieldSubmitted: onSubmitted,
        focusNode: focusNode,
        enabled: enabled,
        decoration: InputDecoration(labelText: label, hintText: hint, prefixIcon: prefix),
      );
}

/// Row of equally wide form fields.
class FieldRow extends StatelessWidget {
  final List<Widget> children;
  final double gap;
  const FieldRow(this.children, {super.key, this.gap = 14});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          for (var k = 0; k < children.length; k++) ...[if (k > 0) SizedBox(width: gap), Expanded(child: children[k])]
        ]),
      );
}

/// Text field tuned for USB barcode/QR scanners (keyboard wedge): captures
/// the code, fires [onScan] on Enter, clears and keeps focus. Ignores an
/// identical code repeated within [repeatGuard] (double trigger).
class ScannerField extends StatefulWidget {
  final void Function(String code) onScan;
  final String hint;
  final FocusNode? focusNode;
  final bool autofocus;
  final Duration repeatGuard;
  final ValueChanged<String>? onChanged;

  /// Optional: lets the page read and change the field's text (the POS
  /// scanner listener uses it).
  final TextEditingController? controller;
  const ScannerField({super.key, required this.onScan, this.hint = 'Scan barcode / QR / serial or type and press Enter', this.focusNode, this.autofocus = true, this.repeatGuard = const Duration(milliseconds: 250), this.onChanged, this.controller});

  @override
  State<ScannerField> createState() => _ScannerFieldState();
}

class _ScannerFieldState extends State<ScannerField> {
  late final TextEditingController _ctl = widget.controller ?? TextEditingController();
  late final FocusNode _focus = widget.focusNode ?? FocusNode();
  String _last = '';
  DateTime _lastAt = DateTime(2000);

  void _submit(String v) {
    final code = v.trim();
    _ctl.clear();
    widget.onChanged?.call('');
    _focus.requestFocus();
    if (code.isEmpty) return;
    final now = DateTime.now();
    if (code == _last && now.difference(_lastAt) < widget.repeatGuard) return;
    _last = code;
    _lastAt = now;
    widget.onScan(code);
  }

  @override
  void dispose() {
    if (widget.controller == null) _ctl.dispose();
    if (widget.focusNode == null) _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.of(context);
    return TextField(
      controller: _ctl,
      focusNode: _focus,
      autofocus: widget.autofocus,
      onSubmitted: _submit,
      onChanged: widget.onChanged,
      textInputAction: TextInputAction.done,
      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
      decoration: InputDecoration(
        hintText: widget.hint,
        prefixIcon: Icon(Icons.qr_code_scanner_rounded, color: c.accent),
        suffixIcon: IconButton(tooltip: 'Add', icon: const Icon(Icons.keyboard_return_rounded), onPressed: () => _submit(_ctl.text)),
      ),
    );
  }
}

/// Searchable picker dialog. Returns the chosen item or null.
Future<T?> pickFromList<T>(
  BuildContext context, {
  required String title,
  required List<T> items,
  required String Function(T) label,
  String Function(T)? subtitle,
  Widget Function(T)? trailing,
  Widget? footer,
}) {
  return showDialog<T>(
    context: context,
    builder: (ctx) {
      var q = '';
      return StatefulBuilder(builder: (ctx, setState) {
        final c = AppTheme.of(ctx);
        final ql = q.toLowerCase();
        final filtered = items.where((e) => ql.isEmpty || label(e).toLowerCase().contains(ql) || (subtitle?.call(e).toLowerCase().contains(ql) ?? false)).take(200).toList();
        final screen = MediaQuery.sizeOf(ctx);
        return Dialog(
          insetPadding: EdgeInsets.symmetric(horizontal: screen.width < 700 ? 12 : 40, vertical: screen.height < 600 ? 12 : 24),
          child: SizedBox(
            width: 560,
            height: (screen.height - 48).clamp(300.0, 560.0),
            child: Column(children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 18, 12, 8),
                child: Row(children: [
                  Expanded(child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: c.text))),
                  IconButton(onPressed: () => Navigator.pop(ctx), icon: const Icon(Icons.close)),
                ]),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: TextField(
                  autofocus: true,
                  decoration: const InputDecoration(hintText: 'Search…', prefixIcon: Icon(Icons.search)),
                  onChanged: (v) => setState(() => q = v),
                  onSubmitted: (_) {
                    if (filtered.isNotEmpty) Navigator.pop(ctx, filtered.first);
                  },
                ),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: filtered.isEmpty
                    ? Center(child: Text('Nothing found', style: TextStyle(color: c.textMuted)))
                    : ListView.builder(
                        itemCount: filtered.length,
                        itemBuilder: (_, k) => ListTile(
                          title: Text(label(filtered[k])),
                          subtitle: subtitle == null ? null : Text(subtitle(filtered[k]), style: TextStyle(color: c.textMuted, fontSize: 12)),
                          trailing: trailing?.call(filtered[k]),
                          onTap: () => Navigator.pop(ctx, filtered[k]),
                        ),
                      ),
              ),
              if (footer != null) Padding(padding: const EdgeInsets.all(12), child: footer),
            ]),
          ),
        );
      });
    },
  );
}

/// Simple single-text prompt (e.g. "Reason for cancellation").
Future<String?> promptText(BuildContext context, {required String title, required String label, String initial = '', bool required = true, int maxLines = 1, String confirm = 'OK'}) {
  final ctl = TextEditingController(text: initial);
  final key = GlobalKey<FormState>();
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      scrollable: true,
      title: Text(title),
      content: SizedBox(
        width: 420,
        child: Form(
          key: key,
          child: TextFormField(
            controller: ctl,
            autofocus: true,
            maxLines: maxLines,
            decoration: InputDecoration(labelText: label),
            validator: (v) => required && (v ?? '').trim().isEmpty ? 'Required' : null,
            onFieldSubmitted: maxLines == 1 ? (_) {
              if (key.currentState!.validate()) Navigator.pop(ctx, ctl.text.trim());
            } : null,
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(
            onPressed: () {
              if (key.currentState!.validate()) Navigator.pop(ctx, ctl.text.trim());
            },
            child: Text(confirm)),
      ],
    ),
  );
}

/// Generic modal form shell with title, scrollable body and action row.
///
/// Responsive: the dialog never gets wider than the window allows, the body
/// scrolls when the window is short, and the action buttons wrap onto a
/// second line (right-aligned) instead of overflowing on narrow windows.
class FormDialog extends StatelessWidget {
  final String title;
  final Widget body;
  final List<Widget> actions;
  final double width;
  final Widget? headerTrailing;
  const FormDialog({super.key, required this.title, required this.body, required this.actions, this.width = 640, this.headerTrailing});

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.of(context);
    final size = MediaQuery.sizeOf(context);
    final compact = size.width < 700;
    return Dialog(
      insetPadding: EdgeInsets.symmetric(horizontal: compact ? 12 : 40, vertical: size.height < 600 ? 12 : 24),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: width, maxHeight: size.height * (size.height < 600 ? 0.96 : 0.9)),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 20, 14, 8),
            child: Row(children: [
              Expanded(child: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: c.text))),
              if (headerTrailing != null) Flexible(child: Padding(padding: const EdgeInsets.only(left: 8), child: headerTrailing!)),
              IconButton(tooltip: 'Close (Esc)', onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close)),
            ]),
          ),
          Flexible(child: SingleChildScrollView(padding: const EdgeInsets.fromLTRB(24, 8, 24, 8), child: body)),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 10, 24, 20),
            child: OverflowBar(
              alignment: MainAxisAlignment.end,
              overflowAlignment: OverflowBarAlignment.end,
              spacing: 10,
              overflowSpacing: 8,
              children: actions,
            ),
          ),
        ]),
      ),
    );
  }
}

/// Dropdown form field that always fits its parent.
///
/// Flutter's DropdownButtonFormField sizes itself to its *widest* item unless
/// `isExpanded` is set, which overflows inside narrow panels (the POS bill
/// panel, filter bars, dialogs). This wrapper expands to the available width,
/// shows the selected value on one line with an ellipsis, and lets the
/// open menu show every option in full (wrapping if needed).
class AppDropdown<T> extends StatelessWidget {
  final T? value;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?>? onChanged;
  final InputDecoration? decoration;
  final bool isDense;
  final String? Function(T?)? validator;
  final double? menuMaxHeight;
  const AppDropdown({super.key, required this.value, required this.items, required this.onChanged, this.decoration, this.isDense = true, this.validator, this.menuMaxHeight = 420});

  @override
  Widget build(BuildContext context) => DropdownButtonFormField<T>(
        initialValue: value,
        items: items,
        onChanged: onChanged,
        validator: validator,
        decoration: decoration ?? const InputDecoration(),
        isDense: isDense,
        isExpanded: true,
        menuMaxHeight: menuMaxHeight,
        selectedItemBuilder: (_) => [
          for (final it in items)
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: DefaultTextStyle.merge(maxLines: 1, softWrap: false, overflow: TextOverflow.ellipsis, child: it.child),
            ),
        ],
      );
}

/// Compact dropdown (no form decoration) that never overflows its slot.
class AppDropdownButton<T> extends StatelessWidget {
  final T? value;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?>? onChanged;
  const AppDropdownButton({super.key, required this.value, required this.items, required this.onChanged});

  @override
  Widget build(BuildContext context) => DropdownButton<T>(
        value: value,
        items: items,
        onChanged: onChanged,
        menuMaxHeight: 420,
        selectedItemBuilder: (_) => [
          for (final it in items)
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: DefaultTextStyle.merge(maxLines: 1, softWrap: false, overflow: TextOverflow.ellipsis, child: it.child),
            ),
        ],
      );
}

/// Label / value row for detail panes.
class InfoRow extends StatelessWidget {
  final String label;
  final String value;
  final bool strong;
  final Color? color;
  const InfoRow(this.label, this.value, {super.key, this.strong = false, this.color});
  @override
  Widget build(BuildContext context) {
    final c = AppTheme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(flex: 2, child: Text(label, style: TextStyle(color: c.textMuted))),
        const SizedBox(width: 12),
        Flexible(
          flex: 3,
          child: Text(value,
              textAlign: TextAlign.right,
              style: TextStyle(color: color ?? c.text, fontWeight: strong ? FontWeight.w700 : FontWeight.w500, fontSize: strong ? 16 : 14)),
        ),
      ]),
    );
  }
}

/// From/To date selection with quick presets.
class DateRangeBar extends StatelessWidget {
  final DateTime from;
  final DateTime to;
  final void Function(DateTime from, DateTime to) onChanged;
  const DateRangeBar({super.key, required this.from, required this.to, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    DateTime d(DateTime x) => DateTime(x.year, x.month, x.day);
    final presets = <String, (DateTime, DateTime)>{
      'Today': (d(now), now),
      'This Week': (d(now.subtract(Duration(days: now.weekday - 1))), now),
      'This Month': (DateTime(now.year, now.month), now),
      'Last Month': (DateTime(now.year, now.month - 1), DateTime(now.year, now.month, 0, 23, 59, 59)),
      'This Year': (DateTime(now.year), now),
    };
    return Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
      for (final e in presets.entries) ActionChip(label: Text(e.key), onPressed: () => onChanged(e.value.$1, e.value.$2)),
      OutlinedButton.icon(
        icon: const Icon(Icons.date_range, size: 18),
        label: Text('${dateFmt.format(from)} – ${dateFmt.format(to)}'),
        onPressed: () async {
          final r = await showDateRangePicker(context: context, firstDate: DateTime(2020), lastDate: DateTime(now.year + 1), initialDateRange: DateTimeRange(start: from, end: to));
          if (r != null) onChanged(r.start, DateTime(r.end.year, r.end.month, r.end.day, 23, 59, 59));
        },
      ),
    ]);
  }
}

/// Debounces rapid text changes (search boxes on big lists).
class Debouncer {
  final Duration delay;
  Timer? _t;
  Debouncer([this.delay = const Duration(milliseconds: 200)]);
  void call(void Function() f) {
    _t?.cancel();
    _t = Timer(delay, f);
  }

  void dispose() => _t?.cancel();
}
