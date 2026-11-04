# NRAGE style plan

This plan applies the guild's web style (`guia-de-estilo-nrage.md`, "the guide") to the addon. It is written so that an implementing agent can pick it up with no other context. **Status: approved by the owner on 2026-11-04. Implement phase by phase, following section 6.**

- **Visual reference:** the Design canvas at https://claude.ai/artifact/U4aUo3uAXjK3jL4zpTi2eR, restyled on 2026-11-04. It uses web fonts and CSS for the cut corners and the glow, so it shows the target, not the exact rendering in the client. When the mockup and this text disagree, this text wins.
- **What changes:** the look of the kit (`NrageAssistant/UI/Kit`): palette, fonts, cut corners, glow, gradients, bars.
- **What does not change:** layout, navigation, tabs, view-model logic, sync, data. This is a reskin of the kit from `docs/REDESIGN_PLAN.md`, not a new redesign.
- **Supersedes:** sections 1.1 to 1.3 of `docs/REDESIGN_PLAN.md` (ember palette, Alliance blue, Fira Sans). Everything else in that plan stands.
- **Out of scope:** Guild Assistant (`../addon-guild-assistant`). The style is Nrage branding. The structural work (`Kit.Shape`, glow) stays free of brand values, so it can be ported later if wanted.

---

## 1. Starting point (verified in code)

Why this is tractable: the kit was built on tokens, so most of the change lands in a few files.

| Fact | Where | Consequence |
|---|---|---|
| Every color and font comes from one table | `UI/Kit/Theme.lua` | Palette and fonts are a one-file change |
| Surfaces are a flat `SetColorTexture` plus a four-texture border | `Pixel.Border`, `Card`, `Button`, `Window` | Cut corners need a new primitive, used by about 8 widgets |
| The hover wash is a full rectangle over the widget | `obj.wash` in `Button`, `Dropdown`, `IconButton` | A wash would spill into the cut corners: hover must change the fill instead |
| 7 raw white washes bypass the tokens | `Controls.lua` 102, 171, 325, 663; `Shell.lua` 335, 587, 859 | White washes look grey on red-black: move them to tokens |
| `Theme.SetAccent` and `Theme.accents` have no caller outside tests | `tests/kit_helpers_spec.lua` | Can be removed |
| Three frames do not use `Window` | `LootPopup`, `LayerPopup` build their own frame; `MinimapButton` is separate | Each needs its own pass |
| No code uses gradients, blend modes, masks or texture slicing yet | whole `UI` | All of it is unmeasured on the Forever client (section 4) |
| `accent` also means "information" | `info` banner, `planned`, `other`, `automatic`, `row.mine` | Blue was neutral, red is not. See decision D1 |
| Primary buttons and destructive buttons would both be red | `BUTTON_FILL` in `Controls.lua` | See decision D2 |
| Text focus and text error borders would both be red | `Controls.lua:495` | Solved in section 5.3 |
| Five chat prefixes hardcode green `\|cff33ff99` | `Core/Init`, `Core/LayerProbe`, `Core/LockdownProbe`, `Core/PvPProbe`, `Commands/Slash` | Change to brand red |

### Corrections to the guide

Follow this plan where the guide's section 7 disagrees.

| Guide says | Reality | Do this |
|---|---|---|
| Font path `AddOns\NRAGE_Assistant\...` | The folder is `NrageAssistant` | Use `Theme.FONT_FILES` |
| Halo through `SetShadowOffset(0, 0)` | A shadow with no offset sits behind the glyphs, so little or nothing shows | Offset copies (section 5.5) |
| Bars with `SetGradient` from `#7A000B` to `#FF7A5A` | Section 2 of the guide has three stops; `SetGradient` takes two | Two textures (section 5.4) |
| `StatusBar` | The kit draws bars from plain textures | Keep the kit's `ProgressBar` |
| `BackdropTemplate` or a `MaskTexture` | The kit avoids backdrops on purpose; masks are unmeasured and not needed | `Kit.Shape` and pre-drawn hexagon art |
| Letter spacing by inserting thin spaces | Breaks `Util.Truncate`, width measuring and tests, and may draw missing glyphs | Bake it into the font (section 3.2) |
| Get `logo.png` from the web repo | `Media/nrage_logo.tga` is already the red logo, 128x128 RGBA | No work |

---

## 2. Decisions

