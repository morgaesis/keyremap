#!/usr/bin/env python3
"""xkb2klc.py

Convert an xkb symbols file + variant into a Microsoft Keyboard Layout Creator
.klc file suitable for kbdutool.exe. Stdlib-only.

Supported xkb subset:
  - `xkb_symbols "<variant>" { ... }` blocks
  - `include "<file>(<variant>)"` recursion with override-last merge
  - `key <CODE> { [ sym1, sym2, sym3, sym4 ] };` up to 4 levels
  - `type[group1]="..."` annotations (ignored; we take positions 1..4)
  - Explicit Unicode keysyms via `U<hex>` or `0x01NNNNNN`
  - NoSymbol / VoidSymbol pass-through (means "do not override")
  - level3(ralt_switch) recognised as the only supported level3 mechanism

Dead keys: for each dead_* that appears in the active layout, we emit a
compose subtable extracted from /usr/share/X11/locale/en_US.UTF-8/Compose
(or a path passed via --compose). Only two-stroke `<dead_X> <single> : "out"`
sequences are considered, which is the KLC dead-key model.
"""

from __future__ import annotations

import argparse
import os
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Tuple

# -------------- keysym -> Unicode codepoint table --------------

# All 32-bit codepoints: the xkb/X convention is
#   0x01000000 | U         = Unicode U   (U+0000..U+10FFFF)
#   small values (<= 0xFF) = directly Latin-1 codepoint
#   0xFE50..0xFE7F         = dead keys   (kept as-is so we can detect them)
# The big table of named keysyms lives in /usr/include/X11/keysymdef.h; we
# parse it and extract whichever entries have "U+NNNN" in the comment
# (all Unicode-mappable keysyms do). A few dozen legacy names map to U+00xx
# via the raw hex value itself.

KEYSYMDEF_PATHS = [
    "/usr/include/X11/keysymdef.h",
]

# dead_* keysym value -> the "spacing" character we represent it with on Windows
# (this mirrors the hand-written kbdisdv.klc conventions).
DEAD_SPACING: Dict[int, int] = {
    0xFE50: 0x0060,  # dead_grave        -> `
    0xFE51: 0x00B4,  # dead_acute        -> ´
    0xFE52: 0x005E,  # dead_circumflex   -> ^
    0xFE53: 0x007E,  # dead_tilde        -> ~
    0xFE54: 0x00AF,  # dead_macron       -> ¯
    0xFE55: 0x02D8,  # dead_breve        -> ˘
    0xFE56: 0x02D9,  # dead_abovedot     -> ˙
    0xFE57: 0x00A8,  # dead_diaeresis    -> ¨
    0xFE58: 0x02DA,  # dead_abovering    -> ˚
    0xFE59: 0x02DD,  # dead_doubleacute  -> ˝
    0xFE5A: 0x02C7,  # dead_caron        -> ˇ
    0xFE5B: 0x00B8,  # dead_cedilla      -> ¸
    0xFE5C: 0x02DB,  # dead_ogonek       -> ˛
}

DEAD_NAME_PRETTY: Dict[int, str] = {
    0x0060: "GRAVE ACCENT",
    0x00B4: "ACUTE ACCENT",
    0x005E: "CIRCUMFLEX ACCENT",
    0x007E: "TILDE",
    0x00AF: "MACRON",
    0x02D8: "BREVE",
    0x02D9: "DOT ABOVE",
    0x00A8: "DIAERESIS",
    0x02DA: "RING ABOVE",
    0x02DD: "DOUBLE ACUTE ACCENT",
    0x02C7: "CARON",
    0x00B8: "CEDILLA",
    0x02DB: "OGONEK",
}


