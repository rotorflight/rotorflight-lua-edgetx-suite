# Helicopter wizard artwork

Editable sources of the illustrations the helicopter setup wizard will show on its cards. The
radio images are in `src/rfsuite/app/pages/helicopter_setup/gfx/`; the package build copies
them as they are and needs nothing from this directory.

## What is here

- `svg/light/` and `svg/dark/` -- 56 illustrations in the Configurator's light and dark theme,
  each a standalone SVG in a transparent 220 by 160 frame. `catalog.json` names the
  Configurator component and the properties each one was drawn from (servo index, axis,
  front/rear variant, rate preset, pulse width).
- `heli/` -- the side view of the helicopter used for the three board-orientation cards
  (blades removed, level, tail lifted 20 degrees): one master image, the three common layers
  derived from it, the annotation patches with their masks, and the three accepted
  full-resolution results. `geometry.json` holds the masks and the transformation,
  `checks.json` the checksums and measured angles.
- `upstream/` -- the Configurator files the SVGs are drawn from, byte for byte: 15 Svelte
  components, the swash layout and rate presets, the theme stylesheet and the licence.
  `provenance.json` records each one's original path and SHA-256 at
  [Configurator PR 491](https://github.com/rotorflight/rotorflight-configurator/pull/491),
  commit `4a57ba971d7ffef06f39bb66b3f376d150a27e25` (GPL-3.0, as this repository).
  The Configurator's `HeliSide.svelte` is not used; `heli/` replaces it.
- `exports.json` -- what the last export wrote: every file with its checksum, the renderer
  versions and the font.

## Exporting the images

```sh
npm ci --ignore-scripts --prefix artwork/helicopter_setup
node bin/wizard/export_artwork.mjs           # writes svg/ and the radio PNGs
node bin/wizard/export_artwork.mjs --check   # fails if any checked-in file differs
```

The exporter compiles the Svelte snapshots with their own logic and styles, instantiates every
entry of `catalog.json` in both themes, fits it into the 220 by 160 frame and writes the SVG and
its PNG (resvg, Arial). The two switch images freeze the Configurator's animation at its end
positions. The degree sign in the rate-curve unit is corrected in the exported SVGs; the source
carries a malformed character. The three `gfx/heli-*.png` are the accepted images under
`heli/accepted/`, scaled to 220 by 110 and placed 25 pixels from the top of the frame.
`--check` also fails when a file under `upstream/` no longer matches `provenance.json`.

Node.js is needed only to export; the package build never runs it.

Text drawn next to an image stays with the application, so it is translated; the numbers and
units inside an image are language-neutral.

## Checking or changing the helicopter images

```sh
python -m pip install -r artwork/helicopter_setup/requirements.txt
python bin/wizard/build_helicopter_artwork.py           # checks the layers and accepted images
python bin/wizard/build_helicopter_artwork.py --write   # after a deliberate edit
```

The check rebuilds the three layers from `heli/master.png` and fails if a layer or an accepted
image differs from it. After `--write`, review the images and update the checksums in
`heli/checks.json`, then run the export.
