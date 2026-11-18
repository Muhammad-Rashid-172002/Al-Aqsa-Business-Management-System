import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../domain/services/app_services.dart';
import '../../domain/services/serial_service.dart';
import '../../export/tabular.dart';
import '../theme.dart';
import 'common.dart';
import 'file_browser.dart';
import 'forms.dart';

/// Result of [showSerialEntry]: how many units, and one serial per unit.
class SerialEntryResult {
  final int quantity;
  final List<String> serials; // normalized
  const SerialEntryResult(this.quantity, this.serials);
}

/// Serial-number entry for a batch of identical units of one product:
/// scan (USB scanner, Enter or Tab after each code), type, paste a list or
/// import CSV / Excel. Shows Required / Entered / Remaining and checks every
/// entry live (format, repeats, already registered, product barcodes).
/// Only returns when the list is complete and has no blocking problems.
Future<SerialEntryResult?> showSerialEntry(
  BuildContext context, {
  required AppServices app,
  required String productName,
  required String brandKey,
  String? productId,
  int quantity = 0,
  List<String> initial = const [],
}) =>
    showDialog<SerialEntryResult>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _SerialEntry(app: app, productName: productName, brandKey: brandKey, productId: productId, quantity: quantity, initial: initial),
    );

class _SerialEntry extends StatefulWidget {
  final AppServices app;
  final String productName;
  final String brandKey;
  final String? productId;
  final int quantity;
  final List<String> initial;
  const _SerialEntry({required this.app, required this.productName, required this.brandKey, this.productId, required this.quantity, required this.initial});
  @override
  State<_SerialEntry> createState() => _SerialEntryState();
}

class _SerialEntryState extends State<_SerialEntry> {
  late final _qty = TextEditingController(text: widget.quantity > 0 ? '${widget.quantity}' : '');
  final _scan = TextEditingController();
  final _scanFocus = FocusNode();
  late List<String> _entries = [...widget.initial];
  List<SerialCheck> _checks = const [];

  @override
  void initState() {
    super.initState();
    _recheck();
  }

  @override
  void dispose() {
    _qty.dispose();
    _scan.dispose();
    _scanFocus.dispose();
    super.dispose();
  }

  int get _required => int.tryParse(_qty.text.trim()) ?? 0;

  void _recheck() => _checks = widget.app.serials.checkNew(_entries, brandKey: widget.brandKey, productId: widget.productId);

  void _addAll(List<String> items) {
    if (items.isEmpty) return;
    setState(() {
      _entries = [..._entries, ...items];
      // No quantity typed yet: the list decides it.
      if (_qty.text.trim().isEmpty || _required == 0) _qty.text = '${_entries.length}';
      _recheck();
    });
  }

  void _submitScan() {
    final items = SerialService.splitEntries(_scan.text);
    _scan.clear();
    _addAll(items);
    _scanFocus.requestFocus();
  }