def load_keysym_table(paths: Iterable[str]) -> Tuple[Dict[str, int], Dict[int, int]]:
    """Parse keysymdef.h. Returns (name->keysym_value, keysym_value->unicode_cp).

    The unicode-cp mapping is derived from the `U+NNNN` annotation in comments.
    Many legacy keysyms (endash=0x0aaa, emdash=0x0aa9, ...) have numeric values
    that differ from their Unicode codepoint; the comment is the source of truth.
    """
    names: Dict[str, int] = {}
    cps: Dict[int, int] = {}
    rx = re.compile(
        r"#define\s+XK_(\w+)\s+0x([0-9a-fA-F]+)\s*(?:/\*\s*U\+([0-9a-fA-F]+))?"
    )
    for p in paths:
        if not os.path.exists(p):
            continue
        with open(p, "r", encoding="utf-8", errors="replace") as fh:
            for line in fh:
                m = rx.match(line)
                if m:
                    name, val = m.group(1), int(m.group(2), 16)
                    names.setdefault(name, val)
                    if m.group(3):
                        cps.setdefault(val, int(m.group(3), 16))
    return names, cps


def keysym_to_codepoint(val: int, cps: Optional[Dict[int, int]] = None) -> Optional[int]:
    """Map an xkb keysym numeric value to a Unicode codepoint.

    Returns None for NoSymbol/VoidSymbol/unmappable function keys.
    Dead keys are returned as the negative of their spacing codepoint
    so callers can recognise them and emit `@` in KLC.
    """
    if val == 0 or val == 0xFFFFFF:  # NoSymbol / VoidSymbol
        return None
    if val in DEAD_SPACING:
        return -DEAD_SPACING[val]
    if 0xFE00 <= val <= 0xFEFF:
        # other dead / ISO modifier keysyms: unsupported
        return None
    if 0xFF00 <= val <= 0xFFFF:
        # function keys (Return, BackSpace, ...)
        return None
    if val & 0xFF000000 == 0x01000000:
        cp = val & 0x00FFFFFF
        return cp if cp <= 0x10FFFF else None
    if cps is not None and val in cps:
        return cps[val]
    if val <= 0xFF:
        return val  # Latin-1 direct
    return None


# -------------- xkb parser --------------

# A parsed symbols file. Maps variant name -> Variant.
@dataclass
class Variant:
    name_group1: Optional[str] = None
    # keycode label ("AE04", "TLDE", ...) -> list of 4 values.
    # Each value is int keysym number, or None for NoSymbol (do not override).
    keys: Dict[str, List[Optional[int]]] = field(default_factory=dict)

    def merge(self, other: "Variant") -> None:
        if other.name_group1:
            self.name_group1 = other.name_group1
        for k, vals in other.keys.items():
            existing = self.keys.get(k, [None, None, None, None])
            merged = list(existing)
            for i, v in enumerate(vals):
                if i >= 4:
                    break
                if v is not None:  # None means NoSymbol -> keep existing
                    merged[i] = v
            while len(merged) < 4:
                merged.append(None)
            self.keys[k] = merged[:4]


