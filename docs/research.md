# Research Notes

## Windows

The native Windows route is a keyboard layout DLL. Microsoft's Keyboard Layout
Samples describe the important pieces: a layout DLL is loaded by the window
manager, contains scan-code to virtual-key tables and virtual-key to character
tables, and exports entry points such as `KbdLayerDescriptor`.

Windows lists valid keyboard layouts under:

```text
HKLM\SYSTEM\CurrentControlSet\Control\Keyboard Layouts
```

The relevant values for this project are `Layout File`, `Layout Text`, optional
`Layout Display Name`, and optional `Layout Id`. A layout must also be attached
to the current user, typically through `HKCU\Keyboard Layout\Preload` or the
Settings UI. `LoadKeyboardLayoutW` can load and activate a KLID once the layout
is registered.

MSKLC 1.4 is useful here only for `kbdutool.exe`, which converts `.klc` to the
C tables expected by `kbd.h`. The old MSKLC setup package is the weak part on
Windows 11 ARM64, so this repo does not use it.

Alternatives rejected as the primary path:

- PowerToys, AutoHotkey, Kanata, and KMonad are background remappers. Useful
  for layers and chords, but not native language-switcher layouts.
- TSF/IME is the right technology for candidates or complex composition, but
  it is much more expensive to build and requires IME-specific packaging and
  signing constraints.
- Low-level hooks have timeout, focus, integrity-level, and serviceability
  limits that are wrong for a simple character layout.

## Linux/XKB

xkeyboard-config stores country layouts under `symbols/<country-code>`.
Icelandic lives in `symbols/is`; `is(dvorak)` includes:

```xkb
include "us(dvorak)"
include "eurosign(4)"
include "level3(ralt_switch)"
```

and overrides these keys:

```xkb
key <AD11> { [ slash, question, U201e, U201c ] };
key <AC02> { [ o, O, odiaeresis, Odiaeresis ] };
key <AC06> { [ d, D, eth, ETH ] };
key <AC10> { [ s, S, ae, AE ] };
key <AC11> { [ minus, underscore, endash, emdash ] };
key <AB10> { [ z, Z, thorn, Thorn ] };
key <AB06> { [ b, B, ssharp, U1E9E ] };
```

For the common four-level Latin case, XKB levels map cleanly to Windows KLC
columns:

```text
level 1 -> normal
level 2 -> Shift
level 3 -> AltGr
level 4 -> Shift+AltGr
```

Dead keys are a semantic mismatch. XKB emits `dead_*` keysyms, while Linux
composition is handled through Compose files and can be locale/user dependent.
Windows requires explicit `DEADKEY` tables in the layout. This project includes
the dead-key tables needed by the imported US Dvorak base.

## Practical Conclusion

For `is(dvorak)`, the smallest dependable deliverable is:

1. Keep a canonical KLC file.
2. Regenerate C sources with `kbdutool`.
3. Compile `kbdisdv.dll` for each target architecture.
4. Register the DLL as a normal Windows layout.
5. Verify the PE architecture, exported descriptor, AltGr flag, and dead-key
   tables.
