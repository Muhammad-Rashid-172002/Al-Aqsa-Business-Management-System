# Permanent delete — what is and is not erased

Owner only (permission `permanentDelete`). Staff keep the earlier archive behaviour.

## Flow
1. ⋮ → **Delete** opens "Delete <type>". It shows the record's type and exact name, what will be erased, and which files are kept because other records still use them.
   - If the record is linked to financial, stock or job history, it **cannot** be erased. The dialog explains why and offers the safe alternative: archive, cancel invoice, purchase return.
2. **Delete** opens "Permanently delete?".
   - The dialog says the action cannot be undone and that backups are not changed.
   - **Permanently Delete** stays disabled until "I understand" is ticked.
   - The button works once; double execution is blocked in the UI and in the service.
3. The deletion runs in **one atomic transaction**, followed by verification. Success is shown only after the check passes.
4. If backup files still contain the record, the app lists them. **Keep backups** is the default. **Purge from backups…** requires typing `PURGE`.

## Full cascade: what is erased (current database, verified)
Owner's choices (19 Nov):
- When a customer is erased, the goods on its invoices **stay sold**.
- When a supplier is erased, the stock received **stays in stock**.

| Delete | Erased with it | Kept, only the link removed | Refused when |
|---|---|---|---|
| **Customer** | Profile; **all** its invoices (draft, completed, cancelled); all its payments (at sale and on account); all its ledger entries (opening balance included); customer returns; quotations; repair jobs; warranty claims | Sold serial numbers (stay *Sold*, no customer/invoice); stock movements and return cost batches (stock history); technician installations billed on its invoices (stay *invoiced*, never billed again) | Never |
| **Supplier** | Profile; **all** its purchases, payments, ledger entries and supplier returns | Stock received: quantities and cost batches stay (each under a new anonymous batch id), so every serial keeps its own batch cost; serials lose the supplier link | Never |
| **Product** | Product; its own serial numbers and serial index rows; cost batches; stock movements; barcode / internal-code rows; zero technician holdings; inspection items; image (if not shared) | — | It appears on any invoice, purchase, return, quotation, technician, repair or warranty record (those belong to other customers / suppliers) |
| **Technician** | Profile; its material records that no invoice depends on; zero holdings; its login if never used, plus login history | Repairs and serials lose the link; a login with activity is kept, deactivated and anonymised | It still holds material, or its login is an owner account |
| **Category** | Category | Its products stay, uncategorised | Never |
| **Expense** | Expense and its receipt | — | Never |
| **Quotation / draft invoice** | The document | A converted invoice keeps working | A completed invoice on its own (use Cancel invoice, or delete its customer) |

**For every erased record:**
- Its audit entries keep only `[permanently deleted]`.
- Notes that named it (stock movement reasons, serial history notes) are replaced by `[linked record permanently deleted]`.
- One new audit entry records the type, internal id and counts, with no names.
- Everything runs in **one commit**.

**Verification after the commit:**
- every erased record is gone;
- **no record in the database still contains any erased id**;
- the audit details are scrubbed.

Success is shown only after that. Dashboard, reports, receivables, payables, payment summaries and search are computed from the remaining data and refresh at once. The data is gone after a restart.

The confirmation shows the **exact number of records per type** that will be erased, and how many kept records lose a link.

## Backups
- A permanent delete **does not change any backup file**. Older backups can still restore the record; they are your recovery copies.
- **Purge from backups** (`PURGE` typed):
  1. Saves a **restore block**: the record's internal ids only, no name.
  2. Opens every backup in the backup folder (D:\AL-AQSA_Backups or the folder you chose) and in the app's local backup folder, which holds the safety copies.
  3. Rewrites each file that contains the record, using **the same plan**: every cascaded record is erased, links in kept records are removed, and exclusive images are dropped. The new file is fully re-checked (checksums, counts) and verified not to contain the record before it replaces the original. On failure the original is kept and the failure is reported.
  4. Scans again and reports how many files were rewritten, how many were checked clean, and which were unreadable or failed.
- The app says "Removed from all checked backups" only when every backup in those folders was opened and none contains the record.
- **Copies outside those folders** (USB, cloud, e-mail) cannot be seen and are **not** changed. Because of the restore block, restoring any of them on this computer still skips the purged record.