class XkbSymbolsLoader:
    def __init__(self, symbols_dir: Path, keysyms: Dict[str, int]):
        self.symbols_dir = symbols_dir
        self.keysyms = keysyms
        self._file_cache: Dict[str, Dict[str, Variant]] = {}

    def load_file(self, name: str) -> Dict[str, Variant]:
        if name in self._file_cache:
            return self._file_cache[name]
        path = self.symbols_dir / name
        if not path.exists():
            raise FileNotFoundError(f"xkb symbols file not found: {path}")
        text = path.read_text(encoding="utf-8", errors="replace")
        text = self._strip_comments(text)
        variants = self._parse_variants(text)
        self._file_cache[name] = variants
        return variants

    def resolve(self, file: str, variant: str) -> Variant:
        variants = self.load_file(file)
        if variant not in variants:
            raise KeyError(f"{file}({variant}) not found. Available: {list(variants)}")
        # Build variant: walk its body in order, applying includes before key defs.
        raw = variants[variant]
        # raw.keys may contain "__includes__" sentinel? No; we stored includes
        # as a side channel. We'll instead re-parse with include awareness.
        return self._build_variant(file, variant)

    # --- parsing internals ---
    _RX_COMMENT_LINE = re.compile(r"//[^\n]*")
    _RX_COMMENT_BLOCK = re.compile(r"/\*.*?\*/", re.DOTALL)

    def _strip_comments(self, text: str) -> str:
        text = self._RX_COMMENT_BLOCK.sub("", text)
        text = self._RX_COMMENT_LINE.sub("", text)
        return text

    _RX_VARIANT_HEAD = re.compile(r"xkb_symbols\s+\"([^\"]+)\"\s*\{")
    _RX_INCLUDE = re.compile(r'include\s+"([^"]+)"')
    _RX_KEY = re.compile(
        r"key\s+<([A-Za-z0-9_]+)>\s*\{\s*(?:type\[[^\]]+\]\s*=\s*\"[^\"]*\"\s*,\s*)?"
        r"\[\s*([^\]]*?)\s*\]"
        r"(?:\s*,\s*type\[[^\]]+\]\s*=\s*\"[^\"]*\"\s*)?\s*\}\s*;",
        re.DOTALL,
    )
    _RX_NAME = re.compile(r'name\[Group1\]\s*=\s*"([^"]*)"')

    def _parse_variants(self, text: str) -> Dict[str, Variant]:
        out: Dict[str, Variant] = {}
        for m in self._RX_VARIANT_HEAD.finditer(text):
            out[m.group(1)] = Variant()
        return out

    @staticmethod
    def _extract_braced(text: str, open_pos: int) -> Tuple[str, int]:
        """Starting at `{` position open_pos, return (body_between_braces, end_pos_exclusive)."""
        assert text[open_pos] == "{"
        depth = 0
        i = open_pos
        while i < len(text):
            c = text[i]
            if c == "{":
                depth += 1
            elif c == "}":
                depth -= 1
                if depth == 0:
                    return text[open_pos + 1 : i], i + 1
            i += 1
        raise ValueError("unbalanced braces")

    def _find_variant_body(self, file: str, variant: str) -> str:
        path = self.symbols_dir / file
        text = self._strip_comments(path.read_text(encoding="utf-8", errors="replace"))
        for m in self._RX_VARIANT_HEAD.finditer(text):
            if m.group(1) == variant:
                body, _ = self._extract_braced(text, m.end() - 1)
                return body
        raise KeyError(f"{file}({variant}) body not found")

    def _build_variant(self, file: str, variant: str) -> Variant:
        body = self._find_variant_body(file, variant)
        result = Variant()
        # walk tokens in order: include "x(y)"  OR  key <FOO> { ... } ;  OR  name[...]
        # Use a combined pattern that yields events.
        pos = 0
        combined = re.compile(
            r'(include\s+"[^"]+")'
            r'|(key\s+<[A-Za-z0-9_]+>\s*\{[^}]*\}\s*;)'
            r'|(name\[Group1\]\s*=\s*"[^"]*")',
            re.DOTALL,
        )
        for m in combined.finditer(body):
            if m.group(1):
                inc = self._RX_INCLUDE.match(m.group(1)).group(1)
                sub = self._include(inc)
                result.merge(sub)
            elif m.group(2):
                self._apply_key_def(result, m.group(2))
            elif m.group(3):
                nm = self._RX_NAME.match(m.group(3))
                if nm:
                    result.name_group1 = nm.group(1)
        return result

    def _include(self, spec: str) -> Variant:
        # spec like "latin(type4)" or "us(dvorak)" or "eurosign(4)"
        m = re.match(r"([A-Za-z0-9_]+)(?:\(([^)]+)\))?", spec.strip())
        if not m:
            raise ValueError(f"bad include spec: {spec}")
        inc_file = m.group(1)
        inc_variant = m.group(2)
        if inc_variant is None:
            # pick default variant
            vs = self.load_file(inc_file)
            if "basic" in vs:
                inc_variant = "basic"
            else:
                inc_variant = next(iter(vs))
        # special-case level3(ralt_switch): no printable keys, skip silently
        if inc_file == "level3":
            return Variant()
        # nbsp, kpdl, keypad, compose, srvr_ctrl — these affect keys we don't port
        # to KLC's 48-key "alphanumeric" table; skip them.
        if inc_file in ("nbsp", "kpdl", "keypad", "compose", "srvrkeys"):
            return Variant()
        return self._build_variant(inc_file, inc_variant)

    def _apply_key_def(self, target: Variant, snippet: str) -> None:
        m = self._RX_KEY.search(snippet)
        if not m:
            return
        code = m.group(1)
        items = [s.strip() for s in m.group(2).split(",")]
        vals: List[Optional[int]] = []
        for item in items:
            vals.append(self._resolve_keysym(item))
        while len(vals) < 4:
            vals.append(None)
        target.keys[code] = vals[:4]

    _RX_HEX_U = re.compile(r"^U([0-9A-Fa-f]+)$")
    _RX_HEX_0X = re.compile(r"^0x([0-9A-Fa-f]+)$")

    def _resolve_keysym(self, name: str) -> Optional[int]:
        name = name.strip()
        if not name or name in ("NoSymbol", "VoidSymbol"):
            return None
        m = self._RX_HEX_U.match(name)
        if m:
            return 0x01000000 | int(m.group(1), 16)
        m = self._RX_HEX_0X.match(name)
        if m:
            return int(m.group(1), 16)
        v = self.keysyms.get(name)
        if v is not None:
            return v
        # unknown -> None (warn)
        sys.stderr.write(f"warning: unknown keysym '{name}', treating as NoSymbol\n")
        return None


