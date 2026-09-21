# Omasum brand assets

Original artwork for Omasum. `../preview.png` is a copy of the 1200×630 banner, which the plugin marketplace uses for the listing card; `screenshot.png` is the running app on Ristretto.

| File | Use |
| --- | --- |
| `omasum-mark.svg` | The mark, outline variant. Default for anything 48px and up. |
| `omasum-mark-solid.svg` | Solid variant. Use below 48px, where the border starts eating the glyph. |
| `omasum-mark-mono.svg` | Single-colour version using `currentColor`. For docs, READMEs, anywhere it must inherit the text colour. |
| `omasum-icon-512.png`, `omasum-icon-128.png` | Outline mark, rasterised, transparent background. |
| `omasum-icon-solid-512/64/32/16.png` | Solid mark, rasterised. The 32 and 16 are the favicon sizes. |
| `omasum-banner-1200x630.png` | Listing and social card. 1200×630 is the standard OpenGraph size. |
| `omasum-banner-2400x1260.png` | The same at 2×, for retina displays. |

## Colours

Tokyo Night, Omarchy's shipped default, is what these are drawn in.

| Role | Hex |
| --- | --- |
| Background | `#1a1b26` |
| Surface | `#1f2335` |
| Border | `#3b4261` |
| Text | `#c0caf5` |
| Muted | `#7a88b8` |
| Accent (units, keywords, window border) | `#7aa2f7` |
| Accent 2 (your variable names) | `#bb9af7` |
| Ok (assignments) | `#9ece6a` |

The running app does not use these values. It reads the active Omarchy theme, so it looks different under gruvbox or catppuccin-latte. These fixed hexes are for the static assets only, which have no theme to read.

## Type

JetBrains Mono for anything monospace, IBM Plex Sans for the rest. Both are open licensed: JetBrains Mono under the SIL Open Font License, IBM Plex under the SIL Open Font License. The banner PNGs have the type already rendered, so nothing needs installing to use them.

## The Omarchy mark

Not included, and not something to redraw. If you want it beside the Omasum mark on a listing page, use the official asset from the Omarchy project under whatever terms they publish it, with clearspace of at least half its height, and never merged into a single glyph with this one.

## Regenerating

The banner is an artboard on the Omasum overlay design canvas (`Listing.dc.html`). The PNGs here were rendered from it at 1× and 2×. Edit the artboard, re-render, replace the files.
