import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:printing/printing.dart';

import '../domain/models/operations.dart';
import '../export/tabular.dart';
import '../printing/pdf_docs.dart';
import 'providers.dart';
import 'theme.dart';
import 'widgets/common.dart';
import 'widgets/file_browser.dart';

/// Shows a PDF preview with Print, Quick print (to the configured printer)
/// and Save as PDF. Works offline; a missing printer is reported, not fatal.
Future<void> showPdf(BuildContext context, AppSettings st, Future<Uint8List> Function() build, {required String name}) async {
  final Uint8List bytes;
  try {
    bytes = await build();
  } catch (e) {
    if (context.mounted) showToast(context, 'Could not create the document: $e', error: true);
    return;
  }
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (ctx) {
      final c = AppTheme.of(ctx);
      final screen = MediaQuery.sizeOf(ctx);
      final narrow = screen.width < 760;
      return Dialog(
        insetPadding: EdgeInsets.all(screen.width < 1000 ? 12 : 32),
        child: SizedBox(
          width: 820,
          height: screen.height * 0.92,
          child: Column(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 10, 8),
              child: Row(children: [
                Icon(Icons.picture_as_pdf_outlined, color: c.accent),
                const SizedBox(width: 10),
                Expanded(child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontWeight: FontWeight.w700, color: c.text, fontSize: 16))),
                // Long printer names are truncated (tooltip shows the full
                // name); on narrow windows the buttons become icons.
                if ((st.printerName ?? '').isNotEmpty)
                  Tooltip(
                    message: 'Print to ${st.printerName}',
                    child: narrow
                        ? IconButton.filled(onPressed: () => quickPrint(ctx, st, bytes, name: name), icon: const Icon(Icons.print, size: 18))
                        : FilledButton.icon(
                            onPressed: () => quickPrint(ctx, st, bytes, name: name),
                            icon: const Icon(Icons.print, size: 18),
                            label: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 200),
                              child: Text('Print to ${st.printerName}', maxLines: 1, overflow: TextOverflow.ellipsis),
                            ),
                          ),
                  ),
                const SizedBox(width: 8),
                narrow
                    ? IconButton.outlined(tooltip: 'Print…', onPressed: () => printWithDialog(ctx, bytes, name: name), icon: const Icon(Icons.print_outlined, size: 18))
                    : OutlinedButton.icon(onPressed: () => printWithDialog(ctx, bytes, name: name), icon: const Icon(Icons.print_outlined, size: 18), label: const Text('Print…')),
                const SizedBox(width: 8),
                narrow
                    ? IconButton.outlined(tooltip: 'Save PDF', onPressed: () => savePdf(ctx, bytes, name: name), icon: const Icon(Icons.save_alt, size: 18))
                    : OutlinedButton.icon(onPressed: () => savePdf(ctx, bytes, name: name), icon: const Icon(Icons.save_alt, size: 18), label: const Text('Save PDF')),
                IconButton(onPressed: () => Navigator.pop(ctx), icon: const Icon(Icons.close)),
              ]),
            ),
            const Divider(height: 1),
            Expanded(
              child: PdfPreview(
                build: (_) async => bytes,
                useActions: false,
                canChangeOrientation: false,
                canChangePageFormat: false,
                canDebug: false,
                allowSharing: false,
                allowPrinting: false,
                pdfFileName: '$name.pdf',
                loadingWidget: const Center(child: CircularProgressIndicator()),
                onError: (_, e) => Center(child: Text('Preview not available. You can still print or save. ($e)')),
              ),
            ),
          ]),
        ),
      );
    },
  );
}

Future<void> printWithDialog(BuildContext context, Uint8List bytes, {required String name}) async {
  try {
    await Printing.layoutPdf(onLayout: (_) async => bytes, name: name, usePrinterSettings: true);
  } catch (e) {
    if (context.mounted) showToast(context, 'Printing is not available: $e', error: true);
  }
}

