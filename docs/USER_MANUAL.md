# AL-AQSA CCTV & SOLAR SYSTEM — User Manual

## Getting started
1. Start the app: the AL-AQSA CCTV & SOLAR SYSTEM splash screen opens your shop data and goes straight to the **Dashboard**. There is no login, username or password (single shop computer, offline).
2. **Settings → Business & Documents**: business name, address, phone, logo, invoice prefixes.
3. **Settings → Printing & Labels**: receipt format (thermal 80/58 mm or A4), quick-print printer, label size.
4. **Backup & Restore → Change external folder**: choose a USB drive. Daily backups go there and to this computer.
5. Add **Categories**, **Suppliers**, **Products** (or **Products → Import Excel/CSV**).

## Daily work
| Task | Where | Shortcut |
|---|---|---|
| Sell | Sales / POS → New Sale | F2 anywhere, F9 to complete |
| Find anything / scan | Top search bar | Ctrl+K |
| Hold a bill | POS | F8 (open with "Held") |
| Pick customer | POS | F4 |
| Receive customer payment | Customers → customer → Receive Payment, or Payments & Ledgers | |
| Buy stock | Purchases → New Purchase | Ctrl+S to save |
| Give material to a technician | Technicians → Issue Material | |
| Technician returns / installs | Technicians → technician → Return / Installed | |
| Check returned items | Inventory → Inspection queue (owner) | |
| Warranty check | Warranty → scan serial | |
| Repair job | Repair Management → Receive Device | |

## POS tips
* Scan a product barcode/QR → it is added (scan again to add one more).
* Scan a **unit serial** → that exact unit is added.
* Serial products clicked in the grid open a serial picker.
* Decimal items (cable): tap the line to type 1.5, 2.75 …
* Amount received larger than total → change is shown.
* Less than total → it is a **credit sale**: choose or create the customer. The credit is approved automatically as the shop owner and recorded on the invoice.
* Customer with installed (not yet invoiced) material → "Add installed items".

### USB barcode / QR scanner
Plug in any USB scanner set to keyboard (HID) mode — no driver or internet needed.
On the POS screen just scan: the item is added whichever field is selected.
A double read of the same label within 0.7 s is ignored; scan again to add one
more. Unknown codes show a red message. Scanner options are in Settings →
Printing & Labels. Details and a first-use checklist: `docs/SCANNER.md`.

## Buying many identical units (e.g. 50 cameras)
Create **one** product, never 50. In **Add Product** turn on *Track individual
serial numbers*, then in *Stock received now* enter the quantity (50), choose
the supplier (and invoice no. / amount paid) and press **Enter 50 serial
numbers**: scan each camera's sticker with the USB scanner (Enter or Tab after
each code), paste a list, or **Import CSV / Excel** (a column named "Serial"
or the first column). The box shows **Required / Entered / Remaining**; repeated
or invalid entries are red and must be fixed, serials that already exist are
amber and need your confirmation. Saving creates the product and a purchase
together. Buying 20 more later: **Purchases › New purchase**, same product,
quantity 20, its 20 serials — earlier serials and invoices stay as they were.
Open the product › **Stock & serial numbers** to see Available / Sold /
Installed / Faulty and every unit's purchase, sale, customer, warranty and
technician details (search and filter by status).

## Technician material
* **Issue**: stock moves to "With Technicians" (not sold).
* **Returned (Unused)** → back to stock.
* **Returned (Used / Damaged / Faulty)** → **Inspection queue**; the owner marks it Sellable, Repairable or Damaged.
* **Installed** at customer → appears in POS for that customer to invoice.

## Serial numbers
Identity is **brand + serial**. If a purchase contains a serial that already exists, the app stops and shows it.
The owner can approve genuine cases (another brand using the same number, or a manufacturer repeat).

## Reports
Reports → pick a report → date range → **Excel / CSV / PDF**. Profit is **gross profit before shop expenses**.

## Customers: who paid, who owes
- **Bill for a new customer:** at the POS, if no customer is selected, type the **name and/or mobile** above the cart.
  - The customer is saved in **Customers** together with the bill.
  - An existing customer with the same mobile number (0300…, +92 300…) is used instead of a duplicate.
  - Leave both empty for a plain walk-in cash sale.