| # | Decision | Outcome | Alternative |
|---|---|---|---|
| D1 | Color of neutral information (info banners, "planned", "automatic", your own name in lists). Red there reads as an error. | **Decided 2026-11-04:** new token `info` = sand `#FFD9A8` | Rejected: ice `#5CC8FF`, which the guide keeps for bosses and "Reserva" |
| D2 | How to tell destructive actions from primary ones | **Decided 2026-11-04:** primary always glows. `dangerSolid` is a dark `blood` fill with a `danger` border and text, and never glows | Rejected: a solid light red fill, which looks like a primary button |
| D3 | Capitals and letter spacing | **Decided 2026-11-04:** baked into font files (section 3.2) | Fallback only if P0 rows 13 or 14 fail: `Util.Upper` at runtime with no spacing |
| D4 | Accent setting | **Decided 2026-11-04:** removed, the brand color is fixed | Rejected: keeping it unused |
| D5 | Ambience (grain, vignette, corner glow) | **Decided 2026-11-04:** only the corner glow on the main window. The owner decides grain and vignette in P5, from screenshots | Rejected: all of it from the start, or none |

---

## 3. Assets

### 3.1 Fonts

Both families are SIL OFL and declare **no Reserved Font Name** (checked in `google/fonts`, `ofl/cinzel/OFL.txt` and `ofl/barlowcondensed/OFL.txt`), so modified copies are allowed. Give them new names anyway. Cinzel ships upstream as a **variable** font (`Cinzel[wght].ttf`, 400 to 900): do not ship it, generate static instances.

| File in `Media/Fonts` | Source | Change |
|---|---|---|
| `NrageDisplay-Bold.ttf` | Cinzel at wght 700 | capitals |
| `NrageDisplay-Black.ttf` | Cinzel at wght 900 | capitals |
| `BarlowCondensed-Medium.ttf` | as published | none |
| `BarlowCondensed-SemiBold.ttf` | as published | none |
| `BarlowCondensed-Bold.ttf` | as published | none |
| `NrageLabel-SemiBold.ttf` | Barlow Condensed SemiBold | capitals, tracking 0.30 em |
| `NrageButton-Bold.ttf` | Barlow Condensed Bold | capitals, tracking 0.16 em |

Remove the three `FiraSans-*.ttf` files. Replace `Media/Fonts/OFL.txt` with `OFL-Cinzel.txt` and `OFL-BarlowCondensed.txt`, and keep a note in each that the modified files derive from that family.

### 3.2 `tools/make_fonts.py` (new)

WoW has no letter spacing and its upper-casing only knows ASCII. A font solves both with no change to any string:

- **Capitals:** point the `cmap` entry of each lowercase letter at its capital glyph, including `á é í ó ú ü ñ`.
- **Tracking:** add `tracking * unitsPerEm` to every advance width in `hmtx`.
- **Static instances:** `fontTools.varLib.instancer` for Cinzel.
- **Names:** rewrite the `name` table.

Because the strings stay as they are, `GetStringWidth`, `Util.Truncate` and the tests that look widgets up by their text keep working. The tool also reports any of these missing from a font, and fails: `A-Z a-z 0-9 á é í ó ú ü ñ Á É Í Ó Ú Ü Ñ ¿ ¡ · … – —`.

The source fonts go in a folder ignored by git. The generated files are committed, as the icons are.

### 3.3 `tools/make_shapes.py` (new)

Reuse the analytic rasterizer of `tools/make_icons.py`. All art is white and tinted at runtime. Output goes to `Media/Shapes`, power-of-two TGA with alpha.

| File | Use |
|---|---|
| `cut4_fill`, `cut6_fill`, `cut8_fill` | one filled corner triangle-cut tile, drawn at 4x resolution |
| `cut4_edge`, `cut6_edge`, `cut8_edge` | the matching 1-unit diagonal line |
| `glow` | soft square halo for slicing, 64x64 |
| `corner_glow` | large soft radial for the window corner, 128x128 |

Add to `tools/make_icons.py`: `hex` (filled), `hex-outline`, `diamond`. Register them in `Icons.NAMES`. These replace masks entirely.

---

## 4. Phase P0: measure on the client

Nothing after P1 is safe until this passes. Add rows 13 to 20 to the table in `docs/API_NOTES.md`, following its format.

Add a temporary `Core/StyleProbe.lua`, following the existing probes, opened with `/nrage styleprobe`. It draws one test frame with every item below. The owner takes one screenshot at UI scale 1.0 and one at 0.71. Remove the probe in P5.