  Future<void> _paste() async {
    final ctl = TextEditingController();
    final clip = await Clipboard.getData(Clipboard.kTextPlain);
    ctl.text = clip?.text ?? '';
    if (!mounted) return;
    final text = await showDialog<String>(
      context: context,
      builder: (ctx) => FormDialog(
        title: 'Paste serial numbers',
        width: 520,
        body: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Text('One serial per line (commas, semicolons and tabs also separate).'),
          const SizedBox(height: 10),
          TextField(key: const ValueKey('serial-paste'), controller: ctl, autofocus: true, maxLines: 12, style: const TextStyle(fontFamily: 'Consolas')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctl.text), child: const Text('Add to list')),
        ],
      ),
    );
    ctl.dispose();
    if (text != null) _addAll(SerialService.splitEntries(text));
  }

  Future<void> _import() async {
    final path = await browseFiles(context, mode: BrowseMode.openFile, title: 'Serial numbers file (Excel, CSV or text)', extensions: const ['.xlsx', '.csv', '.txt']);
    if (path == null || !mounted) return;
    try {
      final bytes = await File(path).readAsBytes();
      final lower = path.toLowerCase();
      final List<String> items;
      if (lower.endsWith('.xlsx')) {
        items = serialsFromTable(readXlsx(bytes));
      } else if (lower.endsWith('.csv')) {
        items = serialsFromTable(parseCsv(utf8.decode(bytes, allowMalformed: true)));
      } else {
        items = SerialService.splitEntries(utf8.decode(bytes, allowMalformed: true));
      }
      if (items.isEmpty) throw const FormatException('No serial numbers found in the file.');
      _addAll(items);
      if (mounted) showToast(context, '${items.length} serial number(s) imported from the file.');
    } catch (e) {
      if (mounted) showToast(context, 'Could not import: $e', error: true);
    }
  }

  void _remove(int i) => setState(() {
        _entries = [..._entries]..removeAt(i);
        _recheck();
      });

  void _removeProblems() => setState(() {
        _entries = [
          for (var i = 0; i < _entries.length; i++)
            if (!_checks[i].blocking) _entries[i],
        ];
        _recheck();
      });

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.of(context);
    final entered = _checks.where((x) => !x.blocking).length;
    final blocking = _checks.where((x) => x.blocking).length;
    final warnings = _checks.where((x) => !x.ok && !x.blocking).length;
    final req = _required;
    final remaining = req - entered;
    final complete = req > 0 && remaining == 0 && blocking == 0;
    final progress = req <= 0 ? 0.0 : (entered / req).clamp(0.0, 1.0);
    Widget counter(String label, String value, Color color, String key) => Expanded(
          child: Container(
            key: ValueKey(key),
            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
            decoration: BoxDecoration(color: color.withValues(alpha: 0.10), borderRadius: BorderRadius.circular(10), border: Border.all(color: color.withValues(alpha: 0.35))),
            child: Column(children: [
              Text(value, style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: color)),
              Text(label, style: TextStyle(color: c.textMuted, fontSize: 12)),
            ]),
          ),
        );
    return FormDialog(
      title: 'Serial numbers • ${widget.productName}',
      width: 640,
      body: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(
            width: 170,
            child: TextField(
              key: const ValueKey('serial-required'),
              controller: _qty,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(labelText: 'Quantity (units)'),
              onChanged: (_) => setState(() {}),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Focus(
              // Scanners that send Tab after the code: add it, keep focus here.
              onKeyEvent: (_, e) {
                if (e is KeyDownEvent && e.logicalKey == LogicalKeyboardKey.tab && _scan.text.trim().isNotEmpty) {
                  _submitScan();
                  return KeyEventResult.handled;
                }
                return KeyEventResult.ignored;
              },
              child: TextField(
                key: const ValueKey('serial-scan'),
                controller: _scan,
                focusNode: _scanFocus,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'Scan or type a serial and press Enter', prefixIcon: Icon(Icons.qr_code_scanner)),
                onSubmitted: (_) => _submitScan(),
              ),
            ),
          ),
        ]),
        const SizedBox(height: 10),
        Wrap(spacing: 8, runSpacing: 8, children: [
          OutlinedButton.icon(onPressed: _paste, icon: const Icon(Icons.content_paste, size: 18), label: const Text('Paste list')),
          OutlinedButton.icon(onPressed: _import, icon: const Icon(Icons.upload_file, size: 18), label: const Text('Import CSV / Excel')),
          if (blocking > 0)
            TextButton.icon(onPressed: _removeProblems, icon: const Icon(Icons.cleaning_services_outlined, size: 18), label: Text('Remove $blocking invalid / repeated')),
          if (_entries.isNotEmpty)
            TextButton.icon(
              onPressed: () => setState(() {
                _entries = [];
                _recheck();
              }),
              icon: const Icon(Icons.clear_all, size: 18),
              label: const Text('Clear list'),
            ),
        ]),
        const SizedBox(height: 14),
        Row(children: [
          counter('Required', '$req', c.text, 'serial-count-required'),
          const SizedBox(width: 10),
          counter('Entered', '$entered', c.accent, 'serial-count-entered'),
          const SizedBox(width: 10),
          counter('Remaining', '${remaining < 0 ? 0 : remaining}', remaining == 0 && req > 0 ? c.accent : c.warning, 'serial-count-remaining'),
        ]),
        const SizedBox(height: 8),
        ClipRRect(borderRadius: BorderRadius.circular(4), child: LinearProgressIndicator(value: progress, minHeight: 6)),
        const SizedBox(height: 8),
        if (remaining < 0) Text('${-remaining} more serial(s) than the quantity. Remove extras or raise the quantity.', style: TextStyle(color: c.danger)),
        if (blocking > 0) Text('$blocking entr${blocking == 1 ? 'y needs' : 'ies need'} fixing (shown in red).', style: TextStyle(color: c.danger)),
        if (warnings > 0)
          Text('$warnings serial(s) already exist (amber). Saving asks the owner to confirm they are genuinely different units.', style: TextStyle(color: c.warning)),
        const SizedBox(height: 8),
        Container(
          height: 260,
          decoration: BoxDecoration(border: Border.all(color: c.border), borderRadius: BorderRadius.circular(10)),
          child: _entries.isEmpty
              ? Center(child: Text('No serial numbers yet.\nScan each unit, paste a list or import a file.', textAlign: TextAlign.center, style: TextStyle(color: c.textMuted)))
              : ListView.builder(
                  itemCount: _entries.length,
                  itemBuilder: (_, i) {
                    final ch = _checks[i];
                    final color = ch.ok ? c.accent : (ch.blocking ? c.danger : c.warning);
                    return ListTile(
                      dense: true,
                      leading: Text('${i + 1}', style: TextStyle(color: c.textMuted, fontFamily: 'Consolas')),
                      title: Text(ch.serial.isEmpty ? '(empty)' : ch.serial, style: const TextStyle(fontFamily: 'Consolas')),
                      subtitle: ch.ok ? null : Text(ch.message, style: TextStyle(color: color, fontSize: 12)),
                      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                        Icon(ch.ok ? Icons.check_circle : (ch.blocking ? Icons.error : Icons.warning_amber), color: color, size: 18),
                        IconButton(tooltip: 'Remove', onPressed: () => _remove(i), icon: const Icon(Icons.close, size: 18)),
                      ]),
                    );
                  },
                ),
        ),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          key: const ValueKey('serial-done'),
          onPressed: complete ? () => Navigator.pop(context, SerialEntryResult(req, [for (final x in _checks) x.serial])) : null,
          child: Text(complete ? 'Use $req serial(s)' : (req <= 0 ? 'Enter the quantity' : '$entered of $req entered')),
        ),
      ],
    );
  }
}
