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

Files under `generated/` are produced mechanically by `kbdutool.exe` from
`src/kbdisdv.klc`. They carry a Microsoft copyright notice at the top
because kbdutool emits its own header; the layout data within them is
original work based on the xkeyboard-config sources above. These files are
committed to the repository so that continuous integration can build
without installing MSKLC.
