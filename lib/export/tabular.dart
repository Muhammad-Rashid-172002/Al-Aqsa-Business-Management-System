import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

/// A table for export: header + rows (+ totals). Keep values typed: numbers
/// stay numbers and dates stay [DateTime] so Excel can sum, sort and filter.
/// [info] lines (period, filters) are printed under the title.
class ExportTable {
  final String title;
  final List<String> headers;
  final List<List<Object?>> rows;
  final List<List<Object?>> footer;
  final List<String> info;
  const ExportTable(this.title, this.headers, this.rows, {this.footer = const [], this.info = const []});

  ExportTable withInfo(List<String> lines) => ExportTable(title, headers, rows, footer: footer, info: lines);
  bool get isEmpty => rows.isEmpty;
}

/// How a cell is shown in CSV, PDF and on screen.
String exportCellText(Object? v) {
  if (v == null) return '';
  if (v is DateTime) {
    final d = '${v.day.toString().padLeft(2, '0')}/${v.month.toString().padLeft(2, '0')}/${v.year}';
    return (v.hour == 0 && v.minute == 0) ? d : '$d ${v.hour.toString().padLeft(2, '0')}:${v.minute.toString().padLeft(2, '0')}';
  }
  if (v is double) return v.toStringAsFixed(2);
  return v.toString();
}

/// Columns whose decimal numbers are quantities / percentages, not money.
final _notMoney = RegExp(r'(qty|available|issued|inspection|damaged|minimum|change|before|after|held|stock$|^stock|%|margin|share|entries|days|units|invoices|months|items|serial numbers)', caseSensitive: false);

/// Column type used for formatting.
enum _Col { text, money, number, integer, date, dateTime }

List<_Col> _columnTypes(ExportTable t) {
  final out = <_Col>[];
  for (var c = 0; c < t.headers.length; c++) {
    var type = _Col.text;
    var dateTime = false;
    for (final r in [...t.rows, ...t.footer]) {
      if (c >= r.length || r[c] == null) continue;
      final v = r[c];
      if (v is DateTime) {
        type = _Col.date;
        if (v.hour != 0 || v.minute != 0) dateTime = true;
      } else if (v is double) {
        type = _notMoney.hasMatch(t.headers[c]) ? _Col.number : _Col.money;
      } else if (v is int && type == _Col.text) {
        type = _Col.integer;
      }
      if (type == _Col.money || type == _Col.number || type == _Col.date) break;
    }
    if (type == _Col.date && dateTime) type = _Col.dateTime;
    if (type == _Col.integer && RegExp(r'(amount|total|price|cost|value|balance|paid|sales|profit|discount|expense|received|debit|credit)', caseSensitive: false).hasMatch(t.headers[c])) {
      type = _Col.money;
    }
    out.add(type);
  }
  return out;
}

// ───────────────────────── XLSX (Office Open XML) ─────────────────────────

