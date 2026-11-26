# Testing Report — 17 Nov 2026

> **18 Nov — bulk serial purchase, official name, backup & restore:** see
> `docs/BACKUP_RESTORE.md` and the user manual. Developer results: pure-Dart
> suite **99/99 passed** on Dart 3.11.4 (new: 8 bulk-serial, 9 backup/recovery
> tests); analysis clean on Flutter 3.41.6 (no issues) and 3.50 (only the known
> `deprecated_member_use` infos). Widget/UI tests (including 2 new bulk-serial
> UI tests), Windows release build and all Windows checks: **not yet run**.
>
> **17 Nov — USB scanner:** see `docs/SCANNER.md`. Developer results: pure-Dart
> suite 82/82 passed (14 new scanner tests); analysis clean on Flutter 3.50 and
> 3.41.6. The 7 POS scanner widget tests and real-scanner testing are **not yet
> verified**.
>
> **17 Nov — performance work:** see `docs/PERFORMANCE_REPORT.md` for the
> audit, the changes and measured before/after numbers. Developer results:
> pure-Dart suite 68/68 passed on Dart 3.11.4; analysis clean on Flutter 3.50
> (29 known deprecation infos) and on Flutter 3.41.6 (no issues). Widget,
> responsive and build results on your Mac: **not yet verified** — run
> `bash tool/run_tests_mac.command` and send `verify_logs/`.


Two kinds of result are kept apart here:

* **Developer results** — run by the developer in a Linux workspace with the exact Dart SDK (3.11.4) and the exact package versions.
* **Your local results** — what `bash tool/verify_mac.sh` (Mac) or the Windows commands produce on your machine. Until you send those logs back, everything in that column is **not yet verified**.

## 1. Dependency fix (PNG decoder / archive conflict)

