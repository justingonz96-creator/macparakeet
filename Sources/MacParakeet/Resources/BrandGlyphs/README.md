# Brand glyphs

Monochrome platform marks used by the Transcribe-URL hero (`MediaPlatformOrbitView`)
and Library source badges. Each is a single-path vector PDF rendered as a **template
image** (`isTemplate = true`), so the app tints it — dimmed when idle, brand-colored
when a matching URL is recognized. See `BrandGlyphImage.swift`.

## Provenance

Geometry is from [Simple Icons](https://simpleicons.org) (icon set licensed
**CC0 1.0**, public domain). SVGs were converted to single-color vector PDF with
`rsvg-convert -f pdf`.

The brand names and logos themselves are **trademarks of their respective owners**.
They are used here only nominatively — to indicate which third-party services a
pasted link can be transcribed from — not to imply affiliation or endorsement.