# -------------- Compose file --------------

COMPOSE_PATHS = ["/usr/share/X11/locale/en_US.UTF-8/Compose"]


def load_compose_deadkeys(paths: Iterable[str], keysyms: Dict[str, int], cps: Dict[int, int]) -> Dict[int, Dict[int, int]]:
    """Return dict of dead_keysym_spacing_cp -> { input_cp -> output_cp }."""
    result: Dict[int, Dict[int, int]] = {}
    # reverse lookup: keysym name -> numeric, for tokens inside the Compose file
    for p in paths:
        if not os.path.exists(p):
            continue
        with open(p, "r", encoding="utf-8", errors="replace") as fh:
            for line in fh:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                # only two-token sequences: <dead_X> <Y> : "O" ...
                m = re.match(r"<([A-Za-z_0-9]+)>\s*<([A-Za-z_0-9]+)>\s*:\s*\"((?:[^\"\\]|\\.)*)\"", line)
                if not m:
                    continue
                a, b, out = m.group(1), m.group(2), m.group(3)
                if not a.startswith("dead_"):
                    continue
                a_val = keysyms.get(a)
                if a_val is None or a_val not in DEAD_SPACING:
                    continue
                dead_sp = DEAD_SPACING[a_val]
                b_val = keysyms.get(b)
                b_cp: Optional[int] = None
                if b_val is not None:
                    mapped = keysym_to_codepoint(b_val, cps)
                    if mapped is None or mapped < 0:
                        continue
                    b_cp = mapped
                else:
                    continue
                # decode C-escapes in out string
                try:
                    decoded = bytes(out, "utf-8").decode("unicode_escape")
                    # But strings containing non-ascii are already utf-8 raw; re-decode properly:
                    decoded = out.encode("latin-1", errors="replace").decode("unicode_escape", errors="replace")
                except Exception:
                    decoded = out
                # Simpler: handle known escapes \" \\ and take first codepoint of remainder
                s = out.replace("\\\"", "\"").replace("\\\\", "\\")
                if not s:
                    continue
                out_cp = ord(s[0])
                result.setdefault(dead_sp, {})[b_cp] = out_cp
    return result


# -------------- keycode -> Windows scan-code --------------

