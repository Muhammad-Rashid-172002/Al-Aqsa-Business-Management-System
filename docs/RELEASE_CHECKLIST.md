# AL-AQSA CCTV & SOLAR SYSTEM — Release Checklist

Tick every item before handing a build to the shop. ✅ = verified automatically by
the developer; ☐ = must be checked by a person on the real machine.

## A. Code & tests (Mac or Windows)
- ✅ `flutter pub get` resolves on Dart 3.11.4 with no `dependency_overrides` (archive 4.0.9, image 4.10.2, pdf 3.12.0, printing 5.14.3) — verified by the developer; ☐ confirm `verify_logs/key_versions.txt` on your Mac/PC shows the same
- ✅ `flutter analyze`: no issues (verified against Flutter 3.41.6 + locked packages; re-run on your PC)
- ✅ `flutter test`: all business, scenario, export/PDF and widget tests pass (see TESTING_REPORT.md)
- ☐ `version:` in pubspec.yaml and `AppVersion` in installer/al_aqsa_cctv.iss bumped

## B. Windows build
- ☐ `flutter doctor -v` green for "Visual Studio - develop Windows apps"
- ☐ `flutter build windows --release` succeeds
- ☐ `build\windows\x64\runner\Release\al_aqsa_cctv.exe` starts; window title "AL-AQSA CCTV & SOLAR SYSTEM", icon shown
- ☐ Starting a second copy shows "AL-AQSA CCTV & SOLAR SYSTEM is already open"
- ☐ Installer builds (Inno Setup) and installs on a clean Windows user account
- ☐ App runs with the network cable unplugged / Wi-Fi off

## C. First-run & security
- ☐ Launch shows the splash screen, then the Dashboard — no login, account setup or password anywhere (automated: `test/widget_test.dart`, fresh and existing databases)
- ☐ Existing shop data opens unchanged after updating from a version that had logins (same owner record reused; no records added or reset)
- ☐ Settings has no Users tab; the top bar has no account / log-out menu (theme toggle kept)
- ☐ Credit sale completes without a password prompt and shows "Credit approved by" on the invoice
- ☐ Settings → Audit & Data shows the actions just performed