| # | Question | If it fails |
|---|---|---|
| 13 | Do the generated TTFs load, with accents, `ñ`, and capitals from lowercase input? | Fall back to D3's alternative |
| 14 | Do the tracked fonts measure correctly with `GetStringWidth`? | Same |
| 15 | `SetGradient(orientation, minColor, maxColor)` with `CreateColor`, the form since patch 10.0.0. Which end is `minColor` on `VERTICAL`? Does it work on `SetColorTexture(1, 1, 1, 1)`, or does it need a white file? | Try the old `r, g, b` form, then a flat color |
| 16 | `SetBlendMode("ADD")` on a tinted texture | Use `BLEND` with a lower alpha |
| 17 | `SetTexCoord` on a TGA, and do sliced corners line up without seams at both scales? | Change the art or snap sizes |
| 18 | Is the diagonal edge visually the same weight as the 1px straight edge? | Redraw the edge art |
| 19 | Text halo: compare offset copies at 0.25, 0.35 and 0.5 alpha, next to the guide's shadow | Keep the best, or plain text |
| 20 | Is Barlow Condensed readable at 12 and 13? | Raise `small` and `body` by 1 (they are one table) |

**Done when:** every row has a result in `API_NOTES.md`, and the owner has accepted the screenshots.

---

## 5. Target design

### 5.1 Color tokens

| Token | New value | Note |
|---|---|---|
| `bg` | `#030001` @ 0.96 | window ground |
| `panel` | `#0C0203` | gradient end for cards |
| `panelTop` *(new)* | `#140405` | gradient start for cards |
| `side` | `#0C0203` | header and sidebar |
| `control` | accent @ 0.06 | secondary button ground |
| `controlHover` *(new)* | accent @ 0.16 | |
| `input` | `#050102` | |
| `border` | accent @ 0.22 | every panel border |
| `borderStrong` *(new)* | accent @ 0.60 | highlighted surfaces, focus |
| `line` *(new)* | `#3A0A10` | dividers, field borders |
| `text` | `#F4EBE8` | |
| `dim` | `#A8918D` | |
| `muted` | `#A8918D` @ 0.85 | below this, small text drops under 4.5:1 on `panel` |
| `accent` | `#FF0019` | |
| `onAccent` | `#FFFFFF` | was dark, because blue was light |
| `info` *(new, D1)* | `#FFD9A8` | |
| `success` | `#6FE08A` | |
| `warning` | `#F0B85A` | the guide's "Pendiente" |
| `danger` | `#FF6A6A` | |
| `gold` | `#F0B85A` | |
| `silver`, `bronze` | unchanged | ranking only |
| `ice` *(new)* | `#5CC8FF` | "Reserva", bosses |
| `online` *(new)* | `#45E07A` | connected indicator |
| `blood` *(new)* | `#2A0006` | `dangerSolid` ground |
| `hover` | accent @ 0.08 | replaces white washes |
| `selected` | accent @ 0.12 | |
| `stripe` | unchanged | |

Gradient pairs live in a new `Theme.gradients`: `panel` (`panelTop` to `panel`), `primary` (`#FF2236` to `#C3000F`), `bar` (`#7A000B`, `#FF0019`, `#FF7A5A`).

**Token moves, `accent` to `info`:** `STATUS_TOKENS` `planned`, `other`, `automatic`; `Banner` kind `info`; `ViewModel.NEED_TOKENS.other`; `ViewModelGuild.lua:203`; `ViewModelHome.lua:230`; and `row.mine` in `Members`, `PvP` (3 sites), `Loot`, plus the "You" badge in `Layers`. Check each against `tests/view_model_spec.lua` (2294, 2746). The PvP tier `4-6` stays `accent`.

Do not add tokens for difficulties or `epic`: nothing shows them.

### 5.2 Typography

`Theme.FONT_FILES` gets the weights `medium`, `semibold`, `bold`, `label`, `button`, `display`, `displayBlack`. `regular` goes away. Callers use style names, so only `Theme.styles` changes.

| Style | Font | Size |
|---|---|---|
| `title` | `displayBlack` | 22 |
| `hero` | `displayBlack` | 18 |
| `window` | `display` | 15 |
| `value` | `bold` | 15 |
| `body` | `medium` | 13 |
| `small` | `medium` | 12 |
| `smallMedium` | `semibold` | 12 |
| `label` | `label` | 11 |
| `tiny` | `medium` | 11 |
| `nav` | `button` | 13 |
| `button` *(new)* | `button` | 13 |

Player names, item names and free text must never use `label`, `button` or a display font: capitals would change how they read. Check `Badge` and `Chip`: they get `label` only for fixed words, and `smallMedium` when they hold a name.

### 5.3 `Kit.Shape` (new file `UI/Kit/Shape.lua`, after `Pixel.lua` in the TOC)

The one primitive for a cut surface. Manual slices were chosen because `SetTexCoord` is the only client feature they need, and they run under the test fakes.

