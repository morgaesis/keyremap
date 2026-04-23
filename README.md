# keyremap

Native Windows keyboard layouts ported from Linux xkb — starting with Icelandic
Dvorak, eventually covering the full xkeyboard-config catalogue so users can
move their Linux keyboard muscle memory to Windows with no background program.

## Why

EPKL, AutoHotkey, PowerToys Keyboard Manager, and Kanata all work by hooking
keys from a running process. If the process stops or crashes, the remaps go
away. They also do not appear in Windows' standard layout picker — Win+Space
will not swap them with "English (US)" or "Icelandic" when a coworker borrows
your machine.

A native kbd\*.dll is different. Windows loads it into winlogon and every
process, it appears in the Settings layout list, and Win+Space toggles to and
from it instantly. Nothing to start, nothing to stop.

## Status

| Layout | xkb name | Status |
|---|---|---|
| Icelandic Dvorak | `is(dvorak)` | **MVP** — see `src/kbdisdv.klc` |
| *(everything else)* | various | planned — see `docs/roadmap.md` |

Built on Windows 11 ARM64 (Snapdragon X), x64, and x86. CI produces all three.

## Install (end user)

1. Download the latest release zip from
   [Releases](https://github.com/morgaesis/keyremap/releases).
2. Unzip, open PowerShell as Administrator in the unzipped folder:
   ```powershell
   .\install.ps1
   ```
3. Sign out and back in (or reboot) so Windows picks up the new DLL.
4. Win+Space to switch. Look for **Icelandic Dvorak** in the layout picker.

To remove:
```powershell
.\uninstall.ps1
```

## The layout

Faithful port of the Linux `is(dvorak)` variant: US Dvorak base + Icelandic
AltGr overlays. AltGr + key gives the Icelandic-specific characters; Shift +
AltGr gives the uppercase.

| Where | AltGr | Shift+AltGr |
|---|---|---|
| `4` | € | € |
| `'` (Dvorak position of QWERTY `q`) | dead_acute | dead_diaeresis |
| `o` | ö | Ö |
| `d` | ð | Ð |
| `s` | æ | Æ |
| `-` | – (en dash) | — (em dash) |
| `b` | ß | ẞ |
| `z` | þ | Þ |
| `/` | „ | " |

**Accented vowels** (á é í ó ú ý) are produced via the acute dead key:
AltGr+`'` then the vowel. All eleven dead keys from us(dvorak) are preserved
(acute, diaeresis, grave, tilde, circumflex, cedilla, caron, above-dot, breve,
ogonek, double-acute) with comprehensive compose tables for Western European,
Nordic, Central European, and Turkish characters.

See [`docs/layout.md`](docs/layout.md) for the full key table.

## Build (from source)

You need a Windows machine (any arch) with:

1. **Visual Studio 2022 Build Tools** with Desktop C++, the MSVC v143 ARM64
   build tools, and the **Windows 11 SDK** (10.0.22621 or newer — the SDK
   includes `kbd.h` under `Include\<ver>\um\`, which is the only non-MSVC
   dependency):
   ```powershell
   winget install Microsoft.VisualStudio.2022.BuildTools --override "--add Microsoft.VisualStudio.Workload.VCTools --add Microsoft.VisualStudio.Component.VC.Tools.ARM64 --add Microsoft.VisualStudio.Component.Windows11SDK.22621 --passive"
   ```
2. From the repo root, in PowerShell:
   ```powershell
   .\scripts\build.ps1 -Arch arm64
   # or x64, x86
   ```
   Output: `build\<arch>\kbdisdv.dll`.

Regenerating the C source from the KLC (only needed when editing
`src\kbdisdv.klc`) requires MSKLC 1.4, run `.\scripts\generate.ps1`. The
generated files are committed under `generated/` so CI does not need MSKLC.

## Architecture

```
src/kbdisdv.klc          ┐
                         │  scripts\generate.ps1  (local dev, MSKLC)
                         ▼
generated/kbdisdv.{c,h,def,rc}    ← committed
                         │
                         │  scripts\build.ps1  (MSVC + WDK, per-arch)
                         ▼
build/<arch>/kbdisdv.dll
                         │
                         │  scripts\install.ps1  (Administrator)
                         ▼
%SystemRoot%\System32\kbdisdv.dll + HKLM registry entry
```

The **source of truth** is `src/kbdisdv.klc` — a text format originally
defined by MSKLC. `kbdutool.exe` (MSKLC's CLI) converts `.klc` → C/H/DEF/RC,
which then compiles to a kbd\*.dll with any MSVC-targeting toolchain. We
commit the generated C so that CI on a fresh GitHub runner doesn't need MSKLC
installed — only MSVC + WDK. This keeps the build reproducible, fast, and
auditable.

## Roadmap

- [x] Icelandic Dvorak (`is(dvorak)`)
- [ ] CapsLock as AltGr overlay (feature flag in KLC)
- [ ] Automated xkb → KLC converter (targeting the 100+ layouts in
      xkeyboard-config)
- [ ] GUI installer / picker for end users
- [ ] Custom layouts from user-submitted KLCs

## License

MIT. Layout data is derived from xkeyboard-config (MIT). The `kbd.h` header
used at compile time is Microsoft's WDK — not redistributed, fetched locally.
See `LICENSE` and `docs/attribution.md`.
