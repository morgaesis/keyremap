# Roadmap

## v0.1 — Icelandic Dvorak MVP  *(current)*

- [x] Hand-authored KLC for `is(dvorak)` with 11 dead-key compose tables
- [x] CI pipeline: x86 / x64 / arm64 DLLs per commit
- [x] Install / uninstall PowerShell scripts
- [x] Golden-file QA (dead-key table reflection via P/Invoke)
- [ ] Published GitHub release with signed DLLs

## v0.2 — CapsLock as AltGr

Extend the KLC with an option (preprocessor flag or build variant) that
remaps the CapsLock physical key to behave as a second AltGr — the user's
hardware habit from Linux, where `xkb_options = lv3:caps_switch` is a
common setting.

Implementation plan:
1. Use Windows' scancode map feature or a second variant of the DLL that
   declares VK_CAPITAL as VK_RMENU-like. This can be done by patching the
   VSC-to-VK and VK-to-WCHAR tables in the generated C source.
2. Ship as a build variant `kbdisdv-caps.dll` alongside the standard one.
3. install.ps1 takes `-CapsAsAltGr` switch.

## v0.3 — CapsLock as generic remap

Expose CapsLock rebinding as a data-driven choice: Esc, Ctrl, AltGr,
Compose, BackSpace, or passthrough. Each is a separate compiled DLL with a
shared build recipe.

## v0.4 — xkb → KLC converter

The load-bearing long-term goal. Take an xkb symbols file and a variant
name (e.g. `is(dvorak)`), produce a valid KLC. This unlocks the entire
xkeyboard-config catalog (~180 layouts, ~500 variants).

Design direction (see `docs/research.md`):
- Parse xkb symbols with a small Rust or Python parser (xkb grammar is
  tractable, ~300 LOC).
- Resolve `include` chains to get a flat 4-level table.
- Map keysyms to Unicode codepoints via `keysymdef.h`.
- Translate `dead_*` keysyms to Windows DEADKEY sections.
- Emit KLC, shell out to kbdutool to produce C, build with MSVC.

**Alternative:** vendor [klfc](https://github.com/39aldo39/klfc) (Haskell,
unmaintained but functional) as a Git submodule and use it as the xkb
parser. Less code to write; exposes us to a dead dependency.

Decision deferred until v0.4.

## v0.5 — UI installer

Right now the install flow is "unzip + run .ps1 as admin". A GUI installer
(WiX / MSI, or a small WinUI app) would:
- Show available layouts with previews
- Let users toggle compose/CapsLock variants
- Uninstall cleanly via Control Panel
- Not require Administrator in the common case (per-user install if
  possible — Windows does permit per-user keyboard layouts via
  `HKCU\Keyboard Layout`, but the DLL still has to live somewhere
  system-readable)

## Deferred / unclear

- **Compose key sequences** (e.g. Compose + o + e → œ). Windows kbd DLLs
  only support a single dead-key level, so this cannot be done in the DLL
  itself. Could be layered via a small background helper — but that
  reintroduces the "program must be running" problem the project is
  designed to avoid.
- **Per-application layouts.** Windows does support language-bar-per-app
  if the app opts into TSF. Not something we can change from the kbd
  driver side.
- **International mixed layouts** (Thai, Japanese, Chinese). These use
  IMEs, not kbd DLLs. Out of scope.