# Canonical US PC/AT mapping for the 48 xkb "alphanumeric" positions.
# SC is the Windows make-code (lower byte of the kbd scancode).
XKB_TO_SCAN: Dict[str, Tuple[str, str]] = {
    # (SC, default VK)
    "TLDE": ("29", "OEM_3"),
    "AE01": ("02", "1"),
    "AE02": ("03", "2"),
    "AE03": ("04", "3"),
    "AE04": ("05", "4"),
    "AE05": ("06", "5"),
    "AE06": ("07", "6"),
    "AE07": ("08", "7"),
    "AE08": ("09", "8"),
    "AE09": ("0a", "9"),
    "AE10": ("0b", "0"),
    "AE11": ("0c", "OEM_MINUS"),
    "AE12": ("0d", "OEM_PLUS"),
    "AD01": ("10", "Q"),
    "AD02": ("11", "W"),
    "AD03": ("12", "E"),
    "AD04": ("13", "R"),
    "AD05": ("14", "T"),
    "AD06": ("15", "Y"),
    "AD07": ("16", "U"),
    "AD08": ("17", "I"),
    "AD09": ("18", "O"),
    "AD10": ("19", "P"),
    "AD11": ("1a", "OEM_4"),
    "AD12": ("1b", "OEM_6"),
    "AC01": ("1e", "A"),
    "AC02": ("1f", "S"),
    "AC03": ("20", "D"),
    "AC04": ("21", "F"),
    "AC05": ("22", "G"),
    "AC06": ("23", "H"),
    "AC07": ("24", "J"),
    "AC08": ("25", "K"),
    "AC09": ("26", "L"),
    "AC10": ("27", "OEM_1"),
    "AC11": ("28", "OEM_7"),
    "BKSL": ("2b", "OEM_5"),
    "LSGT": ("56", "OEM_102"),
    "AB01": ("2c", "Z"),
    "AB02": ("2d", "X"),
    "AB03": ("2e", "C"),
    "AB04": ("2f", "V"),
    "AB05": ("30", "B"),
    "AB06": ("31", "N"),
    "AB07": ("32", "M"),
    "AB08": ("33", "OEM_COMMA"),
    "AB09": ("34", "OEM_PERIOD"),
    "AB10": ("35", "OEM_2"),
    "SPCE": ("39", "SPACE"),
}

# Which VKs are treated as caps-sensitive letters (cap=1 in KLC)?
CAP_LETTER_VKS = {
    "A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M",
    "N", "O", "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z",
}


# -------------- layout metadata --------------

# layout_id -> (kbd name, locale id (hex), locale name, description, langname)
LAYOUT_META = {
    "is": ("kbdis",   "0000040f", "is-IS", "Icelandic",         "íslenska (Ísland)"),
    "us": ("kbdus2",  "00000409", "en-US", "United States",      "English (United States)"),
    "se": ("kbdse",   "0000041d", "sv-SE", "Swedish",            "svenska (Sverige)"),
    "de": ("kbdgr",   "00000407", "de-DE", "German",             "Deutsch (Deutschland)"),
    "dk": ("kbdda",   "00000406", "da-DK", "Danish",             "dansk (Danmark)"),
    "no": ("kbdno",   "00000414", "nb-NO", "Norwegian",          "norsk bokmål (Norge)"),
    "fi": ("kbdfi",   "0000040b", "fi-FI", "Finnish",            "suomi (Suomi)"),
    "es": ("kbdsp",   "0000040a", "es-ES", "Spanish",            "español (España)"),
    "fr": ("kbdfr",   "0000040c", "fr-FR", "French",             "français (France)"),
}


# -------------- KLC emission --------------

def fmt_cell(val: Optional[int]) -> str:
    if val is None:
        return "-1"
    if val < 0:
        return f"{(-val):04x}@"
    # letters and digits: emit literally (KLC accepts both)
    if 0x61 <= val <= 0x7A or 0x41 <= val <= 0x5A or 0x30 <= val <= 0x39:
        return chr(val)
    return f"{val:04x}"


def is_latin_letter(cp: Optional[int]) -> bool:
    if cp is None or cp < 0:
        return False
    return 0x61 <= cp <= 0x7A or 0x41 <= cp <= 0x5A