### What went wrong
| Package | Fact (checked in each release's own pubspec) |
|---|---|
| image 4.11.0 | accepts `archive ^4.0.9`, but its PNG decoder calls `ZLibDecoder.decodeLazy`, which only exists from **archive 4.4.0**. With archive 4.0.9 it does not compile — this is an upstream bug. |
| image 4.11.1 / 4.12+ | fixed, but need `archive ^4.4.0` / `^4.5.0` |
| pdf 3.11.2 – 3.12.0 | `archive >=3.4.0 <4.1.0` |
| pdf 3.13.0 / 3.13.1 | need **Dart SDK >= 3.12** (cannot be used on Dart 3.11.4) |
| printing 5.14.3 | `image >=4.1.0 <=5.0.0`, `pdf ^3.10.0`; printing 5.15.x needs Dart >= 3.12 |

So on Dart 3.11.4 the newest usable pdf is 3.12.0, which caps archive below 4.1.0. That rules out every fixed image release, and upgrading pdf is **not** possible without upgrading Dart. The previous `archive: ^4.4.0` could never resolve.

### The fix (pubspec.yaml)
```yaml
archive: ^4.0.9                 # pdf 3.11.2-3.12.x caps archive <4.1.0
image: ">=4.1.0 <4.11.0"        # skip the one broken release (4.11.0)
```
`image` was already in the app as a dependency of pdf/printing; it is now listed directly so the broken release can be excluded. No `dependency_overrides`, no Flutter/Dart change, and no code or data-format change (image 4.10.x has the same API the pdf package uses).

### Proof (developer)
Resolved with real `dart pub get` (Dart **3.11.4**, Flutter 3.41.6 SDK packages, a local package server holding the published packages from your own pub cache plus the other candidate releases). There were **no overrides** in the pubspec.

* The old pubspec reproduced your exact error: "pdf <3.13.0 depends on archive >=3.4.0 <4.1.0 … version solving failed".
* The new pubspec resolves to:

| Package | Version |
|---|---|
| archive | 4.0.9 |
| image | 4.10.2 |
| pdf | 3.12.0 |
| printing | 5.14.3 |
| xml | 6.6.1 |
| petitparser | 7.0.2 |
| hive_ce | 2.23.3 |
| flutter_riverpod | 2.6.1 |
| path_provider | 2.1.6 |
| intl | 0.20.3 |
| crypto | 3.0.8 |
| barcode / qr / bidi | 2.2.9 / 3.0.3 / 2.0.13 |

## 2. Developer results (Linux, Dart 3.11.4, versions above)

| Check | Result |
|---|---|
| `dart pub get` (no overrides) | ✅ resolved |
| `dart pub deps` | ✅ image 4.10.2 → archive 4.0.9; pdf 3.12.0 → archive, image, xml |
| Static analysis, whole app incl. UI (Flutter 3.41.6 framework source, flutter_lints 5.0.0) | ✅ No issues found |
| Business / scenario / export / PDF tests | ✅ **60 / 60 passed** |
| New PNG regression test, run against the broken combination (image 4.11.0 + archive 4.0.9) | ✅ fails with your original error: `The method 'decodeLazy' isn't defined for the type 'ZLibDecoder'` — so the test really guards the bug |
| `widget_test.dart` | ⚠️ analysed only. Running it needs the Flutter engine, which this workspace doesn't have; it runs in your `flutter test`. |
| `flutter build macos` / `flutter build windows` | ⚠️ cannot run here — **yours to run** |

| Suite | Tests | Covers |
|---|---|---|
| money_test | 6 | money/qty maths, rounding, password hashing |
| workflow_test | 4 | full shop scenario, FIFO, landed cost, monthly report |
| rules_test | 17 | the 10 business rules, roles, warranty, repairs, ledgers |
| backup_store_test | 2 | backup → restore, damaged backup rejected, crash-journal replay |
| clarified_rules_test | 13 | decimals, brand+serial duplicates, inspection, warranty policy, owner-approved credit, v1→v2 migration |
| export_print_test | **5** | XLSX/CSV round-trip, Excel import, every PDF document (A4/80 mm/58 mm), **NEW: PNG logo decoded and embedded as an image in printed PDFs** |
| reports_settings_test | 4 | all 29 reports, settings validation, held bills, expired quotation |
| scenarios_test | 6 | Scenarios A–F (F uses real Hive files: restart, backup, restore) |
| app_paths_test | 3 | Windows data folder, AQSA_DATA_DIR override, single-instance lock |
| widget_test | 1 | login → dashboard (runs on your machine only) |

Every scenario ends with `IntegrityService.check()` reporting no issues.

### 2x. Reports / expenses / P&L round (18 Nov)
- Pure-Dart suite (my run, Linux, Dart 3.11.4): **107/107 passed**, including 8 new tests in `finance_reports_test.dart`:
  - P&L with discounts, partial payments, a return, a cancelled invoice and two purchase costs
  - expense CRUD and history
  - every report with and without filters, and on an empty shop
  - XLSX validity and formats
  - a 1,200-row PDF
- `dart analyze` on Flutter 3.41.6: no issues. On Flutter 3.50: only `deprecated_member_use` infos.
- **Not run here:** the widget tests, including the new `finance_ui_test.dart`, because the Flutter engine is unavailable in my environment. Run `bash tool/run_tests_mac.command` locally.

### Customer statement (21 Nov)
- `test/customer_statement_test.dart` (3 tests, pure Dart, passed here): demo customer with Rs 5,000 opening balance, three invoices with several products (paid / partly paid / unpaid), payments at sale, against an invoice, on account (2), a voided payment, an account-credit return and a credit adjustment. Every posting row's running balance is checked, one row per ledger entry, debit/credit totals equal the ledger, closing Rs 33,000 = customer balance = ledger balance = total receivables. Period tests (previous month, this month, custom, end-before-start rejected). PDF: A4, builds, 60 extra invoices give 8 pages.
- Returns (21 Nov): new test in the same file. Serial cameras returned as Saleable (back to stock), Faulty (inspection queue, marked Faulty, not sellable), Damaged (damaged stock, cash refund), plus cable. Each return is one credit row; total returns Rs 18,600 = return documents; refund shown as a debit; closing Rs 4,400 = ledger. Unknown condition refused. Suite now 148/148.
- `test/customer_statement_ui_test.dart`: widget test, runs only on the Mac (`bash tool/run_tests_mac.command`).
- Full pure-Dart suite: 147/147 passed. `dart analyze` with Flutter 3.41.6: no issues; with 3.50: no issues other than deprecation infos.

### Billing / invoice editing / non-stock items / return settlement (24 Nov)
- `test/billing_edit_test.dart` (5 tests, pure Dart, passed here): 500 and 1,000 clips, installation and labour (no stock change, zero cost, ledger, reports, statement, A4 + thermal PDF, presets); editing a partly paid invoice (serial swap, quantity down, clips up, service added, discount; payments untouched, ledger adjustment, stock and serial status, cost, P&L, history, statement line changes, lowering below paid = credit); walk-in rules, staff blocked, returns block edits; cash refund with entered amount (refund in cash report) and account adjustment with no outstanding (customer credit used by the next bill), duplicate return blocked, balance after return, receipts; edited invoice + non-stock lines + presets + return still correct after a real Hive restart.
- `test/billing_ui_test.dart`: widget tests (POS Add Item, Edit invoice) - run only on the Mac / Windows.
- Full pure-Dart suite: 153/153 passed. `dart analyze` (Flutter 3.41.6): no issues; 3.50: deprecation infos only.

### Shop contact on printouts (24 Nov)
- `test/shop_contact_test.dart` (2 tests, passed here): defaults, old settings get the defaults, link https://wa.me/923715263580, landline gives no link, cleared fields hide the line; 7 documents (A4, thermal 80, thermal 58 invoice, payment receipt, return receipt, customer statement, account statement) build and contain the link; a chosen icon image is embedded.
- Text check with pdftotext on the generated PDFs: "M. Osama" and "0371-5263580" found in all 7. Rendered A4, 80 mm, 58 mm and statement pages checked visually: nothing cut off.
- Full pure-Dart suite 155/155 passed; analyze clean (3.41.6), deprecation infos only (3.50).

### Shop profit / non-stock / labour bills (26 Nov)
- `test/shop_profit_test.dart` (4 tests, passed here): the example (camera 10,000 cost 8,000 + screws 500 + installation 1,000 → invoice 10,500, labour bill 1,000, customer pays 11,500; product revenue 10,000, cost 8,000, gross profit 2,000; net profit after a Rs 500 expense 1,500; dashboard sales 10,500; cash received 10,500; ledger shows only the invoice; reports P&L / invoices / by product / daily); bill discount taken from products first (and line revenues always add up to the total), returns; older invoices with labour lines keep them but out of profit, editing can keep/remove but not add labour; labour bills (collect, pay worker, limits, cancel with permission, summary, by worker, no effect on shop ledger/payments/cash).
- Updated for the new rule: `test/billing_edit_test.dart` (labour now goes on a labour bill; profit expectations), `test/shop_contact_test.dart`, label changes in `test/finance_reports_test.dart` and `test/reports_settings_test.dart` ("Net Product Sales").
- New widget test in `test/billing_ui_test.dart`: POS bill with screws + installation → invoice + labour bill (Mac / Windows only).
- Full pure-Dart suite 159/159 passed; analyze clean (3.41.6), deprecation infos only (3.50).

### Labour back on the customer invoice (27 Nov)
- Changed rule: labour / installation is a line on the customer's invoice (payable, in the ledger), kept out of shop sales and profit; no separate labour bill is created any more (earlier labour bills are kept).
- `test/shop_profit_test.dart` (4 tests, passed here): one invoice camera 10,000 + screws 500 + installation 1,000 = 11,500; one ledger entry 11,500; balance and receivables 11,500; payment 11,500 settles it; product revenue 10,000, cost 8,000, gross profit 2,000, net 1,500 after Rs 500 expense; dashboard sales 10,500; labour 1,000 separate in P&L, invoice, daily and by-product reports; invoice PDF A4 / thermal (text checked with pdftotext: "Installation Labour [Labour, job] Rs 1,000", "Grand Total Rs 11,500"). Discount allocation, preserved older data and labour edits, earlier labour bills.
- `test/billing_edit_test.dart` updated back to labour on invoices.
- Full pure-Dart suite 159/159 passed; analyze clean (3.41.6), deprecation infos only (3.50).

## 3. Your local results (Mac)
Dependency-fix run, from your `verify_logs/` on 16 Nov (read by the developer from the files on your Mac): pub get ✅, deps ✅, analyze ✅, `flutter test` ✅ **61/61 passed** (incl. `widget_test.dart` and `export_print_test.dart`), `flutter build macos --release` ✅ (`al_aqsa_cctv.app`, 52 MB). `key_versions.txt` matches section 1.

### 3b. Responsive UI round (see RESPONSIVE_UI_AUDIT.md)
| Check | Who | Result |
|---|---|---|
| Static analysis incl. `test/responsive_test.dart` | developer | ✅ No issues |
| Business tests (Dart 3.11.4) | developer | ✅ 60/60 |
| `flutter test` incl. the 65 new responsive tests | you | ☐ pending: run `bash tool/run_tests_mac.command` (logs in `verify_logs/ui_*.txt`) |

### 3c. Template for the remaining local checks
| Step | Command | Result |
|---|---|---|
| 03 | `flutter pub get` | ☐ |
| 04 | `flutter pub deps --style=compact` | ☐ |
| 05 | `flutter analyze` | ☐ |
| 06 | `flutter test --reporter expanded` (expect 61 tests incl. widget test) | ☐ |
| 07 | `flutter build macos --release` | ☐ |
| — | `verify_logs/key_versions.txt` matches the table in section 1 | ☐ |

## 4. Still unverified (needs real hardware)
Thermal printer (80/58 mm) output and cutter, label printer, barcode scanner input in POS, USB backup drive, Windows installer, and the Windows build itself — see RELEASE_CHECKLIST.md.
