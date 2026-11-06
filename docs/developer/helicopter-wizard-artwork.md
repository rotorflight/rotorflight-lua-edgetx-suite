# Helicopter wizard artwork

The illustrations for the helicopter setup wizard's cards. The cards that show the helicopter
from the side draw the three `heli-*.png` pictures (`diagrams.lua`): blades crossed out on the
cards where they must come off, the tail lifted 20 degrees on the board-alignment card, and the
level helicopter elsewhere. The other illustrations are prepared for the cards that will show
them; those cards still draw their own sketches, and the live feedback (the attitude view, the
bench tests) is unchanged.

- Radio images: `src/rfsuite/app/pages/helicopter_setup/gfx/` -- `dark/` and `light/` hold the
  illustrations for each colour scheme, and the three `heli-*.png` are the side views, one set for
  both; these are transparent 220 by 160 PNGs. `small/` holds the dark illustrations and the side
  views at 154 by 112, `small_light/` the light illustrations.
  A card's image object is given a frame of that aspect, and EdgeTX zooms the picture to fit it.
  A frame no larger than 154 by 112 (the 480 pixel wide screens and smaller) draws the small
  set, at its own size on the 480 pixel wide screens; a larger frame draws the 220 by 160 set.
  EdgeTX decodes and caches a picture at the size of its file, so the small set needs about half
  the memory per picture.
- Sources: `artwork/helicopter_setup/` -- the SVGs, the helicopter master and its layers, and
  the Configurator PR 491 snapshot they are drawn from. Its `README.md` describes the export
  (`node bin/wizard/export_artwork.mjs`, `--check` to verify) and the helicopter layer check
  (`python bin/wizard/build_helicopter_artwork.py`). Neither is needed to build the package.

`bin/wizard/verify.lua` checks on every screen size that each picture a card names exists in
the package, that its frame keeps the 220 by 160 aspect, and that a small picture is drawn
exactly when the frame is no larger than 154 by 112.

The two rescue pictures (`rescue-flip`, `rescue-up`) come from rotorflight-lua-ethos-suite commit
`69b6060e`, `src/rfsuite/app/gfx/setup_wizard/`, GPL-3.0, at their 220 by 160 size and scaled down
for `small/`; they have no SVG source here, so they have no light set, and both schemes draw them
from `dark/` and `small/`.

The rate-curve and pulse-train images are fixed examples (the Trainer, Sport and 3D presets;
50/1520, 333/1520 and 560/760 microseconds). They are pictures for explanation, not a display
of the flight controller's live settings.
