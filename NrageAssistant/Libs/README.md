# Vendored libraries

Copied from their upstream repositories. Update by re-copying a newer tag and changing this table. The only changes are listed under *Patches*.

| Library | Source | Version |
|---|---|---|
| LibStub, CallbackHandler-1.0, AceComm-3.0 (with ChatThrottleLib) | https://github.com/WoWUIDev/Ace3 | Release-r1403 (`d295b12`) |
| LibSerialize | https://github.com/rossnichols/LibSerialize | v1.2.2 (`40d96aa`) |
| LibDeflate | https://github.com/SafeteeWoW/LibDeflate | 1.0.2-release (`6831edc`) |
| HereBeDragons-2.0, HereBeDragons-Pins-2.0 | https://github.com/Nevcairiel/HereBeDragons | 2.18-release (`90a7b2d`) |

Licenses: `Ace3-LICENSE.txt`, `LibSerialize/LICENSE`, `LibDeflate/LICENSE.txt`, `HereBeDragons/LICENSE.txt` (upstream ships no license file; the note records what its TOC declares: BSD).

HereBeDragons is copied unmodified (only the two files the addon needs; the 7.x migration data is left out) and keeps its shared LibStub names, so the highest minor wins when another addon embeds its own copy. Scanned for divisions that could hit the Forever `Division by zero` behaviour (see below): none has a literal zero or `1 / x` operand; the divisors are map sizes that the code checks, fixed tables, and the minimap radius from `C_Minimap.GetViewRadius()`, which upstream does not check (see `docs/API_NOTES.md`).

## Patches

**LibSerialize** (`LibSerialize/LibSerialize.lua`) is patched in two places, both marked `NRAGE PATCH` or noted in the code:

1. The library name is `NrageAssistant-LibSerialize` instead of `LibSerialize`. LibStub hands out one instance per name, and other addons (DBM ships its own copy) load first, so the addon would otherwise use somebody else's copy.
2. Negative zero is detected with `("%g"):format(num)` instead of `1 / num < 0`. On the Forever client a division by zero raises `Division by zero`, so *every* message failed to encode, because every message carries a `0` (the protocol minor version).

When re-copying a newer upstream version, reapply both and keep the spec that scans the file for `1 / num`.
