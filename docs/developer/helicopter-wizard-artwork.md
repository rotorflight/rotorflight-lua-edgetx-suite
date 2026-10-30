# Helicopter wizard artwork

The illustrations for the helicopter setup wizard's cards. The cards that show the helicopter
from the side draw the three `heli-*.png` pictures (`diagrams.lua`): blades crossed out on the
cards where they must come off, the tail lifted 20 degrees on the board-alignment card, and the
level helicopter elsewhere. The other illustrations are prepared for the cards that will show
them; those cards still draw their own sketches, and the live feedback (the attitude view, the
bench tests) is unchanged.

- Radio images: `src/rfsuite/app/pages/helicopter_setup/gfx/` -- `dark/` holds the 56
  illustrations, and the three `heli-*.png` are the side views; these are transparent
  220 by 160 PNGs. The light theme is kept as SVG sources only. `small/` holds the same dark illustrations and side views at 154 by 112.
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

The rate-curve and pulse-train images are fixed examples (the Trainer, Sport and 3D presets;
50/1520, 333/1520 and 560/760 microseconds). They are pictures for explanation, not a display
of the flight controller's live settings.