- **Customers tabs:**
  - **All**
  - **Balance due (baqaya)**: who owes, with the total
  - **Paid up**: balance zero
  - **Advance / credit**: paid more than billed
- **Columns:** Total billed • Paid (net of voided payments and refunds) • Balance • Last payment.
- Export / Print exports the tab you are on. Open a customer to see every invoice and payment in its Ledger and Payments tabs.

## Expenses and Profit & Loss
- **Expenses**: record rent, bills, salaries, transport, maintenance and other shop costs. You can edit them, or delete them with a reason (they can be restored).
- **Profit & Loss**: pick a month, year or custom range. *Gross profit* is sales minus discounts, returns and the cost of the goods sold. *Net operating profit* is gross profit minus shop expenses. *Cash received* is shown separately, because profit is not cash.
- Every report and list has **Export / Print**: Excel, PDF, Print (choose your printer) and Preview. Details are in REPORTS_EXPENSES.md.

## Restocking an existing product (Add More Serial Numbers)
- When a product sells out and the same company and model arrives again, **don't create the product again**. Go to Products → ⋮ on the product → **Add More Serial Numbers**.
- Name, company and model are shown read-only. Enter the new quantity, then scan, type, paste or import only the new serial numbers. The window shows Required / Entered / Remaining, and Save is enabled only when they match.
- Choose **Purchase from supplier** (supplier, invoice no., date, cost, paid now) or **Opening / other stock** (cost, date, reason).
- Each restock is its own cost batch. A sold serial is always costed at the price **its own batch** was bought for, so profit is exact even when prices change.
- Old serial numbers keep their Sold / In stock / Installed status. A serial already recorded anywhere (this product's earlier purchases, another product or brand) is refused. Only the owner can approve a genuine manufacturer duplicate.
- If you start "Add Product" for a product that already exists, the software offers to restock the existing one instead.
- Non-serial items: ⋮ → **Purchase more stock**.

## WhatsApp customers
- In **Customers**, the small green chat button opens that customer's WhatsApp chat with a greeting already typed. Nothing is sent until **you** press Send in WhatsApp.
- In a customer's details, **WhatsApp** and **Message templates** let you choose a General message, Payment reminder, Outstanding balance reminder, Invoice follow-up or Thank-you message, edit the text, and then open WhatsApp.
  - The balance comes from the customer's ledger.
  - Invoice details come from the latest completed invoice.
  - Reminders are only offered when the customer actually owes money.
- Numbers can be typed as 03001234567, 0300-1234567 or +92 300 1234567 (all become 923001234567). Foreign numbers keep their country code (+971…, +44…).
- An optional alternate number can be saved. Landlines and invalid numbers are skipped, and a clear message is shown instead of a broken link.
- WhatsApp Desktop opens directly if it is installed; otherwise the browser opens wa.me, which hands over to WhatsApp Desktop or WhatsApp Web. An internet connection is needed for WhatsApp itself; the rest of the software stays offline.

## Backup & restore
* Automatic daily backup (time and how many to keep are configurable).
* **Backup Now** at any time.
* **Restore**: pick a backup → it is checked, the current data is saved as a safety backup, then everything is replaced. The app reloads the restored data and returns to the Dashboard.
* **Run check** verifies all balances, stock and serials.

## Where your data is kept (Windows)
* Database: `%APPDATA%\AL AQSA CCTV\data` — never delete this folder.
* Backups: `D:\AL-AQSA_Backups` (default, changeable) plus a second copy in `%APPDATA%\AL AQSA CCTV\backups`. Also copy backups to a USB drive regularly. Details: `docs/BACKUP_RESTORE.md`.
* Only one copy of the app can be open at a time; a second copy shows "already open".

## Returns and inspection
* **Customer return** (Returns → Customer Return, or open the invoice → Return items): choose
  *Good – back to stock*, *Needs inspection* or *Damaged*, and *Cash refund* or *Adjust account*.
* **Supplier return** (Returns → Return to Supplier): reduces what you owe the supplier
  (or record the cash they give back).
* **Technician return**: Technicians → technician → Return.
* Everything marked Used / Damaged / Faulty / Needs inspection waits in **Inventory → Inspection queue**
  until the owner decides.
