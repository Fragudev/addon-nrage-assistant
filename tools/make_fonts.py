#!/usr/bin/env python3
"""Builds the font files of the NRAGE style (docs/NRAGE_STYLE_PLAN.md section 3).

WoW has no letter spacing and its upper-casing only knows ASCII, so both are baked into the font files:
  * capitals: the cmap entry of each lowercase letter (including a e i o u u n with accents) points at the capital glyph;
  * tracking: tracking * unitsPerEm is added to every advance width in hmtx;
  * Cinzel ships as a variable font, so static instances are cut with fontTools.varLib.instancer;
  * the name table is rewritten, so the modified copies carry their own names.
The run fails when a generated font lacks one of the glyphs the addon needs.

The sources are SIL OFL fonts (no Reserved Font Name) downloaded from google/fonts into tools/.font-src, which git
ignores. Needs fontTools (pip install fonttools), in a virtualenv.

Usage: tools/make_fonts.py [source-directory] [output-directory]
       (defaults tools/.font-src and NrageAssistant/Media/Fonts)
"""

import os
import shutil
import sys

from fontTools.ttLib import TTFont
from fontTools.varLib import instancer

CINZEL = "Cinzel[wght].ttf"

# Output file -> (source, wght of the instance or None, capitals, tracking in em, family, style, weight class).
FONTS = [
    ("NrageDisplay-Bold.ttf", CINZEL, 700, True, 0.0, "Nrage Display", "Bold", 700),
    ("NrageDisplay-Black.ttf", CINZEL, 900, True, 0.0, "Nrage Display Black", "Regular", 900),
    ("BarlowCondensed-Medium.ttf", "BarlowCondensed-Medium.ttf", None, False, 0.0, None, None, None),
    ("BarlowCondensed-SemiBold.ttf", "BarlowCondensed-SemiBold.ttf", None, False, 0.0, None, None, None),
    ("BarlowCondensed-Bold.ttf", "BarlowCondensed-Bold.ttf", None, False, 0.0, None, None, None),
    ("NrageLabel-SemiBold.ttf", "BarlowCondensed-SemiBold.ttf", None, True, 0.30, "Nrage Label", "SemiBold", 600),
    ("NrageButton-Bold.ttf", "BarlowCondensed-Bold.ttf", None, True, 0.16, "Nrage Button", "Bold", 700),
]

# Lowercase letters whose capital is the cmap target. Accented letters beyond the Latin-1 ones are not used.
LOWER = "abcdefghijklmnopqrstuvwxyzáéíóúüñ"
REQUIRED = (
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
    "áéíóúüñÁÉÍÓÚÜÑ"
    "¿¡·…–—"
)


def make_capitals(font):
    """Points every lowercase cmap entry at the capital glyph. Returns the number of entries changed."""
    changed = 0
    for table in font["cmap"].tables:
        if not table.isUnicode():
            continue
        for lower in LOWER:
            upper = lower.upper()
            if ord(lower) in table.cmap and ord(upper) in table.cmap:
                table.cmap[ord(lower)] = table.cmap[ord(upper)]
                changed += 1
    return changed


def add_tracking(font, tracking):
    """Adds tracking * unitsPerEm to every advance width."""
    extra = round(tracking * font["head"].unitsPerEm)
    hmtx = font["hmtx"]
    for glyph, (advance, lsb) in list(hmtx.metrics.items()):
        hmtx.metrics[glyph] = (advance + extra, lsb)
    font["hhea"].advanceWidthMax += extra
    # Metrics tables that cache the old advances would disagree with hmtx.
    for stale in ("hdmx", "LTSH", "VDMX"):
        if stale in font:
            del font[stale]
    return extra


def rename(font, family, style, weight):
    """Rewrites the name table so the copy does not pass for the upstream font."""
    full = family if style == "Regular" else f"{family} {style}"
    postscript = full.replace(" ", "-") if style == "Regular" else f"{family.replace(' ', '')}-{style}"
    names = font["name"]
    # Typographic family and style, and the variable font's own names, go away: ids 1 and 2 say it all.
    for name_id in (16, 17, 21, 22, 25):
        names.removeNames(nameID=name_id)
    for name_id, value in ((1, family), (2, style), (3, f"{postscript};nrage-assistant"), (4, full), (6, postscript)):
        names.removeNames(nameID=name_id)
        names.setName(value, name_id, 3, 1, 0x409)
        names.setName(value, name_id, 1, 0, 0)
    os2 = font["OS/2"]
    os2.usWeightClass = weight
    bold = style == "Bold"
    # fsSelection bit 0 italic, bit 5 bold, bit 6 regular.
    os2.fsSelection = (os2.fsSelection & ~0b1100001) | (0b0100000 if bold else 0b1000000)
    font["head"].macStyle = 1 if bold else 0


def instance(source, weight):
    font = TTFont(source)
    font = instancer.instantiateVariableFont(font, {"wght": weight})
    for table in ("STAT", "MVAR", "avar", "fvar", "gvar", "HVAR"):
        if table in font:
            del font[table]
    return font


def check_glyphs(font):
    cmap = font.getBestCmap()
    return [ch for ch in REQUIRED if ord(ch) not in cmap]


def build(source_dir, out_dir):
    os.makedirs(out_dir, exist_ok=True)
    failed = False
    for out_name, src, wght, capitals, tracking, family, style, weight in FONTS:
        path = os.path.join(source_dir, src)
        if not os.path.exists(path):
            sys.exit(f"missing source font: {path}")
        if wght is not None:
            font = instance(path, wght)
        else:
            font = TTFont(path)
        if capitals:
            make_capitals(font)
        if tracking:
            add_tracking(font, tracking)
        if family:
            rename(font, family, style, weight)
        missing = check_glyphs(font)
        if missing:
            failed = True
            print(f"FAIL {out_name}: missing glyphs {' '.join(missing)}")
            continue
        target = os.path.join(out_dir, out_name)
        if wght is None and not capitals and not tracking:
            shutil.copyfile(path, target)  # published as is
        else:
            font.save(target)
        print(f"wrote {out_name} ({os.path.getsize(target)} bytes), required glyphs present")
    if failed:
        sys.exit("some fonts lack required glyphs; see above")


def main():
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    source_dir = sys.argv[1] if len(sys.argv) > 1 else os.path.join(root, "tools", ".font-src")
    out_dir = sys.argv[2] if len(sys.argv) > 2 else os.path.join(root, "NrageAssistant", "Media", "Fonts")
    build(source_dir, out_dir)


if __name__ == "__main__":
    main()
