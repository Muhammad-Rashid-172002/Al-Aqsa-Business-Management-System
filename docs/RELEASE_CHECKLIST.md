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
