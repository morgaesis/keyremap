# Shared variant definitions. Sourced by generate.ps1, build.ps1, install.ps1.
#
# A variant is a post-kbdutool transformation that produces an alternate DLL
# with different non-character-key behavior. The character/dead-key tables
# are identical across all variants — only the VSC→VK map changes.

$script:Variants = [ordered]@{
    'default' = @{
        DllName = 'kbdisdv.dll'
        BaseName = 'kbdisdv'
        DisplayName = 'Icelandic Dvorak'
        Patches = @()
    }
    'caps-altgr' = @{
        DllName = 'kbdisdv-caps-altgr.dll'
        BaseName = 'kbdisdv-caps-altgr'
        DisplayName = 'Icelandic Dvorak (Caps=AltGr)'
        # Patch the ausVK[] entry for scan code 0x3A (CapsLock) to deliver
        # VK_RMENU | KBDEXT instead of VK_CAPITAL. With KLLF_ALTGR set in
        # fLocaleFlags (which kbdutool generates for us), the kernel treats
        # RMENU as Ctrl+Alt — giving a second AltGr in the Caps position
        # without a background program or scancode-map registry hack.
        Patches = @(
            @{
                File = '$BaseName.c'
                # Unique context around the T3A token in ausVK[]: between
                # T39 (space scan code ID) and T3B (F1).
                Find = '(?m)(T39, )T3A(, T3B)'
                Replace = '$1(VK_RMENU | KBDEXT)$2'
            }
        )
    }
    'caps-esc' = @{
        DllName = 'kbdisdv-caps-esc.dll'
        BaseName = 'kbdisdv-caps-esc'
        DisplayName = 'Icelandic Dvorak (Caps=Esc)'
        Patches = @(
            @{
                File = '$BaseName.c'
                Find = '(?m)(T39, )T3A(, T3B)'
                Replace = '$1VK_ESCAPE$2'
            }
        )
    }
    'caps-ctrl' = @{
        DllName = 'kbdisdv-caps-ctrl.dll'
        BaseName = 'kbdisdv-caps-ctrl'
        DisplayName = 'Icelandic Dvorak (Caps=Ctrl)'
        Patches = @(
            @{
                File = '$BaseName.c'
                # Plain VK_LCONTROL (no KBDEXT — Caps is not an extended key).
                # Windows treats any VK_CONTROL/VK_LCONTROL/VK_RCONTROL press
                # as the Ctrl modifier; for Caps-as-Ctrl, LCONTROL is most
                # idiomatic (emacs/vi users expect Caps to feel like LCtrl).
                Find = '(?m)(T39, )T3A(, T3B)'
                Replace = '$1VK_LCONTROL$2'
            }
        )
    }
}

function Get-VariantNames { return @($script:Variants.Keys) }

function Get-VariantSpec {
    param([Parameter(Mandatory)][string]$Name)
    if (-not $script:Variants.Contains($Name)) {
        throw "Unknown variant '$Name'. Known: $(($script:Variants.Keys) -join ', ')"
    }
    return $script:Variants[$Name]
}