String _esc(String s) => const HtmlEscape(HtmlEscapeMode.element)
    .convert(s.replaceAll(RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F]'), ' '))
    .replaceAll('"', '&quot;');

String _col(int index) {
  var n = index + 1;
  var s = '';
  while (n > 0) {
    final r = (n - 1) % 26;
    s = String.fromCharCode(65 + r) + s;
    n = (n - 1) ~/ 26;
  }
  return s;
}

int _colIndex(String letters) {
  var n = 0;
  for (final ch in letters.codeUnits) {
    n = n * 26 + (ch - 64);
  }
  return n - 1;
}

/// Excel serial date (days since 30 Dec 1899), ignoring time zones.
double _excelDate(DateTime d) =>
    DateTime.utc(d.year, d.month, d.day, d.hour, d.minute, d.second).difference(DateTime.utc(1899, 12, 30)).inMilliseconds / 86400000;

// Style indexes (see styles.xml below).
const _sHeading = 2, _sTitle = 3, _sInfo = 4, _sHead = 5, _sMoney = 6, _sNum = 7, _sDate = 8, _sDateTime = 9, _sText = 10;
const _sFootText = 11, _sFootMoney = 12, _sFootNum = 13, _sNum2 = 14, _sFootNum2 = 15, _sInt = 16, _sFootInt = 17;

/// Row number (1-based) of the column header in a sheet for [t].
int _headerRow(ExportTable t, String heading) => (heading.isEmpty ? 0 : 1) + (t.title.isEmpty ? 0 : 1) + 1 + t.info.length + 1 + 1;

String _sheetXml(ExportTable t, {required String heading, required DateTime generated}) {
  final types = _columnTypes(t);
  final ncol = t.headers.isEmpty ? 1 : t.headers.length;
  // Column widths from the longest text (header or cell), money a bit wider.
  final widths = List<double>.generate(ncol, (c) => c < t.headers.length ? t.headers[c].length + 2.0 : 10.0);
  for (final r in [...t.rows.take(2000), ...t.footer]) {
    for (var c = 0; c < ncol && c < r.length; c++) {
      if (r == t.footer.firstOrNull && c == 0) continue; // long notes in totals
      final len = switch (types[c]) {
        _Col.money => exportCellText(r[c]).length + 6.0,
        _Col.date => 12.0,
        _Col.dateTime => 17.0,
        _ => exportCellText(r[c]).length + 2.0,
      };
      if (len > widths[c]) widths[c] = len;
    }
  }
  final hr = _headerRow(t, heading);
  final b = StringBuffer('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
      '<sheetViews><sheetView workbookViewId="0"><pane ySplit="$hr" topLeftCell="A${hr + 1}" activePane="bottomLeft" state="frozen"/></sheetView></sheetViews>'
      '<cols>');
  for (var c = 0; c < ncol; c++) {
    b.write('<col min="${c + 1}" max="${c + 1}" width="${widths[c].clamp(8, 60).toStringAsFixed(1)}" customWidth="1"/>');
  }
  b.write('</cols><sheetData>');
  var r = 1;
  void cell(int c, Object? v, int style) {
    final ref = '${_col(c)}$r';
    if (v == null) {
      if (style != 0) b.write('<c r="$ref" s="$style"/>');
      return;
    }
    if (v is DateTime) {
      b.write('<c r="$ref" s="$style"><v>${_excelDate(v)}</v></c>');
    } else if (v is num) {
      final n = v is double && (v.isNaN || v.isInfinite) ? 0 : v;
      b.write('<c r="$ref" s="$style"><v>$n</v></c>');
    } else {
      b.write('<c r="$ref" t="inlineStr" s="$style"><is><t xml:space="preserve">${_esc(v.toString())}</t></is></c>');
    }
  }

  void line(String text, int style) {
    b.write('<row r="$r">');
    cell(0, text, style);
    b.write('</row>');
    r++;
  }

  int dataStyle(int c, Object? v, {bool footer = false}) {
    if (v is String || v == null) return footer ? _sFootText : _sText;
    if (v is DateTime) return types[c] == _Col.dateTime ? _sDateTime : _sDate;
    return switch (types[c]) {
      _Col.money => footer ? _sFootMoney : _sMoney,
      _Col.number => footer ? _sFootNum2 : _sNum2,
      _Col.integer => footer ? _sFootInt : _sInt,
      _ => v is int ? (footer ? _sFootInt : _sInt) : (footer ? _sFootNum : _sNum),
    };
  }

  if (heading.isNotEmpty) line(heading, _sHeading);
  if (t.title.isNotEmpty) line(t.title, _sTitle);
  String two(int v) => v.toString().padLeft(2, '0');
  final g = generated;
  line('Generated: ${two(g.day)}/${two(g.month)}/${g.year} ${two(g.hour)}:${two(g.minute)}', _sInfo);
  for (final i in t.info) {
    line(i, _sInfo);
  }
  r++; // blank row
  assert(r == hr);
  b.write('<row r="$r">');
  for (var c = 0; c < t.headers.length; c++) {
    cell(c, t.headers[c], _sHead);
  }
  b.write('</row>');
  r++;
  final firstData = r;
  for (final x in t.rows) {
    b.write('<row r="$r">');
    for (var c = 0; c < x.length; c++) {
      cell(c, x[c], dataStyle(c, x[c]));
    }
    b.write('</row>');
    r++;
  }
  final lastData = r - 1;
  if (t.rows.isEmpty) line('No records match this report.', _sInfo);
  for (final x in t.footer) {
    b.write('<row r="$r">');
    for (var c = 0; c < x.length; c++) {
      cell(c, x[c], dataStyle(c, x[c], footer: true));
    }
    b.write('</row>');
    r++;
  }
  b.write('</sheetData>');
  if (t.rows.isNotEmpty && t.headers.isNotEmpty) {
    b.write('<autoFilter ref="A$hr:${_col(t.headers.length - 1)}$lastData"/>');
  }
  final landscape = ncol > 6;
  b.write('<pageMargins left="0.4" right="0.4" top="0.5" bottom="0.5" header="0.3" footer="0.3"/>'
      '<pageSetup paperSize="9" orientation="${landscape ? 'landscape' : 'portrait'}" fitToWidth="1" fitToHeight="0"/>'
      '<headerFooter><oddFooter>&amp;L${_esc(heading)}&amp;CPage &amp;P of &amp;N&amp;R${_esc(t.title)}</oddFooter></headerFooter>'
      '</worksheet>');
  // (firstData kept for readability of the layout above)
  assert(firstData == hr + 1);
  return b.toString();
}

/// Builds an .xlsx workbook (one worksheet per table) with a business
/// heading, title, generation time, period/filter lines, formatted header
/// row, PKR currency and date formats, column widths, frozen header,
/// auto-filter, bold totals and A4 print settings (header row repeated).
List<int> buildXlsx(List<ExportTable> tables, {String heading = '', DateTime? generated}) {
  final when = generated ?? DateTime.now();
  final names = <String>[];
  for (var k = 0; k < tables.length; k++) {
    var n = _sheetName(tables[k].title, k);
    var i = 2;
    while (names.contains(n)) {
      final suffix = ' ($i)';
      n = '${_sheetName(tables[k].title, k).substring(0, (_sheetName(tables[k].title, k).length).clamp(0, 31 - suffix.length))}$suffix';
      i++;
    }
    names.add(n);
  }
  String quoted(String n) => "'${n.replaceAll("'", "''")}'";
  final files = <String, String>{
    '[Content_Types].xml': '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
        '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
        '<Default Extension="xml" ContentType="application/xml"/>'
        '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>'
        '<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>'
        '<Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>'
        '${[for (var k = 0; k < tables.length; k++) '<Override PartName="/xl/worksheets/sheet${k + 1}.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>'].join()}'
        '</Types>',
    '_rels/.rels': '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>'
        '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>'
        '</Relationships>',
    'docProps/core.xml': '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/" '
        'xmlns:dcterms="http://purl.org/dc/terms/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">'
        '<dc:title>${_esc(tables.isEmpty ? '' : tables.first.title)}</dc:title><dc:creator>${_esc(heading)}</dc:creator>'
        '<dcterms:created xsi:type="dcterms:W3CDTF">${when.toUtc().toIso8601String().split('.').first}Z</dcterms:created>'
        '</cp:coreProperties>',
    'xl/workbook.xml': '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets>'
        '${[for (var k = 0; k < tables.length; k++) '<sheet name="${_esc(names[k])}" sheetId="${k + 1}" r:id="rId${k + 1}"/>'].join()}'
        '</sheets><definedNames>'
        '${[for (var k = 0; k < tables.length; k++) '<definedName name="_xlnm.Print_Titles" localSheetId="$k">${_esc(quoted(names[k]))}!\$${_headerRow(tables[k], heading)}:\$${_headerRow(tables[k], heading)}</definedName>'].join()}'
        '</definedNames></workbook>',
    'xl/_rels/workbook.xml.rels': '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '${[for (var k = 0; k < tables.length; k++) '<Relationship Id="rId${k + 1}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet${k + 1}.xml"/>'].join()}'
        '<Relationship Id="rId${tables.length + 1}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>'
        '</Relationships>',
    'xl/styles.xml': '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
        '<numFmts count="3">'
        '<numFmt numFmtId="164" formatCode="&quot;PKR &quot;#,##0.00;[Red]&quot;PKR -&quot;#,##0.00"/>'
        '<numFmt numFmtId="165" formatCode="dd/mm/yyyy"/>'
        '<numFmt numFmtId="166" formatCode="dd/mm/yyyy hh:mm"/>'
        '</numFmts>'
        '<fonts count="6">'
        '<font><sz val="11"/><name val="Calibri"/></font>'
        '<font><b/><sz val="11"/><name val="Calibri"/></font>'
        '<font><b/><sz val="16"/><color rgb="FF0B5D4B"/><name val="Calibri"/></font>'
        '<font><b/><sz val="13"/><name val="Calibri"/></font>'
        '<font><i/><sz val="10"/><color rgb="FF555555"/><name val="Calibri"/></font>'
        '<font><b/><sz val="11"/><color rgb="FFFFFFFF"/><name val="Calibri"/></font>'
        '</fonts>'
        '<fills count="4"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill>'
        '<fill><patternFill patternType="solid"><fgColor rgb="FF0B5D4B"/><bgColor indexed="64"/></patternFill></fill>'
        '<fill><patternFill patternType="solid"><fgColor rgb="FFE8F3EF"/><bgColor indexed="64"/></patternFill></fill></fills>'
        '<borders count="3"><border><left/><right/><top/><bottom/><diagonal/></border>'
        '<border><left/><right/><top/><bottom style="thin"><color rgb="FFD0D7DE"/></bottom><diagonal/></border>'
        '<border><left/><right/><top style="medium"><color rgb="FF0B5D4B"/></top><bottom style="medium"><color rgb="FF0B5D4B"/></bottom><diagonal/></border></borders>'
        '<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>'
        '<cellXfs count="18">'
        '<xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>' // 0
        '<xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/>' // 1
        '<xf numFmtId="0" fontId="2" fillId="0" borderId="0" xfId="0" applyFont="1"/>' // 2 heading
        '<xf numFmtId="0" fontId="3" fillId="0" borderId="0" xfId="0" applyFont="1"/>' // 3 title
        '<xf numFmtId="0" fontId="4" fillId="0" borderId="0" xfId="0" applyFont="1"/>' // 4 info
        '<xf numFmtId="0" fontId="5" fillId="2" borderId="0" xfId="0" applyFont="1" applyFill="1" applyAlignment="1"><alignment vertical="center" wrapText="1"/></xf>' // 5 header
        '<xf numFmtId="164" fontId="0" fillId="0" borderId="1" xfId="0" applyNumberFormat="1" applyBorder="1"/>' // 6 money
        '<xf numFmtId="0" fontId="0" fillId="0" borderId="1" xfId="0" applyBorder="1"/>' // 7 number
        '<xf numFmtId="165" fontId="0" fillId="0" borderId="1" xfId="0" applyNumberFormat="1" applyBorder="1" applyAlignment="1"><alignment horizontal="left"/></xf>' // 8 date
        '<xf numFmtId="166" fontId="0" fillId="0" borderId="1" xfId="0" applyNumberFormat="1" applyBorder="1" applyAlignment="1"><alignment horizontal="left"/></xf>' // 9 date-time
        '<xf numFmtId="0" fontId="0" fillId="0" borderId="1" xfId="0" applyBorder="1"/>' // 10 text
        '<xf numFmtId="0" fontId="1" fillId="3" borderId="2" xfId="0" applyFont="1" applyFill="1" applyBorder="1"/>' // 11 footer text
        '<xf numFmtId="164" fontId="1" fillId="3" borderId="2" xfId="0" applyNumberFormat="1" applyFont="1" applyFill="1" applyBorder="1"/>' // 12 footer money
        '<xf numFmtId="0" fontId="1" fillId="3" borderId="2" xfId="0" applyFont="1" applyFill="1" applyBorder="1"/>' // 13 footer number
        '<xf numFmtId="4" fontId="0" fillId="0" borderId="1" xfId="0" applyNumberFormat="1" applyBorder="1"/>' // 14 number 2 dp
        '<xf numFmtId="4" fontId="1" fillId="3" borderId="2" xfId="0" applyNumberFormat="1" applyFont="1" applyFill="1" applyBorder="1"/>' // 15 footer 2 dp
        '<xf numFmtId="3" fontId="0" fillId="0" borderId="1" xfId="0" applyNumberFormat="1" applyBorder="1"/>' // 16 integer
        '<xf numFmtId="3" fontId="1" fillId="3" borderId="2" xfId="0" applyNumberFormat="1" applyFont="1" applyFill="1" applyBorder="1"/>' // 17 footer integer
        '</cellXfs>'
        '<cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>'
        '</styleSheet>',
    for (var k = 0; k < tables.length; k++) 'xl/worksheets/sheet${k + 1}.xml': _sheetXml(tables[k], heading: heading, generated: when),
  };
  final archive = Archive();
  files.forEach((name, content) {
    final bytes = utf8.encode(content);
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  });
  return ZipEncoder().encode(archive);
}

String _sheetName(String title, int k) {
  final clean = title.replaceAll(RegExp(r'[\\/?*\[\]:]'), ' ').trim();
  final name = clean.isEmpty ? 'Sheet${k + 1}' : clean;
  return name.length > 31 ? name.substring(0, 31) : name;
}

/// Reads the first worksheet of an .xlsx file into rows of strings.
List<List<String>> readXlsx(List<int> bytes) {
  final archive = ZipDecoder().decodeBytes(bytes);
  String? text(String name) {
    for (final f in archive.files) {
      if (f.name == name) return utf8.decode(f.content);
    }
    return null;
  }

  final shared = <String>[];
  final ss = text('xl/sharedStrings.xml');
  if (ss != null) {
    for (final si in XmlDocument.parse(ss).findAllElements('si')) {
      shared.add(si.findAllElements('t').map((t) => t.innerText).join());
    }
  }
  final sheetName = archive.files.map((f) => f.name).where((n) => RegExp(r'^xl/worksheets/sheet\d+\.xml$').hasMatch(n)).toList()..sort();
  if (sheetName.isEmpty) throw const FormatException('No worksheet found in this Excel file.');
  final doc = XmlDocument.parse(text(sheetName.first)!);
  final rows = <List<String>>[];
  for (final row in doc.findAllElements('row')) {
    final rowNo = int.tryParse(row.getAttribute('r') ?? '');
    while (rowNo != null && rows.length < rowNo - 1) {
      rows.add(<String>[]);
    }
    final cells = <String>[];
    for (final c in row.findElements('c')) {
      final ref = c.getAttribute('r') ?? '';
      final letters = RegExp(r'^[A-Z]+').stringMatch(ref) ?? _col(cells.length);
      final idx = _colIndex(letters);
      while (cells.length < idx) {
        cells.add('');
      }
      final type = c.getAttribute('t');
      String v;
      if (type == 's') {
        final i = int.tryParse(c.getElement('v')?.innerText ?? '') ?? -1;
        v = i >= 0 && i < shared.length ? shared[i] : '';
      } else if (type == 'inlineStr') {
        v = c.findAllElements('t').map((t) => t.innerText).join();
      } else {
        v = c.getElement('v')?.innerText ?? '';
        if (v.endsWith('.0')) v = v.substring(0, v.length - 2);
      }
      cells.add(v);
    }
    rows.add(cells);
  }
  return rows;
}

// ───────────────────────── CSV ─────────────────────────

String buildCsv(ExportTable t) {
  String cell(Object? v) {
    final s = exportCellText(v);
    return s.contains(RegExp(r'[",\n\r]')) ? '"${s.replaceAll('"', '""')}"' : s;
  }

  final b = StringBuffer();
  if (t.title.isNotEmpty) b.writeln(cell(t.title));
  for (final i in t.info) {
    b.writeln(cell(i));
  }
  if (t.title.isNotEmpty || t.info.isNotEmpty) b.writeln();
  b.writeln(t.headers.map(cell).join(','));
  for (final r in [...t.rows, ...t.footer]) {
    b.writeln(r.map(cell).join(','));
  }
  return '﻿$b'; // BOM so Excel opens UTF-8 correctly
}

List<List<String>> parseCsv(String input) {
  final text = input.startsWith('﻿') ? input.substring(1) : input;
  final rows = <List<String>>[];
  var row = <String>[];
  final cell = StringBuffer();
  var quoted = false;
  for (var i = 0; i < text.length; i++) {
    final ch = text[i];
    if (quoted) {
      if (ch == '"') {
        if (i + 1 < text.length && text[i + 1] == '"') {
          cell.write('"');
          i++;
        } else {
          quoted = false;
        }
      } else {
        cell.write(ch);
      }
    } else if (ch == '"') {
      quoted = true;
    } else if (ch == ',') {
      row.add(cell.toString());
      cell.clear();
    } else if (ch == '\n' || ch == '\r') {
      if (ch == '\r' && i + 1 < text.length && text[i + 1] == '\n') i++;
      row.add(cell.toString());
      cell.clear();
      if (row.any((c) => c.isNotEmpty)) rows.add(row);
      row = <String>[];
    } else {
      cell.write(ch);
    }
  }
  if (cell.isNotEmpty || row.isNotEmpty) {
    row.add(cell.toString());
    if (row.any((c) => c.isNotEmpty)) rows.add(row);
  }
  return rows;
}

/// Turns header + rows into maps keyed by header (for imports).
List<Map<String, String>> rowsToMaps(List<List<String>> rows) {
  if (rows.isEmpty) return [];
  final header = rows.first.map((h) => h.trim()).toList();
  return [
    for (final r in rows.skip(1))
      if (r.any((c) => c.trim().isNotEmpty)) {for (var k = 0; k < header.length; k++) header[k]: k < r.length ? r[k] : ''}
  ];
}

/// Serial numbers from an imported sheet / CSV: the column whose header
/// mentions "serial" (or "S/N"), otherwise the first column. A header row is
/// skipped; blank cells are dropped.
List<String> serialsFromTable(List<List<String>> rows) {
  if (rows.isEmpty) return const [];
  bool isHeader(String v) {
    final s = v.trim().toLowerCase().replaceAll(RegExp(r'[^a-z/]'), '');
    return s.contains('serial') || s == 's/n' || s == 'sn' || s == 'sno' || s == 'imei';
  }

  var col = 0;
  var start = 0;
  final head = rows.first;
  final h = head.indexWhere(isHeader);
  if (h >= 0) {
    col = h;
    start = 1;
  }
  return [
    for (final r in rows.skip(start))
      if (r.length > col && r[col].trim().isNotEmpty) r[col].trim(),
  ];
}
