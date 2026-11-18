; Inno Setup script for AL-AQSA CCTV & SOLAR SYSTEM (https://jrsoftware.org/isinfo.php)
; Build the app first:  flutter build windows --release
; Then open this file in Inno Setup Compiler and press Compile (or run: iscc installer\al_aqsa_cctv.iss)
; Optional: put Microsoft's vc_redist.x64.exe in installer\redist\ to install the VC++ runtime offline.

#define AppName "AL-AQSA CCTV & SOLAR SYSTEM"
#define OldAppName "AL AQSA CCTV"
; "&&" shows one "&" in wizard check-box captions
#define AppNameCaption "AL-AQSA CCTV && SOLAR SYSTEM"
#define AppVersion "1.1.0"
#define AppExe "al_aqsa_cctv.exe"
#define BuildDir "..\build\windows\x64\runner\Release"

[Setup]
AppId={{F4530189-5E0D-4B12-AC20-2EBA57E957E5}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher=AL-AQSA CCTV & SOLAR SYSTEM
AppVerName={#AppName} {#AppVersion}
VersionInfoProductName={#AppName}
VersionInfoDescription={#AppName} Setup
VersionInfoVersion={#AppVersion}
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
OutputDir=output
OutputBaseFilename=AL-AQSA_CCTV_and_Solar_System_Setup_{#AppVersion}
; Same AppId as earlier versions: an upgrade keeps the existing install folder.
UsePreviousAppDir=yes
SetupIconFile=..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#AppExe}
; Official AL-AQSA logo on the wizard pages (normal and 200% DPI).
WizardImageFile=wizard_image.bmp,wizard_image_200.bmp
WizardSmallImageFile=wizard_small.bmp,wizard_small_200.bmp
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
PrivilegesRequired=admin
; Closes a running copy before upgrading
CloseApplications=yes

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Shortcuts:"

[Files]
Source: "{#BuildDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "redist\vc_redist.x64.exe"; DestDir: "{tmp}"; Flags: deleteafterinstall skipifsourcedoesntexist

[Icons]
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\{#AppExe}"; IconFilename: "{app}\{#AppExe}"; IconIndex: 0
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExe}"; IconFilename: "{app}\{#AppExe}"; IconIndex: 0; Tasks: desktopicon

[InstallDelete]
; Shortcuts with the previous product name
Type: files; Name: "{autoprograms}\{#OldAppName}.lnk"
Type: files; Name: "{autodesktop}\{#OldAppName}.lnk"

[Run]
Filename: "{tmp}\vc_redist.x64.exe"; Parameters: "/install /quiet /norestart"; StatusMsg: "Installing Microsoft Visual C++ runtime..."; Check: VCRedistNeeded; Flags: skipifdoesntexist waituntilterminated
Filename: "{app}\{#AppExe}"; Description: "Start {#AppNameCaption}"; Flags: nowait postinstall skipifsilent

[UninstallRun]
; Remove the daily backup task the app registers (backup files are kept).
Filename: "schtasks.exe"; Parameters: "/Delete /TN ""AL-AQSA CCTV & SOLAR SYSTEM\Daily Backup"" /F"; Flags: runhidden; RunOnceId: "RemoveBackupTask"

; Shop data lives in %APPDATA%\AL AQSA CCTV (folder name kept from earlier
; versions so upgrades find the data) and is NEVER removed by uninstall or
; upgrade. Backups in D:\AL-AQSA_Backups are never touched by the installer.

[Code]
function VCRedistNeeded(): Boolean;
var Installed: Cardinal;
begin
  Result := not (RegQueryDWordValue(HKLM64, 'SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64', 'Installed', Installed) and (Installed = 1));
end;
