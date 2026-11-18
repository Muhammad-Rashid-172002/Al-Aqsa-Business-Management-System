# AL-AQSA CCTV & SOLAR SYSTEM — Windows Build & Deployment Guide

Status: the `windows/` folder is included. It was generated from the Flutter 3.41.6
`flutter create` templates and customised: title "AL-AQSA CCTV & SOLAR SYSTEM", 1440×900 window,
1200×720 minimum size, and the app icon. **No Windows build has been produced or
run yet.** Follow this guide on the Windows PC and report the results.

## 1. One-time setup of the build PC

| Requirement | Notes |
|---|---|
| Windows 10 or 11, 64-bit | |
| Flutter **3.41.6** stable (Dart 3.11.4) | Same version as the Mac. Download from flutter.dev and add `flutter\bin` to PATH. **Do not upgrade.** |
| Visual Studio 2022 (Community is fine) | Workload **"Desktop development with C++"** (includes MSVC v143, a Windows 10/11 SDK and CMake). Visual Studio *Code* is not enough. |
| Git for Windows | Flutter needs it. |
| Internet on the **first** build | The `printing` plugin downloads PDFium (`pdfium-win-x64.tgz`, chromium/5200) from GitHub while building. After that, builds and the app work offline. |

Check it:
```powershell
flutter doctor -v
```
"Visual Studio - develop Windows apps" must show a green tick. Android and Chrome warnings can be ignored.

## 2. Build

Unzip the project, for example to `C:\Projects\al_aqsa_cctv` (keep the path short and without non-English characters). Then:

```powershell
cd C:\Projects\al_aqsa_cctv
flutter doctor -v
flutter config --enable-windows-desktop
flutter pub get
flutter analyze
flutter test
flutter build windows --release
```

Output: `build\windows\x64\runner\Release\`
```
al_aqsa_cctv.exe
flutter_windows.dll
pdfium.dll           <- from the printing plugin
printing_plugin.dll
data\                <- app code + assets (icudtl.dat, flutter_assets, app.so)
```
**Always copy the whole Release folder.** The exe does not run on its own.

## 3. Run it

Double-click `build\windows\x64\runner\Release\al_aqsa_cctv.exe`, or run:
```powershell
.\build\windows\x64\runner\Release\al_aqsa_cctv.exe
```
On first launch it asks you to create the owner account. There are no built-in passwords.

## 4. Runtime requirements on the shop PC

* Windows 10/11 64-bit.
* **Microsoft Visual C++ 2015–2022 Redistributable (x64)**: `vcruntime140.dll`, `vcruntime140_1.dll`, `msvcp140.dll`.
  Most PCs already have it. If the app says a DLL is missing, install `vc_redist.x64.exe` from Microsoft. The installer below can include it, so no internet is needed at the shop.
* A printer driver for the receipt printer (most 58/80 mm thermal printers install as a normal Windows printer).
* No internet, .NET, Java or database server is needed.

## 5. Professional installer (Inno Setup)

1. Install **Inno Setup 6** (free): https://jrsoftware.org/isinfo.php
2. Optional, for offline VC++ runtime: download `vc_redist.x64.exe` from Microsoft and save it as `installer\redist\vc_redist.x64.exe`.
3. Build the app (section 2), then:
   ```powershell
   & "C:\Program Files (x86)\Inno Setup 6\ISCC.exe" installer\al_aqsa_cctv.iss
   ```
4. Result: `installer\output\AL_AQSA_CCTV_Setup_1.0.0.exe`. It:
   - installs to `C:\Program Files\AL-AQSA CCTV & SOLAR SYSTEM` (an upgrade keeps the existing folder: same AppId)
   - adds Start-menu and optional desktop shortcuts
   - installs the VC++ runtime if missing (when included)
   - **never deletes shop data**, on uninstall or upgrade.

Before each release, update `AppVersion` in the `.iss` file and `version:` in `pubspec.yaml`.

## 6. Where data and backups are stored

| What | Location |
|---|---|
| Database (Hive files) | `%APPDATA%\AL AQSA CCTV\data\` (e.g. `C:\Users\<user>\AppData\Roaming\AL AQSA CCTV\data`) |
| Local backups (second copy) | `%APPDATA%\AL AQSA CCTV\backups\` |
| Product images, shop logo | `%APPDATA%\AL AQSA CCTV\media\` |
| Backups (default) | `D:\AL-AQSA_Backups\` (changeable in Backup & Restore) |
| External backups | The folder chosen in **Backup & Restore** (use a USB drive, e.g. `E:\AQSA Backups`) |
| Single-instance lock | `%APPDATA%\AL AQSA CCTV\app.lock` |

The path is fixed in code (`lib/data/app_paths.dart`). It does not depend on the exe name or version, so upgrades always find the data. Advanced: set the environment variable `AQSA_DATA_DIR` to store data elsewhere (for a portable install).

Data is stored for the Windows user account that runs the app. Use the same Windows login every day.

## 7. Upgrading without losing data

1. In the app: **Backup & Restore → Backup Now** (to the USB drive too).
2. Close the app.
3. Run the new `AL_AQSA_CCTV_Setup_x.y.z.exe`, or replace the Release folder contents.
4. Start the app. Schema migrations run automatically (`lib/data/migrations.dart`): older data and older backups are upgraded in place.
5. Check the dashboard figures, then **Backup & Restore → Run check**.

If anything looks wrong: **Restore from file…** and pick the backup from step 1. A restore always saves the current data as a safety backup first.

## 8. Moving to a new computer

1. Old PC: Create Backup Now → copy `AL-AQSA_Backup_<date>.zip` from `D:\AL-AQSA_Backups` to USB.
2. New PC: install the app, create a temporary owner account, then go to **Backup & Restore → Restore from file…**
3. Log in with the shop's original owner account.

## 9. Windows-specific checks to do once (cannot be done on a Mac)

See `docs/RELEASE_CHECKLIST.md`, section "Windows hardware".

## 10. Troubleshooting

| Symptom | Fix |
|---|---|
| `flutter build windows` fails downloading pdfium | Connect to the internet for the first build, or let the GitHub URL through the firewall. |
| "Unable to find suitable Visual Studio toolchain" | Install the "Desktop development with C++" workload, then restart PowerShell. |
| App says "already open" | Another copy is running (check the taskbar / Task Manager). |
| `VCRUNTIME140.dll was not found` | Install the VC++ Redistributable (section 4). |
| Receipt prints blank or tiny | Settings → Printing: choose the 58/80 mm format and the thermal printer; set the printer's paper size in Windows printer preferences. |
| Antivirus quarantines the exe | Add an exclusion for `C:\Program Files\AL-AQSA CCTV & SOLAR SYSTEM`, or sign the exe with a code-signing certificate. |

## Data folder name
The data folder keeps the name `%APPDATA%\AL AQSA CCTV` after the rename to
AL-AQSA CCTV & SOLAR SYSTEM, on purpose: an upgrade must find the existing shop
data. The executable is still `al_aqsa_cctv.exe` for the same reason; its
product name, description, window title and shortcuts use the new name.

## Background backup mode
`al_aqsa_cctv.exe --backup-now` (started by the Windows scheduled task the app
registers) opens no window, makes the automatic backup if it is due and exits.
If the app is already open it exits at once and the open app makes the backup.
