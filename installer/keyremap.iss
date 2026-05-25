#define AppName "Keyremap"
#define AppVersion "0.1.0"
#define AppPublisher "morgaesis"

[Setup]
AppId={{1F54B8DA-F1D8-4B12-A383-28F6F6BD47C2}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher={#AppPublisher}
DefaultDirName={autopf}\Keyremap
DefaultGroupName=Keyremap
DisableProgramGroupPage=yes
OutputDir=Output
OutputBaseFilename=keyremap-setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible or arm64
ArchitecturesInstallIn64BitMode=x64compatible or arm64
UninstallDisplayName=Keyremap keyboard layouts

[Files]
Source: "..\README.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\LICENSE"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\scripts\install.ps1"; DestDir: "{app}\scripts"; Flags: ignoreversion
Source: "..\scripts\uninstall.ps1"; DestDir: "{app}\scripts"; Flags: ignoreversion
Source: "..\build\x86\kbdisdv.dll"; DestDir: "{app}\build\x86"; Flags: ignoreversion
Source: "..\build\x64\kbdisdv.dll"; DestDir: "{app}\build\x64"; Flags: ignoreversion
Source: "..\build\arm64\kbdisdv.dll"; DestDir: "{app}\build\arm64"; Flags: ignoreversion

[Run]
Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\scripts\install.ps1"" -Force"; StatusMsg: "Installing Icelandic Dvorak keyboard layout..."; Flags: runhidden waituntilterminated

[UninstallRun]
Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\scripts\uninstall.ps1"""; RunOnceId: "UninstallKeyboardLayouts"; Flags: runhidden waituntilterminated