```lua
local shape = Kit.Shape.New(frame, {
  cut = "md",                     -- "sm" 4, "md" 6, "lg" 8 units
  corners = { tl = true, tr = true, bl = true, br = true },
})
shape:SetFill("panel")            -- token, or { gradient = "panel" }
shape.border:SetColor("border")   -- same signature as Pixel.Border
shape:SetGlow(nil)                -- nil | { color = "accent", alpha = 0.5 }
shape:Resize()
```

- **Fill, 7 textures:** two corners and a strip on top, the same on the bottom, one middle band. A gradient runs on the middle band; the top strip takes the start color and the bottom strip the end color. Over 4 to 8 units that clamp is not visible.
- **Border, 8 textures:** 4 straight edges snapped with `Pixel.Size`, 4 diagonals. A corner not listed in `corners` is drawn square.
- **Glow:** 8 sliced `glow` pieces, created only on the first `SetGlow`, drawn outside the frame with `ADD`, so a surface with no glow costs nothing.
- **Pooling:** widgets are pooled, so `apply` must set fill, border and glow every time.
- **Gradient call:** one wrapper, `Theme.Gradient(texture, orientation, from, to)`, behind `pcall`, falling back to the flat `from` color, as the kit does for other client calls.

| Widget | Cut | Fill | Border |
|---|---|---|---|
| `Window`, `LootPopup`, `LayerPopup` | `lg` | `bg` | `border` |
| `Card` | `md` | gradient `panel` | `border`; `opts.highlight` gives `borderStrong` and a glow; `opts.special` gives `gold` |
| `Modal`, `Popup`, `Menu` | `md` | gradient `panel` | `border` |
| `Button` primary | `md` | gradient `primary` | none, glow 0.45, hover 0.6 |
| `Button` secondary | `md` | `control`, hover `controlHover` | `border`; text `text`, never `accent` |
| `Button` danger | `md` | transparent | `danger` |
| `Button` dangerSolid (D2) | `md` | `blood` | `danger` |
| `Button` ghost | none | none | none; text `info`, because small text is never `accent` (section 7) |
| `EditBox`, `TextArea`, `Dropdown`, `DateField` | `sm` | `input` | `line`; focus `borderStrong`; error `danger` |
| `Badge`, `Chip`, `Banner` | `sm` | status @ 0.10 | none |
| `Segmented`, `TabStrip` | `sm` on the selected piece | `control` | |

Not cut: table rows, list rows, nav rows, dividers, scrollbars, switch and checkbox.

**Focus against error:** `EditBox` already shows an error through its message. Focus is `borderStrong` (dark red), error is `danger` (light red) plus the message, so the two never rely on the same color alone. Error wins when both apply.

**Window corners:** header and sidebar sit on top of the window fill, and would poke out of the cut. Header takes a `Shape` with `tl` and `tr`, sidebar one with `bl`. The resize grip stays inside the `br` cut: move it in 4 units.

**Hover:** remove `obj.wash` from `Button`, `IconButton` where cut, and `Dropdown`. `refresh()` calls `SetFill` with the hover color.

**Clipping:** `ScrollArea` clips its children, so a glow near the edge of the content is cut off. `contentSide` (30) and `blockGap` (20) leave room for a 10-unit glow. Keep glows at or under that.

### 5.4 `ProgressBar`

- Track `#140204`, border `#3A0610`.
- New `opts.xp`: fill is two textures, each half of the filled width, `#7A000B` to `#FF0019` and `#FF0019` to `#FF7A5A`, so the bright end follows the tip. Add a glow only if the height is 8 or more.
- `opts.xp` also draws 19 black 1-pixel ticks, placed in `layout`, snapped with `Pixel.Size`, and `opts.label`, `opts.valueText` on top, in style `label`.
- A bar with another `color` token stays flat, so "complete" in PvP stays green.
- Consumers: `Tabs/PvP.lua:394` uses `xp`. `LootPopup.lua:206` (height 2) stays a thin flat bar, with no ticks.

### 5.5 Glow text and details

- `Label` gets `opts.glow`: four extra FontStrings at offsets of 1 unit, in `accent` at the alpha chosen in P0 row 19, behind the text. They must follow `SetText`, and hide when `glow` is off, because the widget is pooled.
- Used only by `PageHeader` title and `hero` labels. Never in a list.
- `opts.highlightWords` is not needed: a keyword in red can use a `|cffff0019` code in the page title if the owner asks for it.
- `UserCard` avatar: `disc` becomes `hex`.
- `StatusChip`: circle ground becomes `hex`.
- `Switch` knob and checkbox stay square, which the guide accepts.
- Selected `NavRow`: red bar with a small glow, `selected` wash, label in `text`.
- Header logo: a `glow` behind it, at alpha 0.5.

