# AL-AQSA CCTV & SOLAR SYSTEM — Architecture & Data Design

## 1. Structure

```
lib/
  core/            Money (integer paisa), ids, errors, password hashing
  data/
    store/         DataStore interface, HiveStore (+ write-ahead journal), MemoryStore (tests)
    migrations.dart  schema versioning; also applied to restored backups
  domain/
    models/        typed entities with toJson/fromJson
    services/      business logic (one service per module) + AppServices composition root
  ui/              Riverpod providers, theme, shell, pages, widgets
test/              unit, business-rule, end-to-end, backup and widget tests
```

Layering: **UI → services → UnitOfWork → DataStore**. The UI never writes to
the database directly. Every business operation runs inside one `UnitOfWork`
and is committed as a single atomic batch.

## 2. Storage (Hive CE)

* One Hive box per entity (see `Boxes` in `data_store.dart`).
* Records are stored as typed maps produced by each model's `toJson()`; the
  model's `fromJson()` is the type adapter. This avoids generated code
  (build_runner) while keeping every read strongly typed in Dart.
* **Atomic commits:** `HiveStore.commit()` writes the full batch to a
  `_journal` box and flushes it before touching any data box. After every box
  is updated and flushed the journal entry is deleted. On startup, any
  leftover journal entry (power cut / crash) is replayed. Result: an invoice
  is never saved without its stock, ledger and payment records.
* Reads are synchronous from memory → fast search over thousands of rows.

## 3. Money

All amounts are `Money` = integer paisa. No floating point anywhere in
financial totals. Division uses half-up rounding; shares are proportional.

## 4. Inventory costing — FIFO

* Each stock-in (purchase, sales return, technician return, adjustment)
  creates a **cost layer** (qty, unit cost).
* Each stock-out consumes the oldest layers; the consumed cost is the
  **COGS** stored on the invoice line.
* Purchase landed unit cost = (qty × price − line discount + line tax) ÷ qty.
* Gross profit = net sales − COGS. Labelled "before shop expenses" because
  rent/salaries are intentionally not recorded.

Stock buckets per product: **available**, **issued** (with technicians),
**damaged**. Every change writes a `StockMovement` with before/after values.

## 5. Technician material

Issue: available → issued, cost moves to the technician's holding.
Return unused/used-good: issued → available (new cost layer at holding cost).
Return damaged/faulty: issued → damaged.
Installed: issued → out, recorded as an *installation* (not a sale). It is
later added to a customer invoice (line linked by `techUsageId`), and its
holding cost becomes that line's COGS. Pending (un-invoiced) installations are
listed per customer.

## 6. Serial numbers

Key = normalized serial (trimmed, upper-case), so a serial can never be
registered twice. Status lifecycle:
`In Stock → Issued to Technician → Installed → Sold`, plus `Returned`,
`Under Repair`, `Replaced`, `Damaged`, `Returned to Supplier`.
Every transition is appended to the serial's history.

Product barcodes/QR (identify a model) live in a separate unique index and may
not collide with serials (identify one unit). Scanning resolves either.

## 7. Accounting

Append-only ledger per customer/supplier.
Customer: debit = they owe more (sale, repair charge), credit = they owe less
(payment, return). Supplier: credit = we owe more (purchase), debit = we owe
less (payment, return). Cancellations and voided payments add reversing
entries; nothing is overwritten. Cached balances are verified by
`IntegrityService` against the ledger.

## 8. Backups

`AL-AQSA_Backup_YYYY-MM-DD.zip` (format 2; older `.aqbak` = format 1) = zip of `data.json` + `manifest.json` + `files.json` + `files/` (images) — see `docs/BACKUP_RESTORE.md` (app, schema, app version,
time, record counts, SHA-256). Written to temp then renamed, then read back
and validated. Daily automatic backup to the local folder **and** the
configured external folder (USB / second drive). Restore = validate →
safety backup of current data → migrate → replace everything in one
atomic commit → verify counts → force re-login.

## 9. Business rules enforced in services (all tested)

1. No sale beyond available stock unless the owner authorises negative stock.
2. Serial numbers are unique; a serial must be In Stock to be sold/issued.
3. Purchase returns ≤ purchased − already returned.
4. Sales returns ≤ sold − already returned.
5. Technician returns/installs ≤ technician's holding.
6. Quotations never touch stock; conversion creates a draft invoice.
7. Cancelled invoices/purchases keep their record + audit log entry.
8. Payment voids/adjustments are reversing entries with a mandatory reason.
9. Invoices store name/price snapshots — product edits never change history.
10. Every stock change writes a stock movement record.

## 10. Business rules confirmed by the client (Nov 2026)

1. **Decimal quantities.** All quantities are `Qty` (3 decimals, stored as
   integer thousandths). A product opts in with "Allow decimal quantities"
   (e.g. cable 1.5 m). Serial-tracked products always use whole units.
2. **Serial identity = brand + serial.** Records are keyed `BRAND|SERIAL`
   with an index from the plain serial to all its records. A clash (same
   serial under another brand, or a repeated serial within a brand) blocks
   the purchase until the **owner** approves it; approved duplicates within
   a brand get a `|2` suffix and are marked "duplicate approved".
3. **Inspection / quality control.** Technician returns marked Used,
   Damaged or Faulty (and customer returns marked "needs inspection") go to
   the *inspection* bucket, not sellable stock. Only the owner decides:
   sellable (back to stock at original cost), repairable (separate bucket,
   decide again later) or damaged. Partial decisions are supported.
4. **Warranty start** defaults to the invoice date; Settings can switch to
   the installation date.
5. **Credit sales.** Walk-in customers pay in full, or a customer account is
   created/selected on the spot. Any unpaid balance needs `approveCredit`
   (owner) — either the owner is logged in, or the owner types their
   password on the counter (`AuthService.authorize`). The approver is saved
   on the invoice and in the audit log.

## 11. Remaining assumptions

* Staff role: sales, customers, quotations, warranty, repairs, issue stock;
  no purchase costs, financial reports, backups or settings.
* Warranty replacement units come from stock; their cost is a stock
  movement (`warrantyReplacement`) and is not charged to the customer.
* Serial-tracked stock is corrected per unit (mark damaged / purchase
  return), not by count adjustment.

## 12. Schema versions

* v1 – initial release.
* v2 – decimal quantities (×1000), brand-aware serial keys + serial index,
  inspection bucket. `Migrator` upgrades live data and older backups.

## 13. Printing & export

* PDFs (package `pdf`): A4 invoice, 80/58 mm thermal receipt, quotation,
  purchase, payment receipt, repair receipt, account statement, QR +
  Code128 labels, any report.
* Printing (package `printing`): preview, system print dialog, or direct
  print to the printer chosen in Settings. Missing printers are reported
  and fall back to the dialog.
* Excel: built-in .xlsx writer/reader (no extra package) + CSV.
* Files: built-in offline file/folder browser (drives, USB) instead of a
  file-picker plugin.
