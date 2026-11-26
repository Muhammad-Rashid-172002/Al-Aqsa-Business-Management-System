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

## Shop contact on printouts

- Every customer document (A4 and thermal invoices, payment receipts, return receipts / credit notes, customer and account statements, quotations, repair receipts, PDF exports) shows **Contact: M. Osama** with a green WhatsApp badge and **0371-5263580** under the shop name. On customer statements it is also in every page footer.
- In a PDF the badge and number are a link to https://wa.me/923715263580 (opens WhatsApp in readers that support links).
- Change the name or number in **Settings → Business** (Contact person / Contact WhatsApp number). Clear both to hide the line.
- **Settings → Choose WhatsApp icon** puts an icon image of your choice (for example the official WhatsApp icon file from WhatsApp's brand resources) in place of the built-in green phone badge.

## Non-stock items and labour (POS)

- In the bill, press **Add Item (product, non-stock, service)** and choose:
  - **Stock product**: the usual product from stock.
  - **Non-stock item**: clips, screws, small accessories. Description, quantity (e.g. 500 or 1000), unit and price; no product record, stock is not touched. It is printed on the shop invoice and is part of what the customer pays, but it is **not counted in shop profit** (no purchase cost is recorded for it).
  - **Labour / installation** (karegar's charges): CCTV / camera / solar installation, wiring, mazdoori. This is the **worker's money**: when the bill is completed it is saved on a separate **Labour Bill** (LB-...), not on the shop invoice, not in the customer's shop ledger, not in shop sales, cash or profit. Type the worker's name in the bill panel.
- The bill panel shows "Shop invoice" and "Labour bill (karegar, separate)"; TOTAL is what the customer pays for both. Money received pays the shop invoice first, then the labour bill.
- **Sales → Labour Bills**: every labour bill with customer, worker, invoice, total, received, due, paid to the worker. Open one to **Receive** more from the customer, **Pay worker**, **Print** or **Cancel** it. **New Labour Bill** makes one without a shop invoice. Export to Excel / PDF includes a by-worker sheet.
- Tick **Save for quick billing next time** to keep an item as a preset.

## Shop profit

- Shop profit counts **only stock products**: their sales after discounts minus their actual purchase cost (FIFO). Net profit = that gross profit (+ repair profit) − shop expenses.
- A bill discount is taken from the stock products first, so product profit is never overstated.
- Dashboard "Sales" = products + non-stock items (no labour). "Gross Profit" = stock products only. Reports (Profit & Loss, sales daily / monthly / by product / invoices) show non-stock items and labour in their own columns or sheet, outside profit.
- Invoices made before labour bills existed keep their labour lines (nothing was removed); those amounts are shown as "Labour on older invoices" and are left out of shop sales and profit. Editing such an invoice can keep or remove the labour line, but new labour cannot be added to an invoice.

## Editing a completed invoice (owner)

- Open the invoice (Sales → Invoices, the ⋮ menu → Edit, or the customer's Ledger tab → pencil on a sale) and press **Edit invoice**.
- Change products and quantities, serial numbers, prices, discounts, non-stock items and services, notes. A reason is required.
- The invoice keeps its number and date. Payments are never deleted or duplicated: the summary shows what was already paid against the invoice and the new balance. For a customer, the difference is posted to the ledger as a separate "Invoice edited" entry; if the new total is lower than what was paid, the excess stays as customer credit. A walk-in invoice must stay fully paid: receive the extra amount in the edit window, or the difference is paid back as a cash refund.
- Stock follows the change: removed units go back to stock at their own cost, added units are taken from stock. Removed serial numbers return to In stock; added ones become Sold on this invoice.
- Profit & loss uses the edited lines and costs.
- The invoice window shows the **Edit history** (date and time, who, reason, old and new lines and totals). Invoices with returns or technician-installed material cannot be edited.

## Customer returns: settlement

- **Cash refund**: enter the refund amount (or leave empty for the full price). The money is recorded as paid out (cash reports and payments), the customer ledger shows the return credit and the refund, and a **Return Receipt** opens for printing.
- **Adjust in customer account**: the return amount is credited to the customer. It reduces what they owe; if they owe nothing it stays as customer credit and is used by the next bills. No cash is paid. A **Credit Note** opens for printing.
- The amount can be lower than the price charged (for example a deduction for a damaged item), never higher.
- Returns history shows the invoice, return number, products, quantities, amount, settlement, date and the customer balance after the return. The same serial number or quantity cannot be returned twice.

## Customer statement (A4)

**Print Customer Statement** is on the Customers page (top), in each customer's ⋮ menu, in the customer window, on its Ledger tab, and on Payments & Ledgers.

- Choose the period: **Complete history** (default), This month, Previous month, or a Custom date range. With a period, earlier transactions become the "balance brought forward".
- **Print Preview** shows the A4 statement; **Print** opens the printer dialog; **Export PDF** saves the file. All three use the same PDF.
- Every invoice is listed with its product lines (qty, unit price, total, serial numbers, discounts), then the invoice total as Debit. Payments (at sale, against an invoice, on account), returns, refunds, voided payments, cancelled invoices, repair charges and adjustments are separate rows. The Balance column is the running balance after each row.
- Summary: Opening + Debit − Payments − Returns/adjustments = Closing outstanding balance. It always equals the customer's balance in the software (for a statement that runs to today).
- The Invoice Status table shows each invoice as Paid, Partly paid (with the amount due) or Unpaid, counting only payments taken against that invoice. Payments taken "on account" reduce the account balance and are shown separately.
- **Returns:** every customer return is a separate Credit row (one per return voucher), with its product lines, the condition and the reason. A **Product Returns** table lists date, return no., original invoice, product, qty, amount, condition, reason and whether it was credited to the account or refunded in cash. A cash refund also shows as a Debit row, because the money was paid back.
- Return conditions (Returns → customer return): **Saleable** goes back to available stock; **Faulty** is kept aside in the inspection queue marked "Faulty" (not sellable until the owner decides); **Damaged** goes to damaged stock; **Needs inspection** goes to the inspection queue.
- Urdu text in product names is not printed (the PDF font is Latin only), as in the other printouts.

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
