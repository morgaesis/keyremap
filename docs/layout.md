# Icelandic Dvorak — full layout reference

Windows port of xkb `is(dvorak)`. Base = `us(dvorak)` + `eurosign(4)` +
7 is(dvorak) overrides + `level3(ralt_switch)`.

## Key table

Shift states: **P** = plain, **S** = Shift, **A** = AltGr (Ctrl+Alt), **SA** =
Shift+AltGr. A trailing `@` indicates a dead key.

| Scan | QWERTY label | P | S | A | SA |
|---|---|---|---|---|---|
| 29 | `` ` `` | `` ` `` | `~` | dead_grave | dead_tilde |
| 02 | 1 | 1 | ! | | |
| 03 | 2 | 2 | @ | | |
| 04 | 3 | 3 | # | | |
| 05 | 4 | 4 | $ | **€** | **€** |
| 06 | 5 | 5 | % | | |
| 07 | 6 | 6 | ^ | dead_circumflex | dead_circumflex |
| 08 | 7 | 7 | & | | |
| 09 | 8 | 8 | \* | | |
| 0a | 9 | 9 | ( | dead_grave | dead_breve |
| 0b | 0 | 0 | ) | | |
| 0c | - | \[ | { | | |
| 0d | = | ] | } | dead_tilde | |
| 10 | Q | ' | " | dead_acute | dead_diaeresis |
| 11 | W | , | < | dead_cedilla | dead_caron |
| 12 | E | . | > | dead_abovedot | · |
| 13 | R | p | P | | |
| 14 | T | y | Y | | |
| 15 | Y | f | F | | |
| 16 | U | g | G | | |
| 17 | I | c | C | | |
| 18 | O | r | R | | |
| 19 | P | l | L | | |
| 1a | \[ | / | ? | **„** | **"** |
| 1b | ] | = | + | | |
| 1e | A | a | A | | |
| 1f | S | o | O | **ö** | **Ö** |
| 20 | D | e | E | | |
| 21 | F | u | U | | |
| 22 | G | i | I | | |
| 23 | H | d | D | **ð** | **Ð** |
| 24 | J | h | H | | |
| 25 | K | t | T | | |
| 26 | L | n | N | | |
| 27 | ; | s | S | **æ** | **Æ** |
| 28 | ' | - | \_ | **–** | **—** |
| 2b | \\ | \\ | \| | | |
| 2c | Z | ; | : | dead_ogonek | dead_doubleacute |
| 2d | X | q | Q | | |
| 2e | C | j | J | | |
| 2f | V | k | K | | |
| 30 | B | x | X | | |
| 31 | N | b | B | **ß** | **ẞ** |
| 32 | M | m | M | | |
| 33 | , | w | W | | |
| 34 | . | v | V | | |
| 35 | / | z | Z | **þ** | **Þ** |
| 39 | space | (space) | (space) | (space) | (space) |

Rows in **bold** are the seven positions overridden by `is(dvorak)` on top of
`us(dvorak)`, plus the EuroSign injection from `eurosign(4)`.

## Dead keys

All eleven dead keys inherited from `us(dvorak)` are preserved with
comprehensive compose tables covering Icelandic, Western European, Nordic,
Central European, and Turkish characters.

| Dead key | Glyph | Typical use | Invocation |
|---|---|---|---|
| acute | ´ | á é í ó ú ý ć ń ś ź | AltGr+`Q`-position |
| diaeresis | ¨ | ä ë ï ö ü ÿ | Shift+AltGr+`Q`-position |
| grave | ` | à è ì ò ù | AltGr+`` ` `` or AltGr+9 |
| tilde | ~ | ã ñ õ | Shift+AltGr+`` ` `` or AltGr+= |
| circumflex | ^ | â ê î ô û | AltGr+6 |
| cedilla | ¸ | ç ş ţ | AltGr+`W`-position |
| caron | ˇ | č ď ě ň ř š ť ž | Shift+AltGr+`W`-position |
| above-dot | ˙ | ċ ė ġ ż İ (Turkish) | AltGr+`E`-position |
| breve | ˘ | ă ğ | Shift+AltGr+9 |
| ogonek | ˛ | ą ę į ų | AltGr+`Z`-position |
| double-acute | ˝ | ő ű | Shift+AltGr+`Z`-position |

Producing á: AltGr+`Q`-position (which in Dvorak is the `'` key), then `a`.
Producing Ý: AltGr+`Q`-position, then Shift+y.
Producing a literal acute: AltGr+`Q`-position, then Space.

## Divergences from Linux `is(dvorak)`

- **Scancode vs keysym mapping.** Windows addresses keys by PS/2 scan code;
  xkb uses evdev/xfree86 keycodes. The mapping is standard, but there is one
  case to be aware of: xkb's `<LSGT>` (the extra ISO key between Shift and Z
  on European keyboards) is not in this layout because US 101/104 keyboards
  lack it.
- **Compose key.** Linux's `Compose` key (which enables multi-keystroke
  sequences like Compose + o + e = œ) is not available via a kbd DLL; Windows
  kbd DLLs only support single-level dead keys. The specific `is(dvorak)` file
  does not define Compose, so there is no loss for this layout specifically.
- **AltGr implementation.** Windows treats RAlt as Ctrl+Alt. The DLL sets the
  `KLLF_ALTGR` flag so RAlt behaves as a pure AltGr rather than generating
  spurious Ctrl+Alt+key shortcuts. LAlt remains a plain Alt.
