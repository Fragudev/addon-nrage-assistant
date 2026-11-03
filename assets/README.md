# Artwork

Source images. They are **not** shipped in the addon zip (only `NrageAssistant/` is).

| File | What | Used for |
|---|---|---|
| `nrage_logo.png` | Nrage guild logo, black angular face on a solid bright red blob, transparent background, 361x394 | source of `NrageAssistant/Media/nrage_logo.tga`: window header, minimap button, AddOns list icon |
| `alliance_logo.png` | Alliance lion, dark blue on transparent, 732x909 | not used by the addon yet |

## Regenerating the game texture

WoW does not load PNG. It loads TGA or BLP with power-of-two sides. `tools/make_tga.swift` (macOS, needs the Swift
toolchain) centres an image on a transparent square canvas and writes a 32-bit uncompressed TGA with straight alpha:

```bash
swift tools/make_tga.swift assets/nrage_logo.png NrageAssistant/Media/nrage_logo.tga 128 0.04
```

The last two arguments are the canvas size in pixels (a power of two) and the margin as a fraction of it.
The logo carries its own coloured background, so it reads on both light and dark surfaces.
