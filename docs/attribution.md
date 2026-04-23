# Attribution

## Layout data

The Icelandic Dvorak key assignments and dead-key compose tables are derived
from [xkeyboard-config](https://gitlab.freedesktop.org/xkeyboard-config/xkeyboard-config),
specifically the `symbols/is` file (for the `dvorak` variant) and the
`symbols/us` file (for the `dvorak` base and dead-key definitions).

xkeyboard-config is distributed under the MIT License. The relevant
copyright holders for the `is(dvorak)` variant include Ævar Arnfjörð
Bjarmason and the xkeyboard-config maintainers.

## Build toolchain

- `kbdutool.exe` (used at development time to regenerate C from KLC) ships
  with **Microsoft Keyboard Layout Creator 1.4**, a free Microsoft download.
  MSKLC itself is not redistributed by this project.
- `kbd.h` is part of the **Windows 10/11 SDK** (`Include\<version>\um\`).
  It is read at build time from the SDK installation on the developer's or
  CI's machine. It is not redistributed by this project. The header has
  historically lived in the WDK `km\` directory as well — the build script
  finds it in either location.
- Compilation relies on Microsoft Visual C++ (MSVC) from Visual Studio Build
  Tools 2022. Not redistributed.

## Generated files

The `generated/` directory is produced at build time from `src/kbdisdv.klc`
via `kbdutool.exe` (part of the free MSKLC 1.4 download). It contains
Microsoft-copyrighted kbdutool header text that we therefore never commit
to version control; CI installs MSKLC on each run and regenerates them
fresh. Local developers can do the same via `scripts\generate.ps1`.