/// Prints straight to the printer chosen in Settings (e.g. the thermal printer).
Future<bool> quickPrint(BuildContext context, AppSettings st, Uint8List bytes, {required String name}) async {
  try {
    final printers = await Printing.listPrinters();
    final target = printers.where((p) => p.name == st.printerName || p.url == st.printerName).toList();
    if (target.isEmpty) {
      if (context.mounted) showToast(context, 'Printer "${st.printerName}" is not connected. Opening the print dialog instead.', error: true);
      if (context.mounted) await printWithDialog(context, bytes, name: name);
      return false;
    }
    final ok = await Printing.directPrintPdf(printer: target.first, onLayout: (_) async => bytes, name: name, usePrinterSettings: true);
    if (context.mounted && ok) showToast(context, 'Sent to ${target.first.name}');
    return ok;
  } catch (e) {
    if (context.mounted) showToast(context, 'Could not print: $e', error: true);
    return false;
  }
}

Future<void> savePdf(BuildContext context, Uint8List bytes, {required String name}) async {
  final path = await browseFiles(context, mode: BrowseMode.saveFile, title: 'Save PDF', suggestedName: '${_safe(name)}.pdf');
  if (path == null || !context.mounted) return;
  await _write(context, path.endsWith('.pdf') ? path : '$path.pdf', bytes);
}

Future<void> exportTable(BuildContext context, ExportTable table, {required String format}) async {
  final ext = format == 'csv' ? '.csv' : '.xlsx';
  final path = await browseFiles(context, mode: BrowseMode.saveFile, title: 'Export ${format.toUpperCase()}', suggestedName: '${_safe(table.title)}$ext');
  if (path == null || !context.mounted) return;
  // Built on a background isolate: large reports take a while to encode.
  final List<int> bytes;
  try {
    bytes = await encodeTableInBackground(table, format: format);
  } catch (e) {
    if (context.mounted) showToast(context, 'Could not create the file: $e', error: true);
    return;
  }
  if (!context.mounted) return;
  await _write(context, path.endsWith(ext) ? path : '$path$ext', bytes);
}

List<int> buildCsvBytes(ExportTable t) => utf8.encode(buildCsv(t));

/// CSV or XLSX bytes of [t], encoded on a background isolate.
Future<List<int>> encodeTableInBackground(ExportTable t, {required String format, String heading = ''}) =>
    Isolate.run(() => format == 'csv' ? buildCsvBytes(t) : buildXlsx([t], heading: heading));

/// Workbook bytes (one sheet per table), encoded on a background isolate.
Future<List<int>> encodeWorkbookInBackground(List<ExportTable> tables, {String heading = ''}) =>
    Isolate.run(() => buildXlsx(tables, heading: heading));

/// What an Export / Print menu can do with the records on screen.
enum ExportAction {
  excel('Export to Excel (.xlsx)', Icons.table_view),
  pdf('Export to PDF', Icons.picture_as_pdf_outlined),
  print('Print…', Icons.print_outlined),
  preview('Print preview', Icons.preview_outlined),
  csv('Export CSV', Icons.description_outlined);

  final String label;
  final IconData icon;
  const ExportAction(this.label, this.icon);
}

