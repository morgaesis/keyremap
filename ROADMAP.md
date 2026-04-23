# Roadmap

Each phase ships an incremental capability. Version numbers match Git tags.
**Done phases stay here as an audit trail** — do not delete, only add.

## v0.1.0 — Icelandic Dvorak MVP ✅

Native Windows kbd DLL for `is(dvorak)` with all 11 inherited dead keys,
installed via PowerShell script, built for x86/x64/ARM64 in CI.

Acceptance:
- `kbdisdv.dll` builds for three architectures on CI.
- `KbdLayerDescriptor` exports cleanly.
- Golden QA confirms 128 dead-key compose entries + AltGr flag.
- `install.ps1` registers the layout and adds it to the user's preload list.
- Layout appears in Windows Settings → Language.

## v0.1.1 — Cleanup of legal + UX roughness ✅ *(in progress)*

P0 tasks before the v0.1.0 tag:

- **Drop `generated/` from the repo.** CI installs MSKLC and regenerates the
  C source on every build so Microsoft-copyright artefacts never live in a
  public MIT repo.
- **No sign-out required after install.** `install.ps1` calls
  `user32!LoadKeyboardLayoutW` with `KLF_ACTIVATE` and broadcasts
  `WM_INPUTLANGCHANGEREQUEST` so the layout picker refreshes live.
- **MIT attribution audited.** `docs/attribution.md` enumerates everything
  third-party: xkeyboard-config (MIT) for layout data, Microsoft SDK
  (reference-only, not redistributed) for `kbd.h`, MSKLC (installed at
  build time, not redistributed) for `kbdutool.exe`.

Acceptance:
- `generated/` does not exist in `main` at the tag.
- `grep -r "Microsoft Corporation" .` returns zero hits on tracked files.
- Fresh install + immediate Win+Space lists "Icelandic Dvorak" without any
  sign-out or reboot, verified on this ARM64 box.

## v0.2.0 — CapsLock as AltGr

One new DLL variant: `kbdisdv-caps-altgr.dll`. CapsLock (SC 0x3A) behaves as
RAlt with the AltGr flag, giving the user a second AltGr key in the natural
Linux position.

Acceptance:
- Variant DLL built in the CI matrix.
- `install.ps1 -CapsAction AltGr` installs the variant DLL instead of the
  standard one.
- Verified locally: holding Caps + pressing `d` produces `ð`.

## v0.3.0 — CapsLock configurable

Extend v0.2 to cover the common user preferences: `Esc`, `Ctrl`, `AltGr`,
`None` (default, no remap). Ships as four variant DLLs from the same source.

Acceptance:
- Four build variants in CI.
- `install.ps1 -CapsAction <Esc|Ctrl|AltGr|None>` picks the right DLL.

## v0.4.0 — xkb → KLC converter

Python 3 stdlib-only tool that reads an `xkeyboard-config` symbols file and
emits the KLC format we already build. Seeded with: `is(dvorak)`,
`us(dvorak)`, `se(basic)`, `no(basic)`, `dk(basic)`, `fi(basic)`,
`de(basic)`, `es(basic)`, `fr(oss)` — the common European set.

Acceptance:
- `tools/xkb2klc/xkb2klc.py` round-trips `is(dvorak)` to match
  `src/kbdisdv.klc` (differences only in compose-table breadth).
- At least 8 additional layouts produce valid KLC.
- CI builds a DLL for each layout.

## v0.5.0 — MSI installer

WiX 3.14 MSI that a non-technical user can double-click to install. Bundles
all layouts from v0.4, offers a layout picker + Caps-action picker, calls
`LoadKeyboardLayoutW` from a CustomAction. One MSI per architecture.

Acceptance:
- `keyremap-<arch>.msi` built by CI on tag push.
- Double-click install works end-to-end on Windows 11 ARM64.
- Control Panel → Programs lists it; uninstall cleans everything.

## v0.6.0 — Contribution infrastructure

Make the repo accept community layout submissions.

Acceptance:
- `CONTRIBUTING.md`, PR template, issue template committed.
- A PR workflow builds any submitted `.klc` or xkb symbols file and posts
  the resulting DLL as a check artefact.
- At least one external layout added via the PR workflow (can be synthetic
  in the same commit that adds the workflow).

---

## Out of scope

- **Compose-key multi-step sequences** (e.g. Compose + o + e → œ). Windows
  kbd DLLs only support single-level dead keys. Would need a background
  helper, which defeats the native-layout goal.
- **Per-application layouts.** Apps must opt in via TSF. Not a driver-level
  concern.
- **IME-class layouts** (Japanese, Korean, Chinese). Those are TSF/IME text
  services, not kbd DLLs.