## D. Windows hardware (cannot be verified on a Mac)
- ☐ USB barcode scanner: in POS, scanning a product barcode adds the item; scanning twice adds qty 2
- ☐ Scanner set to "Enter" suffix (most are by default); a scan without Enter needs the scanner reconfigured
- ☐ QR scanning: scan a label printed by the app → product found
- ☐ Unit serial scan (POS, Purchases, Warranty search)
- ☐ 80 mm thermal receipt prints, text not cut off (Settings → Printing → Thermal 80 mm, quick-print printer chosen)
- ☐ 58 mm thermal receipt prints
- ☐ A4 invoice and quotation print on a laser/inkjet printer
- ☐ Label printer: 50×25 mm labels (or the configured size) print; QR and barcode scan back correctly
- ☐ Printer unplugged → app shows "Printer … is not connected" and opens the print dialog (no crash)
- ☐ Save PDF and Export Excel to `C:\` and to a USB drive; files open in Acrobat / Excel
- ☐ Backup to USB drive `E:\…`; pull the USB out → next automatic backup warns, local backup still made
- ☐ Restore from the USB backup on a second PC

## E. Data safety
- ☐ Make a sale, close the app from the taskbar, reopen → sale is there
- ☐ Make a sale, end the app in Task Manager immediately → reopen → sale either fully present or not at all; Backup & Restore → Run check shows "All records are consistent"
- ☐ Upgrade test: install version N, enter data, install N+1 → data intact

## F. Hand-over
- ☐ Owner account created by the shop owner (not the developer)
- ☐ External backup folder set to a USB drive
- ☐ Receipt format and printer configured
- ☐ USER_MANUAL.md shared with the shop

## Windows: backup, restore and reinstall recovery (17-18 Nov changes — not yet tested on Windows)
- ☐ Installer shows "AL-AQSA CCTV & SOLAR SYSTEM"; Start Menu + desktop shortcuts have the new name; old "AL AQSA CCTV" shortcuts are gone; upgrade keeps the install folder and all data
- ☐ Exe Properties › Details: product name "AL-AQSA CCTV & SOLAR SYSTEM"
- ☐ Backup & Restore shows location `D:\AL-AQSA_Backups (default)`, status Available; folder is created automatically
- ☐ Create Backup Now → `D:\AL-AQSA_Backups\AL-AQSA_Backup_<date>.zip`; second one same day → `_2.zip`; nothing overwritten
- ☐ Task Scheduler shows `AL-AQSA CCTV & SOLAR SYSTEM\Daily Backup` (daily, "run as soon as possible after a missed start"); toggling Automatic backup OFF removes it
- ☐ Close the app, wait for the backup time → a backup appears and no window opens
- ☐ Computer off at backup time → backup made shortly after start
- ☐ No D: drive (or USB folder unplugged): Create Backup Now shows "Backup NOT saved…", offers "Choose another location"; status shows the error; local copy exists
- ☐ Corrupted zip (truncate a copy) → "cannot be restored", data unchanged
- ☐ Product image + shop logo set; restore on a freshly installed Windows (new user profile) from D: → all records, serials, balances, images, logo back
- ☐ Restore the same backup twice → no duplicate products / serials / invoices
- ☐ Restoring an older backup shows the "OLDER backup" warning

## Bulk serial purchase (not yet tested on Windows)
- ☐ Add Product → serial tracking ON → Quantity received 50 + supplier → Enter 50 serial numbers (scan with USB scanner, paste, import CSV/XLSX) → Required/Entered/Remaining correct → Save → one product, stock 50
- ☐ Product › Stock & serial numbers: counts and the Serial Numbers tab (search, status filter, purchase / sale / warranty / technician details)


## Reports, export/print, expenses, Profit & Loss (18 Nov — not yet tested on Windows)
- [ ] Reports → each group: open a few reports, apply filters, and check the totals against the screen.
- [ ] Excel export opens in **Microsoft Excel** without a repair prompt, with PKR format, dates, frozen header and one sheet per tab.
- [ ] PDF export: A4, header repeated on page 2+, page numbers; wide reports are landscape.
- [ ] Print shows the Windows printer list and prints on the shop printer. Preview works.
- [ ] Export / Print menu on Products, Stock, Sales, Purchases, Customers, Suppliers, Ledgers, Serials, Technicians, Warranty, Repairs, Returns and Quotations.
- [ ] Expenses: add (with a receipt), edit, delete with a reason, show deleted, restore; history shown.
- [ ] Profit & Loss for a month with real data: gross profit and net operating profit match a hand calculation; cash is shown separately.
- [ ] Large export (e.g. 5,000+ rows) finishes with the progress dialog and doesn't freeze the UI.

## Official icon (18 Nov — not yet checked on Windows)
- [ ] `build\windows\x64\runner\Release\al_aqsa_cctv.exe` shows the AL-AQSA logo in Explorer (Large icons view) and in Properties.
- [ ] The running app shows the logo on the taskbar, in Alt+Tab and in the window's title bar.
- [ ] `installer\output\AL-AQSA_CCTV_and_Solar_System_Setup_*.exe` shows the logo; the wizard pages show the logo on the left and top-right.
- [ ] After installing: the Desktop and Start Menu shortcuts and Apps & features / Control Panel all show the logo.
- [ ] Inside the app: the splash screen shows the full logo; the sidebar shows the square icon; the dashboard shows the logo and name.
- [ ] If Windows still shows the old icon after upgrading, that is Windows' icon cache: unpin and re-pin the taskbar shortcut, or sign out and back in.

## Three-dot (⋮) row menu and Delete (19 Nov — not yet tested on Windows)
- [ ] Products, Categories, Customers, Suppliers, Technicians (card corner), Expenses, Quotations, Sales invoices, Purchases, Payments & Ledgers and a customer's or supplier's Payments tab: every row ends in ⋮ with only the relevant View, Edit and Delete items.
- [ ] Delete shows "Delete record", the record's name, "Are you sure you want to delete this record?", Cancel and Delete. Cancel changes nothing; Delete shows a green notification.
- [ ] A product, customer, supplier or technician with history is archived ("Show archived" / "Show inactive" → ⋮ → Restore). One with no history is removed.
- [ ] A completed invoice or purchase is cancelled (a reason is required). A payment is voided. An expense is soft-deleted and can be restored.
- [ ] The menu opens fully inside the window when the window is small, and at 125% / 150% Windows scaling.

## WhatsApp customers (19 Nov — not yet tested on Windows)
- [ ] With WhatsApp Desktop installed: the green button in Customers opens the right chat with the greeting typed in; nothing is sent automatically.
- [ ] Without WhatsApp Desktop: the browser opens wa.me → WhatsApp Web with the right number and text (Urdu/English text, line breaks and "&" intact).
- [ ] Customer details → Message templates: name, balance and invoice number match the ledger; reminders are disabled when nothing is owed.
- [ ] A customer with no or invalid number shows the "no valid mobile number" message.
- [ ] Edit a customer: the alternate number saves and is offered in the composer.

## Instant refresh (19 Nov — not yet tested on Windows)
- [ ] In each module, add, edit, delete/archive and restore a record: the list updates at once, without switching pages.
- [ ] With a customer's details open, record a payment: the balance and ledger update in the open dialog.
- [ ] Complete a POS sale: Products, Stock, Serial Numbers, Customers (balance), Dashboard and Profit & Loss show the new figures when opened, and also while open.
- [ ] Type a search or set a filter first, then add a matching record: it appears and the search and filter stay as they were.

## Repeat purchases / Add More Serial Numbers (19 Nov — not yet tested on Windows)
- [ ] Sell a serial product down to 0, then ⋮ → Add More Serial Numbers: 5 new serials at a new price from a different supplier. Stock 0 → 5, old serials still Sold, no second product.
- [ ] Try a serial that was sold earlier: refused, and shown as "Already recorded for this product".
- [ ] Sell one unit from the new batch: on the invoice and in Profit & Loss, its cost is the new batch price.
- [ ] Opening / other stock option: adds units with a reason; the stock-in number (SIN-…) appears in the serial history.
- [ ] Add Product with the same name, brand and model: the "This product already exists" dialog offers to add more serial numbers to it.

## Permanent delete (19 Nov — not yet tested on Windows)
- [ ] Owner: ⋮ → Delete on an unused customer → Delete → tick "I understand" → Permanently Delete. It disappears at once; close and reopen the app: still gone.
- [ ] A customer with an invoice: "cannot be permanently deleted" with reasons; "Archive instead" works.
- [ ] Expense with a receipt: Profit & Loss drops by its amount; the receipt file is gone from the app's media folder.
- [ ] After making a backup on D:, a permanent delete lists that backup as still containing the record. Keep → backup unchanged. Purge (type PURGE) → report shows the rewritten files; Backup & Restore can still open and restore them.
- [ ] Restore a copy of an old backup saved outside D: → the purged record does not come back.

## Full cascade delete (19 Nov — not yet tested on Windows)
- [ ] Demo customer with 2–3 invoices, payments and an outstanding balance: Delete shows the counts (invoices, payments, ledger entries…). After deleting, the Dashboard, Profit & Loss and receivables drop by exactly that customer's figures, and stock quantities are unchanged.
- [ ] Supplier with purchases: after deleting, its stock is still in stock with the same value. Selling one of its serials uses that batch's cost.

## Customer statement A4 (21 Nov — not yet tested on Windows)
- [ ] Customers → Print Customer Statement → pick a customer → Print Preview shows the A4 statement.
- [ ] Complete history / This month / Previous month / Custom range give the expected opening and closing balance.
- [ ] Closing balance equals the customer's balance on the Customers page and the dashboard receivable share.
- [ ] Print on the shop's A4 printer: headers repeat on every page, page numbers show, no cut-off amounts.
- [ ] Export PDF opens in a PDF reader with the same content as the print.
- [ ] Customer return with Saleable / Faulty / Damaged: stock goes to available / inspection (Faulty) / damaged; statement shows each return once as a credit and in the Product Returns table.
