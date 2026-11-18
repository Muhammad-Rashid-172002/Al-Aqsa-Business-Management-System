# Reports, Export/Print, Expenses and Profit & Loss

## Where things are
- **Reports** (sidebar): a central list of every report, grouped as Business, Profit & Expenses, Sales, Purchases, Products & Stock, Accounts, Technicians, Warranty, and Repairs & Faulty.
  - Pick a report, a date range, and the filters it supports: product, category, supplier, customer, payment status, serial, technician, transaction type.
  - The buttons are **Excel**, **PDF**, **Print**, **Preview** and CSV.
  - Every export contains only the filtered records shown on screen.
  - Reports with several sheets (for example Profit & Loss, or Purchase Details & Serial Numbers) show sheet chips. Excel gets one worksheet per sheet.
- **Module screens**: Products, Stock, Sales, Purchases, Customers, Suppliers, Payments & Ledgers, Serial Numbers, Technicians, Warranty, Repairs, Returns and Quotations each have an **Export / Print** menu (Excel, PDF, Print, Print preview). It exports the rows currently listed after search and filters.
- **Expenses** (sidebar, needs the *Manage expenses* permission):
  - Add, view, edit, delete and restore shop expenses.
  - Categories: Shop rent, Electricity bill, Internet bill, Staff salaries, Transport, Maintenance, Other. You can also add a custom category.
  - Each expense keeps a change history.
  - Deleting is a soft delete with a reason. Deleted expenses are left out of every total but can be shown and restored.
  - A receipt (image or PDF) can be attached. It is copied into the app's data folder.
- **Profit & Loss** (sidebar, needs *View financials*):
  - Choose a Month, a Year or a Custom range.
  - Shows a statement, summary cards, an expense breakdown donut and a 12-month chart.
  - **Export / Print** offers Monthly P&L, Gross Profit, Expense Report, Category-wise Expenses and the Yearly Financial Summary.

## How the numbers are calculated
| Line | Definition |
|---|---|
| Total sales | Item totals of completed invoices before any discount. Cancelled invoices are excluded. Quotations and unsold stock are never counted. |
| Sales discounts | Line discounts + invoice discounts. **A discount is not a payment.** |
| Sales returns | Value of goods customers returned in the period. |
| Net sales | Total sales − discounts − returns |
| Cost of goods sold | The actual purchase cost (FIFO) of the units sold, less the cost of returned units |
| **Gross profit** | Net sales − COGS. Always labelled *gross*. |
| Repair service profit | Delivered repair charges − parts cost (shown as a separate line) |
| Total shop expenses | Non-deleted expenses dated in the period |
| **Net operating profit** | Gross profit + repair profit − expenses |
| Cash received | Customer payments actually received: at sale plus later payments. Payments on cancelled invoices are excluded. Shown apart from profit. |
| Sold on credit | The unpaid part of invoices at the time of sale. It is counted in sales, not in cash. |
| Customer balances outstanding | Customer ledger balance at the end of the period |

- **Payment status** (Paid / Partial / Unpaid) is worked out from the payments linked to each invoice or purchase.
- A general "on account" payment reduces the customer's ledger balance, but it is not assigned to a particular invoice.
- No historical expenses are invented: the report only uses expenses you enter.

## File format details
- **Excel** files are real .xlsx and open in Microsoft Excel and LibreOffice. Each sheet has:
  - the business name, report title, "Generated" date and the period/filter lines
  - a bold, frozen and filterable header row
  - PKR money format, real dates (dd/MM/yyyy), sized columns and bold totals
  - A4 print setup, with the header row repeated on every printed page
- **PDF** files are A4, landscape for wide reports, with the header row repeated on every page, page "x of y", and the generated date.
- **Print** opens the Windows print dialog, where you choose the printer. **Preview** shows the PDF first.
- You choose where each file is saved.
- Purchase cost and profit columns only appear for users allowed to view purchase prices or financials.