/// Runs [action] for [tables] (the first is the main one; Excel gets one
/// worksheet per table, PDF one section per table). Files are saved where
/// the user chooses; heavy work runs on a background isolate while a
/// progress indicator shows.
Future<void> runExport(
  BuildContext context,
  AppSettings st,
  List<ExportTable> tables,
  ExportAction action, {
  required String name,
  bool landscape = false,
}) async {
  if (tables.isEmpty) return;
  if (tables.every((t) => t.rows.isEmpty) && action != ExportAction.preview) {
    final go = await confirmDialog(context, title: 'No records', message: 'There are no records to export with the current filters. Create an empty report anyway?', confirm: 'Continue');
    if (!go || !context.mounted) return;
  }
  final heading = st.businessName;
  Future<Uint8List> pdf() => reportPdfMultiInBackground(st, tables, landscape: landscape);
  switch (action) {
    case ExportAction.preview:
      await showPdf(context, st, pdf, name: name);
    case ExportAction.print:
      final bytes = await _withProgress(context, 'Preparing $name…', pdf);
      if (bytes != null && context.mounted) await printWithDialog(context, bytes, name: name);
    case ExportAction.pdf:
      final path = await browseFiles(context, mode: BrowseMode.saveFile, title: 'Save PDF', suggestedName: '${_safe(name)}.pdf');
      if (path == null || !context.mounted) return;
      final bytes = await _withProgress(context, 'Creating PDF…', pdf);
      if (bytes != null && context.mounted) await _write(context, path.toLowerCase().endsWith('.pdf') ? path : '$path.pdf', bytes);
    case ExportAction.excel:
    case ExportAction.csv:
      final ext = action == ExportAction.csv ? '.csv' : '.xlsx';
      final path = await browseFiles(context, mode: BrowseMode.saveFile, title: action.label, suggestedName: '${_safe(name)}$ext');
      if (path == null || !context.mounted) return;
      final bytes = await _withProgress(
        context,
        'Creating file…',
        () => action == ExportAction.csv ? encodeTableInBackground(tables.first, format: 'csv') : encodeWorkbookInBackground(tables, heading: heading),
      );
      if (bytes != null && context.mounted) await _write(context, path.toLowerCase().endsWith(ext) ? path : '$path$ext', bytes);
  }
}

/// Shows a small progress dialog while [work] runs (the window stays
/// responsive: the work itself runs on a background isolate).
Future<T?> _withProgress<T>(BuildContext context, String text, Future<T> Function() work) async {
  var open = true;
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => AlertDialog(content: Row(children: [const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5)), const SizedBox(width: 16), Flexible(child: Text(text))])),
  ).whenComplete(() => open = false);
  try {
    return await work();
  } catch (e) {
    if (context.mounted) showToast(context, 'Could not create the document: $e', error: true);
    return null;
  } finally {
    if (open && context.mounted) Navigator.of(context, rootNavigator: true).pop();
  }
}

/// "Export / Print" button for a module screen: Excel, PDF, Print, Print
/// preview of exactly the records currently shown.
class ExportMenu extends StatelessWidget {
  final List<ExportTable> Function() tables;
  final String? name; // default: the first table's title
  final AppSettings Function()? settings;
  final bool landscape;
  final bool csv;
  const ExportMenu({super.key, required this.tables, this.name, this.settings, this.landscape = false, this.csv = false});

  @override
  Widget build(BuildContext context) => PopupMenuButton<ExportAction>(
        key: const ValueKey('export-menu'),
        tooltip: 'Export to Excel / PDF, print',
        onSelected: (a) {
          final ts = tables();
          final st = settings?.call() ?? ProviderScope.containerOf(context).read(servicesProvider).ctx.settings;
          runExport(context, st, ts, a, name: name ?? (ts.isEmpty ? 'Export' : ts.first.title), landscape: landscape || (ts.isNotEmpty && ts.first.headers.length > 6));
        },
        itemBuilder: (_) => [
          for (final a in ExportAction.values)
            if (a != ExportAction.csv || csv) PopupMenuItem(value: a, child: Row(children: [Icon(a.icon, size: 18), const SizedBox(width: 10), Text(a.label)])),
        ],
        child: IgnorePointer(
          child: OutlinedButton.icon(onPressed: () {}, icon: const Icon(Icons.ios_share, size: 18), label: const Text('Export / Print')),
        ),
      );
}

Future<void> _write(BuildContext context, String path, List<int> bytes) async {
  try {
    await File(path).writeAsBytes(bytes, flush: true);
    if (context.mounted) showToast(context, 'Saved to $path');
  } catch (e) {
    if (context.mounted) showToast(context, 'Could not save file: $e', error: true);
  }
}

String _safe(String s) => s.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');

/// Lists printer names for the Settings screen.
Future<List<String>> availablePrinters() async {
  try {
    return (await Printing.listPrinters()).map((p) => p.name).toList();
  } catch (_) {
    return [];
  }
}