### 5.6 Not built

Nothing in the addon would use these today. Add one only with a real screen for it: Discord featured button, "EN DIRECTO" chip, stamps ("VICTORIA"), countdown boxes, difficulty colors, comic illustration and embers.

---

## 6. Phases

One PR per phase, each merged before the next starts. Every phase passes what CI runs (`.github/workflows/ci.yml`): `luacheck NrageAssistant tests`, `busted --coverage`, StyLua, and `tools/check_coverage.sh`. Commits follow the repository's conventional style, with no AI attribution.

| Phase | Executor | Scope | Files | Done when |
|---|---|---|---|---|
| **P0a** tools | Sonnet | `make_fonts.py`, `make_shapes.py`, icons, `StyleProbe` | `tools/`, `Media/`, `Core/` | Assets generated, probe opens, fonts not yet used by the UI |
| **P0b** measure | Owner | Section 4 | `docs/API_NOTES.md` | All rows filled, screenshots accepted |
| **P1a** tokens | Haiku | Values in sections 5.1 and 5.2, chat prefixes, remove `SetAccent`, font files and licenses | `Theme.lua`, 5 prefix files, `kit_helpers_spec.lua`, `Media/Fonts` | Addon is red and black in-game, with flat corners |
| **P1b** semantics | Sonnet | The `accent` to `info` moves, raw washes to tokens, `Badge` and `Chip` font rule | `Controls`, `Shell`, `Data`, view models, tabs, specs | No literal `SetColorTexture(1, 1, 1` left in `UI/` |
| **P2** primitive | Sonnet | `Kit.Shape`, `Theme.Gradient`, fakes | `Shape.lua`, `Theme.lua`, TOC, `tests/support/fake_frames.lua`, new `kit_shape_spec.lua` | Unit tests pass; no widget uses it yet |
| **P3** surfaces | Sonnet | The table in 5.3, except windows | `Core.lua`, `Controls.lua`, `Text.lua`, `Shell.lua` (popups) | Cards, buttons, fields cut in-game, hover works |
| **P4** shell | Sonnet | `Window`, `LootPopup`, `LayerPopup`, sidebar, header, section 5.5, `ProgressBar` | `Shell.lua`, popups, `Text.lua`, `Tabs/PvP.lua` | Every window cut, no corner spill, bars with ticks |
| **P5** finish | Haiku | Corner glow (D5), grain and vignette only if the owner asks after seeing screenshots, remove `StyleProbe`, docs, tone pass | `Locales/esES.lua`, docs, `README.md` | See below |

### P2 test requirements

`fake_frames.lua` needs `SetTexCoord`, `SetBlendMode`, `SetGradient`, `SetDrawLayer`. New specs cover:

- texture count with and without glow;
- a corner left out is drawn square;
- `SetFill` with a token and with a gradient;
- `Theme.Gradient` falls back to flat when `SetGradient` is missing or raises;
- a pooled widget reused without glow shows no glow;
- `Label` glow copies follow `SetText`, and hide on reuse;
- `ProgressBar`: 19 ticks with `xp`, none without, nothing drawn at value 0.

### P5 details

- **Tone (Haiku):** rewrite page descriptions and empty states in `Locales/esES.lua` in the guide's voice: Spain Spanish, second person, short. Do not touch labels, errors or anything that names a rule or a number. The owner reviews the diff.
- **Docs:** add a pointer to this plan at the top of sections 1.1 to 1.3 of `docs/REDESIGN_PLAN.md`. Move the guide to `docs/NRAGE_STYLE_GUIDE.md`. Update `assets/README.md`, and `docs/USER_GUIDE.md` if it mentions colors.
- **Release:** the screenshots in `assets/curseforge` show the old look. The owner retakes them. Add release notes in `release-notes/`.

---

## 7. Risks

| Risk | Handling |
|---|---|
| Condensed type at 12 is hard to read | P0 row 20; sizes live in one table |
| Red text on near-black at small sizes | `accent` is for fills, bars and borders. Small text uses `text`, `dim` or `info` |
| Too much glow stops feeling special | Only primary buttons, highlighted cards, selected nav, page titles, logo. Never rows |
| Texture count on long pages | 15 per surface, 8 more with glow, pooled. Rows are not cut. Check the Members tab for a hitch when it opens in P3 |
| Cut corners break the layout of small widgets | `sm` for anything under 24 units high |
| Fork drift | `Kit.Shape` holds no brand values. Port later only if asked |