def emit_klc(
    layout: str,
    variant_name: str,
    var: Variant,
    compose: Dict[int, Dict[int, int]],
    out: List[str],
    cps: Optional[Dict[int, int]] = None,
) -> None:
    meta = LAYOUT_META.get(layout, (f"kbd{layout}", "00000000", f"{layout}", layout, layout))
    kbd_name, locale_id, locale_name, desc, langname = meta
    kbd_name = f"{kbd_name}{variant_name[:2]}"[:8] if variant_name != "basic" else kbd_name
    desc_full = var.name_group1 or f"{desc} ({variant_name})"

    # Map keys to Windows
    rows: List[str] = []
    used_deads: List[int] = []

    # iterate in scancode order
    scan_order = sorted(XKB_TO_SCAN.keys(), key=lambda k: int(XKB_TO_SCAN[k][0], 16))
    for xcode in scan_order:
        if xcode not in var.keys:
            continue
        sc, default_vk = XKB_TO_SCAN[xcode]
        vals = var.keys[xcode]
        resolved = [None if v is None else keysym_to_codepoint(v, cps) for v in vals]
        if all(c is None for c in resolved):
            continue
        vk = default_vk
        cap = "1" if is_latin_letter(resolved[0]) else "0"
        c0 = fmt_cell(resolved[0])
        c1 = fmt_cell(resolved[1]) if len(resolved) > 1 else "-1"
        c2 = "-1"
        c6 = fmt_cell(resolved[2]) if len(resolved) > 2 else "-1"
        c7 = fmt_cell(resolved[3]) if len(resolved) > 3 else "-1"
        for c in resolved:
            if c is not None and c < 0:
                if -c not in used_deads:
                    used_deads.append(-c)
        # Use \t\t after short VK names (<=3 chars) to keep column alignment,
        # and \t after longer names. Matches the hand-written kbdisdv.klc layout.
        vk_sep = "\t\t" if len(vk) <= 5 else "\t"
        rows.append(f"{sc}\t{vk}{vk_sep}{cap}\t{c0}\t\t{c1}\t\t{c2}\t\t{c6}\t\t{c7}")

    # Space row (always present)
    rows.append("39\tSPACE\t\t0\t0020\t\t0020\t\t-1\t\t0020\t\t0020")

    # --- write the KLC ---
    out.append(f'KBD\t{kbd_name}\t"{desc_full}"\n')
    out.append(f'COPYRIGHT\t"(c) 2026 morgaesis"\n')
    out.append(f'COMPANY\t"morgaesis"\n')
    out.append(f'LOCALENAME\t"{locale_name}"\n')
    out.append(f'LOCALEID\t"{locale_id}"\n')
    out.append("VERSION\t1.0\n\n")
    out.append(f"; Generated by xkb2klc.py from xkb {layout}({variant_name}).\n\n")
    out.append("SHIFTSTATE\n\n")
    out.append("0\t;Column 4 :              normal\n")
    out.append("1\t;Column 5 :              Shft\n")
    out.append("2\t;Column 6 :        Ctl\n")
    out.append("6\t;Column 7 :        Ctl Alt          (AltGr)\n")
    out.append("7\t;Column 8 :        Ctl Alt Shft     (Shift+AltGr)\n\n")
    out.append("LAYOUT\t\t;an extra '@' at the end is a dead key\n\n")
    out.append(";SC\tVK_\t\tCap\t0\t\t1\t\t2\t\t6\t\t7\n")
    out.append(";--\t----\t\t----\t----\t\t----\t\t----\t\t----\t\t----\n\n")
    for r in rows:
        out.append(r + "\n")
    out.append("\n")

    # Deadkey tables
    for dead_cp in used_deads:
        table = compose.get(dead_cp, {})
        out.append(f"DEADKEY {dead_cp:04x}\n\n")
        for inp, outp in sorted(table.items()):
            out.append(f"{inp:04x}\t{outp:04x}\n")
        # space -> literal spacing
        out.append(f"0020\t{dead_cp:04x}\n")
        out.append("\n")

    # KEYNAME blocks (standard Windows set)
    out.append(KEYNAME_BLOCK)
    # KEYNAME_DEAD
    if used_deads:
        out.append("KEYNAME_DEAD\n\n")
        for d in used_deads:
            pretty = DEAD_NAME_PRETTY.get(d, f"DEAD {d:04X}")
            if " " in pretty:
                out.append(f'{d:04x}\t"{pretty}"\n')
            else:
                out.append(f"{d:04x}\t{pretty}\n")
        out.append("\n")

    lid_short = locale_id[-4:]
    out.append("DESCRIPTIONS\n\n")
    out.append(f"{lid_short}\t{desc_full}\n\n")
    out.append("LANGUAGENAMES\n\n")
    out.append(f"{lid_short}\t{langname}\n\n")
    out.append("ENDKBD\n")


