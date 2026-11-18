# AL-AQSA CCTV & SOLAR SYSTEM — Offline Business Management System

Flutter desktop ERP for a CCTV shop: products, QR/barcode, serial numbers,
purchases, POS, technicians, ledgers, quotations, warranty, repairs, reports,
backup/restore. 100% offline (Hive CE local database).

## First-time setup (Mac or Windows)

```bash
cd al_aqsa_cctv
flutter create --platforms=windows,macos --project-name al_aqsa_cctv --org com.alaqsa .
flutter pub get
flutter analyze
flutter test
```

`flutter create .` only adds the missing platform folders; it does not
overwrite existing files.

Run on Mac for development: `flutter run -d macos`
(macOS needs no extra setup — data is stored in Application Support).

## Windows release build (on the shop's Windows PC)

1. Install Flutter + Visual Studio 2022 with "Desktop development with C++".
2. `flutter build windows --release`
3. The app is in `build\windows\x64\runner\Release\` — copy the whole folder.

## Where data lives

* Database: `%APPDATA%\com.example\al_aqsa_cctv\data` (Windows)
* Local backups: `...\backups`
* Set an external backup folder (USB drive) in Settings → Backup.

See `docs/ARCHITECTURE.md` for design, costing method, rules and assumptions.

## Build status

All 18 sidebar modules are implemented and connected to the database:
Dashboard, Products (labels, Excel import), Categories, Purchases, Sales/POS
+ Invoices, Inventory (+ inspection queue, movements), Serial Numbers,
Technicians, Customers, Suppliers, Returns, Quotations, Warranty, Repairs,
Payments & Ledgers, Reports (29 reports, PDF/Excel/CSV), Backup & Restore,
Settings (business, printing, labels, users, audit log).

* Static analysis: no issues (Flutter 3.47). Tests: 50/50 pass.
* **Windows build: not yet built/tested** — run the steps above on a Windows PC.

Docs: `docs/ARCHITECTURE.md`, `docs/USER_MANUAL.md`, `docs/TESTING_REPORT.md`.
