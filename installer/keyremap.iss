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
Source: "..\data\layouts.json"; DestDir: "{app}\data"; Flags: ignoreversion
Source: "layouts.ini"; Flags: dontcopy
Source: "..\build\x86\kbdisdv.dll"; DestDir: "{app}\build\x86"; Flags: ignoreversion
Source: "..\build\x64\kbdisdv.dll"; DestDir: "{app}\build\x64"; Flags: ignoreversion
Source: "..\build\arm64\kbdisdv.dll"; DestDir: "{app}\build\arm64"; Flags: ignoreversion

[Run]
Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\scripts\install.ps1"" -ManifestPath ""{app}\data\layouts.json"" -SelectionFile ""{tmp}\keyremap-selected-layouts.txt"" -Force"; StatusMsg: "Installing selected keyboard layouts..."; Flags: runhidden waituntilterminated

[UninstallRun]
Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\scripts\uninstall.ps1"" -ManifestPath ""{app}\data\layouts.json"""; RunOnceId: "UninstallKeyboardLayouts"; Flags: runhidden waituntilterminated

[Code]
var
  LayoutPage: TWizardPage;
  LayoutList: TNewCheckListBox;
  LayoutIds: array of String;
  LayoutPackaged: array of Boolean;
  LayoutIni: String;

function BoolFromIni(Value: String): Boolean;
begin
  Result := Value = '1';
end;

procedure InitializeWizard;
var
  I, Count: Integer;
  Id, Name, Xkb, Caption, ExistsText, PackagedText: String;
  Packaged, WindowsExists: Boolean;
begin
  ExtractTemporaryFile('layouts.ini');
  LayoutIni := ExpandConstant('{tmp}\layouts.ini');

  LayoutPage := CreateCustomPage(wpSelectDir, 'Select Linux keyboard layouts',
    'Choose the xkeyboard-config layouts to install.');

  LayoutList := TNewCheckListBox.Create(LayoutPage);
  LayoutList.Parent := LayoutPage.Surface;
  LayoutList.Left := 0;
  LayoutList.Top := 0;
  LayoutList.Width := LayoutPage.SurfaceWidth;
  LayoutList.Height := LayoutPage.SurfaceHeight;
  LayoutList.WantTabs := True;
  LayoutList.BorderStyle := bsSingle;

  Count := StrToIntDef(GetIniString('Layouts', 'Count', '0', LayoutIni), 0);
  SetArrayLength(LayoutIds, Count);
  SetArrayLength(LayoutPackaged, Count);

  for I := 1 to Count do begin
    Id := GetIniString('Layouts', 'Id' + IntToStr(I), '', LayoutIni);
    Name := GetIniString('Layouts', 'Name' + IntToStr(I), Id, LayoutIni);
    Xkb := GetIniString('Layouts', 'Xkb' + IntToStr(I), '', LayoutIni);
    WindowsExists := BoolFromIni(GetIniString('Layouts', 'WindowsExists' + IntToStr(I), '0', LayoutIni));
    Packaged := BoolFromIni(GetIniString('Layouts', 'Packaged' + IntToStr(I), '0', LayoutIni));

    ExistsText := '';
    if WindowsExists then
      ExistsText := '  [Windows has related layout]';
    PackagedText := '  [not built yet]';
    if Packaged then
      PackagedText := '  [ready]';

    Caption := Name + '  (' + Xkb + ')' + ExistsText + PackagedText;
    LayoutIds[I - 1] := Id;
    LayoutPackaged[I - 1] := Packaged;
    LayoutList.AddCheckBox(Caption, '', 0, Packaged, Packaged, False, True, nil);
  end;
end;

function NextButtonClick(CurPageID: Integer): Boolean;
var
  I: Integer;
  Selected: String;
begin
  Result := True;
  if CurPageID = LayoutPage.ID then begin
    Selected := '';
    for I := 0 to LayoutList.Items.Count - 1 do begin
      if LayoutList.Checked[I] and LayoutPackaged[I] then
        Selected := Selected + LayoutIds[I] + #13#10;
    end;
    if Selected = '' then begin
      MsgBox('Select at least one layout marked [ready]. Layouts marked [not built yet] are shown for roadmap visibility but cannot be installed from this build.', mbError, MB_OK);
      Result := False;
      exit;
    end;
    SaveStringToFile(ExpandConstant('{tmp}\keyremap-selected-layouts.txt'), Selected, False);
  end;
end;
