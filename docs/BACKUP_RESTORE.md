# Backup & Restore — AL-AQSA CCTV & SOLAR SYSTEM (18 Nov 2026)

## Where things are
| What | Where |
|---|---|
| Live database (Hive) | `%APPDATA%\AL AQSA CCTV\data` — not in the install folder |
| Product images, shop logo | `%APPDATA%\AL AQSA CCTV\media` (copied there when chosen) |
| Backups (default) | `D:\AL-AQSA_Backups\` — created automatically; changeable |
| Second copy of each backup | `%APPDATA%\AL AQSA CCTV\backups` |

## Backup file
`AL-AQSA_Backup_2026-11-18.zip` (a second one that day: `_2`, `_3` …; an
existing file is never overwritten; safety copies before a restore end in
`_before-restore`). Inside:
* `data.json` — every record (products, categories, stock, cost layers,
  serial numbers, purchases, sales, returns, quotations, customers, suppliers,
  payments, ledger, technicians, warranty, repairs, settings, audit log),
  taken as one consistent snapshot of the database (not a copy of the open
  database files);
* `files/` + `files.json` — product images, the shop logo and any other file
  in the media folder, with size and SHA-256 of each;
* `manifest.json` — app name and version, date, record counts per table,
  SHA-256 of `data.json` and of the file list.

Account password hashes are blanked in backups (the app has no login). No API
keys or other credentials exist in the app. Invoices / PDFs are not stored as
files by the app — they are generated from the data, so restoring the data
restores them.

## Automatic backup
* ON/OFF and daily time (hour : minute) in Backup & Restore.
* Due when no automatic backup succeeded since the last scheduled time. Checked
  20 s after start-up, every minute while the app is open, and by a **Windows
  Task Scheduler** task (`AL-AQSA CCTV & SOLAR SYSTEM\Daily Backup`) that runs
  `al_aqsa_cctv.exe --backup-now` without a window even when the app is
  closed; "start when available" makes Windows run a missed task soon after the
  computer is switched on. Result: a backup missed because the PC was off or
  the app closed is made at the next opportunity.
* The state (last success, last error) is stored in the database, so it
  survives restarts.
* Failure (drive missing, no permission, disk full): the error is saved and
  shown (red banner, notification bell); the backup is NOT recorded as
  successful; a copy is still written to the local folder; the next attempt is
  an hour later.
* Retention: per folder, the newest *N* automatic backups are kept (7–90,
  default 30); older automatic ones are deleted. Manual backups and
  before-restore safety copies are never deleted by the app.

## Restore
Restore Backup → choose a `.zip` (or an old `.aqbak`) from D: or anywhere →
the file is checked completely (zip integrity, SHA-256 of data, file list and
every image, record counts, app/version) → a preview shows the date, version
and contents (products, serials, invoices, customers, images …) and warns if it
is older than the latest backup → tick "I understand" → Restore:
1. a safety backup of the current data is written;
2. images are unpacked to a staging folder and checked;
3. all records are replaced in ONE atomic database commit (the database
   journal makes it all-or-nothing, also on power loss);
4. images move into the media folder; image paths are re-pointed to this
   computer (needed after a reinstall: the Windows user folder may differ);
5. counts and image files are verified; the app re-opens the restored data.
If anything fails before step 3 nothing changes. Restore replaces everything,
so restoring the same backup twice never creates duplicates.

## Windows reinstall
D: survives a Windows reinstall **only if the D: partition is not formatted or
deleted**. It does not protect against the disk failing, theft or fire: also
copy backups to a USB drive or external disk regularly (or set the USB drive
as the backup location). After reinstalling: install the app → Backup &
Restore → Restore Backup → choose the newest file in `D:\AL-AQSA_Backups`.

## Tested here vs. to test on Windows
Tested in the developer workspace (pure Dart on real Hive files, Linux):
manual backup naming/no overwrite, password stripping, missing / unwritable
backup folder, schedule + catch-up + restart, retention, corrupted / tampered /
incomplete zips, full restore onto a fresh "installation" with image and logo
remapping, repeated restore, old-format restore, task XML.
**Not yet tested on Windows:** the Task Scheduler task, `--backup-now` hidden
mode, a real D: drive missing, Explorer "Open folder", the installer, an actual
Windows reinstall. Recovery after a reinstall is not claimed to work on Windows
until done — see the checklist in `docs/RELEASE_CHECKLIST.md`.
