# Helicopter wizard artwork

The illustrations for the helicopter setup wizard's cards. The cards that show the helicopter
from the side draw the three `heli-*.png` pictures (`diagrams.lua`): blades crossed out on the
cards where they must come off, the tail lifted 20 degrees on the board-alignment card, and the
level helicopter elsewhere. The other illustrations are prepared for the cards that will show
them; those cards still draw their own sketches, and the live feedback (the attitude view, the
bench tests) is unchanged.

- Radio images: `src/rfsuite/app/pages/helicopter_setup/gfx/` -- `light/` and `dark/` hold 56
  illustrations each, and the three `heli-*.png` are the side views. Every image is a
  transparent 220 by 160 PNG; a card's image object is given a frame of that aspect, and EdgeTX
  zooms the picture to fit it on every screen size.
- Sources: `artwork/helicopter_setup/` -- the SVGs, the helicopter master and its layers, and
  the Configurator PR 491 snapshot they are drawn from. Its `README.md` describes the export
  (`node bin/wizard/export_artwork.mjs`, `--check` to verify) and the helicopter layer check
  (`python bin/wizard/build_helicopter_artwork.py`). Neither is needed to build the package.

`bin/wizard/verify.lua` checks on every screen size that each picture a card names exists in
the package and that its frame keeps the 220 by 160 aspect.

The rate-curve and pulse-train images are fixed examples (the Trainer, Sport and 3D presets;
50/1520, 333/1520 and 560/760 microseconds). They are pictures for explanation, not a display
of the flight controller's live settings.