KEYNAME_BLOCK = """KEYNAME

01\tEsc
0e\tBackspace
0f\tTab
1c\tEnter
1d\tCtrl
2a\tShift
36\t"Right Shift"
37\t"Num *"
38\tAlt
39\tSpace
3a\t"Caps Lock"
3b\tF1
3c\tF2
3d\tF3
3e\tF4
3f\tF5
40\tF6
41\tF7
42\tF8
43\tF9
44\tF10
45\tPause
46\t"Scroll Lock"
47\t"Num 7"
48\t"Num 8"
49\t"Num 9"
4a\t"Num -"
4b\t"Num 4"
4c\t"Num 5"
4d\t"Num 6"
4e\t"Num +"
4f\t"Num 1"
50\t"Num 2"
51\t"Num 3"
52\t"Num 0"
53\t"Num Del"
54\t"Sys Req"
57\tF11
58\tF12
7c\tF13
7d\tF14
7e\tF15
7f\tF16
80\tF17
81\tF18
82\tF19
83\tF20
84\tF21
85\tF22
86\tF23
87\tF24

KEYNAME_EXT

1c\t"Num Enter"
1d\t"Right Ctrl"
35\t"Num /"
37\t"Prnt Scrn"
38\t"Right Alt"
45\t"Num Lock"
46\tBreak
47\tHome
48\tUp
49\t"Page Up"
4b\tLeft
4d\tRight
4f\tEnd
50\tDown
51\t"Page Down"
52\tInsert
53\tDelete
54\t<00>
56\tHelp
5b\t"Left Windows"
5c\t"Right Windows"
5d\tApplication

"""


# -------------- main --------------

def main() -> int:
    p = argparse.ArgumentParser(description="xkb -> Microsoft KLC converter")
    p.add_argument("--symbols-dir", required=True, type=Path)
    p.add_argument("--layout", required=True, help="xkb symbols file (e.g. 'is')")
    p.add_argument("--variant", required=True, help="variant (e.g. 'dvorak')")
    p.add_argument("--output", required=True, type=Path)
    p.add_argument("--compose", default=None,
                   help="Path to X11 Compose file (default: /usr/share/X11/locale/en_US.UTF-8/Compose)")
    p.add_argument("--keysymdef", default=None,
                   help="Path to keysymdef.h (default: /usr/include/X11/keysymdef.h)")
    args = p.parse_args()

    keysymdef_paths = [args.keysymdef] if args.keysymdef else KEYSYMDEF_PATHS
    keysyms, keysym_cps = load_keysym_table(keysymdef_paths)
    if not keysyms:
        sys.stderr.write("error: no keysyms loaded (is keysymdef.h available?)\n")
        return 2

    compose_paths = [args.compose] if args.compose else COMPOSE_PATHS
    compose = load_compose_deadkeys(compose_paths, keysyms, keysym_cps)

    loader = XkbSymbolsLoader(args.symbols_dir, keysyms)
    var = loader.resolve(args.layout, args.variant)

    out_lines: List[str] = []
    emit_klc(args.layout, args.variant, var, compose, out_lines, cps=keysym_cps)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    # KLC files are UTF-16 LE with BOM on Windows, but kbdutool on MSYS accepts
    # UTF-8 too; the reference src/kbdisdv.klc is UTF-8 in this repo, so match.
    args.output.write_text("".join(out_lines), encoding="utf-8")
    sys.stderr.write(f"wrote {args.output}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
