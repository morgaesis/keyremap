# keyremap

Native Windows keyboard layouts ported from Linux xkeyboard-config.

The target is broad xkeyboard-config coverage: Linux keyboard layouts packaged
as Windows `kbd*.dll` files, not background remappers, so selected layouts can
be registered as normal Windows keyboard layouts and selected with `Win+Space`.

## Why This Path

Windows keyboard layouts are DLLs loaded by the window manager. Microsoft
documents the model in the Windows Driver Samples: a layout DLL contains
scan-code to virtual-key tables plus virtual-key to character tables, and
exports `KbdLayerDescriptor`.

Windows discovers installed layouts from:

```text
HKLM\SYSTEM\CurrentControlSet\Control\Keyboard Layouts\<KLID>
```

with values such as `Layout File` and `Layout Text`. The installer in this
repo registers `kbdisdv.dll` there, adds it to the current user's preload list,
and calls `LoadKeyboardLayoutW`.

MSKLC's GUI and generated installer are not the dependable part of the stack,
especially on Windows 11 ARM64. This repo only uses MSKLC's `kbdutool.exe` to
convert a `.klc` source file into C tables, then builds those tables with a
modern compiler.

## Layouts

`data\layouts.json` is the installable-layout manifest. The installer also
shows the broader Linux/Windows candidate catalog generated from
xkeyboard-config, including layouts not built yet.

The first packaged layout is `is-dvorak`. `src\kbdisdv.klc` is its source of
truth. It is a Windows KLC port of xkeyboard-config `is(dvorak)`:

- base: `us(dvorak)`
- overlay: `eurosign(4)`
- AltGr: `level3(ralt_switch)`
- overrides: `„ “ ð Ð æ Æ ö Ö þ Þ ß ẞ – — €`

The US Dvorak dead keys inherited by xkeyboard-config are represented as
Windows `DEADKEY` tables.

## Build

Prerequisites:

- Microsoft Keyboard Layout Creator 1.4, for `kbdutool.exe`
- Visual Studio 2022 Build Tools with Desktop C++
- Windows 10/11 SDK, for `kbd.h`
- For ARM64 output: `MSVC v143 - VS 2022 C++ ARM64/ARM64EC build tools`

Build:

```powershell
.\scripts\build.ps1 -Arch x64
.\scripts\build.ps1 -Arch arm64
```

Output:

```text
build\<arch>\kbdisdv.dll
```

The build script verifies the PE machine type and `KbdLayerDescriptor` export.
It also checks that `VsDevCmd` selected the requested compiler architecture;
this catches the common ARM64 failure where Visual Studio silently leaves
`cl.exe` pointed at x64.

## Install

For a visible setup wizard, build and run the installer:

```powershell
.\scripts\build-installer.ps1
.\installer\Output\keyremap-setup.exe
```

The installer requests elevation, copies the architecture-matched DLL, registers
the keyboard layout, and adds an uninstaller entry in Windows.

For script-based local development, open PowerShell as Administrator:

```powershell
.\scripts\install.ps1
```

To install a specific DLL:

```powershell
.\scripts\install.ps1 -DllPath .\build\arm64\kbdisdv.dll
```

Uninstall:

```powershell
.\scripts\uninstall.ps1
```

## Verification Checklist

After installing on the Windows 11 ARM64 laptop, test:

- `Win+Space` shows `Icelandic Dvorak`
- Notepad: base Dvorak keys and AltGr Icelandic letters
- Start search and Settings search
- Microsoft Store or another WinUI/UWP text field
- elevated prompt text entry
- sign-out/sign-in persistence

Render the installed layout through Windows' live translation APIs:

```powershell
.\tests\render-live-layout.ps1 -Klid 0001040f -ExpectedLayoutName "Icelandic Dvorak" -AssertIcelandicDvorak -HtmlPath .\artifacts\is-dvorak-live.html
```

This calls `MapVirtualKeyEx` and `ToUnicodeEx` for the registered layout, so it
checks the same key translation path applications use. It also resolves the
registered display name through Windows' registry string indirection. The HTML
output shows normal, Shift, AltGr, and Shift+AltGr for each physical key.

## Sources

- xkeyboard-config `symbols/is`, variant `dvorak`
- xkeyboard-config `symbols/us`, variant `dvorak`
- Microsoft Keyboard Layout Samples
- Microsoft Keyboard Identifiers documentation
- Microsoft `LoadKeyboardLayout` documentation

See [docs/research.md](docs/research.md) for the investigation notes.

## Bulk Linux Layout Catalog

The repo includes a review pipeline for broader xkeyboard-config coverage:

```powershell
.\tools\generate-layout-catalog.ps1
```

It parses xkeyboard-config metadata, compares it with the local Windows
keyboard registry, and writes:

- `data\windows-keyboards.local.json`
- `data\xkb-windows-candidates.json`
- `docs\layout-candidates.md`

This is intentionally review-first. Many XKB entries depend on Compose,
IME-like behavior, higher-level groups, or hardware assumptions that are not
safe to auto-ship as KLC DLLs without inspection.

The GUI installer displays this catalog. Layouts marked `[ready]` have packaged
DLLs and can be selected for installation. Layouts marked `[not built yet]` are
visible so the full Linux target set is clear, but they are disabled until the
bulk generator/build pipeline has produced verified DLLs for them.

On Windows 11 ARM, plain ARM64 keyboard DLLs are not enough for x64-compatible
text hosts. Until ARM64EC/ARM64X keyboard DLLs are produced, the installer uses
the x64-compatible payload on ARM systems.
