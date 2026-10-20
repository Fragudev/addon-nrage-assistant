# Vendored libraries

Copied from their upstream repositories. Update by re-copying a newer tag and changing this table. The only changes are listed under *Patches*.

| Library | Source | Version |
|---|---|---|
| LibStub, CallbackHandler-1.0, AceComm-3.0 (with ChatThrottleLib) | https://github.com/WoWUIDev/Ace3 | Release-r1403 (`d295b12`) |
| LibSerialize | https://github.com/rossnichols/LibSerialize | v1.2.2 (`40d96aa`) |
| LibDeflate | https://github.com/SafeteeWoW/LibDeflate | 1.0.2-release (`6831edc`) |

Licenses: `Ace3-LICENSE.txt`, `LibSerialize/LICENSE`, `LibDeflate/LICENSE.txt`.

## Patches

**LibSerialize** (`LibSerialize/LibSerialize.lua`) is patched in two places, both marked `NRAGE PATCH` or noted in the code:

1. The library name is `NrageAssistant-LibSerialize` instead of `LibSerialize`. LibStub hands out one instance per name, and other addons (DBM ships its own copy) load first, so the addon would otherwise use somebody else's copy.
2. Negative zero is detected with `("%g"):format(num)` instead of `1 / num < 0`. On the Forever client a division by zero raises `Division by zero`, so *every* message failed to encode, because every message carries a `0` (the protocol minor version).

When re-copying a newer upstream version, reapply both and keep the spec that scans the file for `1 / num`.
