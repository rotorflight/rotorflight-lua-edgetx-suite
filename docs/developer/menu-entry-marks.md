---
title: Marks on menu tiles
sidebar_label: Menu tile marks
---

# Marks on menu tiles

A tile on a menu page can carry a mark in its top-right corner. The menu draws the mark; the
page behind the entry decides when it applies, through a condition on its entry in
`app/manifest.lua`.

| Mark | Entry attribute | Drawn when |
| --- | --- | --- |
| Red badge with the armed glyph | `lockedWhileArmed = true` | the craft is armed (condition `modelArmed`); the tile is also disabled |
| Green disc with a check | `doneWhen = "<condition>"` | the named condition is true |

The armed badge wins when both apply, so a locked tile always says why it cannot be pressed.

## `doneWhen`

`doneWhen` takes the same forms as `visibleWhen`: the name of a condition, or a function
`function(conditions, entry)` that returns `true` for done. The condition is published with
`menu.setCondition(name, value)`; setting a changed value rebuilds the menu cards, so the mark
appears on the next draw. The menu never decides what "done" means and reads nothing else:
a page that wants the mark keeps its own record and publishes the condition, for example when
a flight controller connects and when the page records a completion.

```lua
{ id = "step_01", title = "@i18n(...)@", menuId = "...", doneWhen = "exampleStep01Done" }
```

The check is drawn as two line strokes rather than a glyph, because the radio fonts carry no
check-mark character.

## Related

- `app/menu_registry.lua` -- `isEntryLockedByArm`, `isEntryDone`, `makeCard`
- `ui/tiles.lua` -- `appendCornerBadge`, `appendDoneBadge`

A change to `app/manifest.lua` also owes `lua5.3 bin/dashboard/make_menu_list.lua`: the rotary quick menu reads the list it makes,
`widgets/dashboard/menu_list.lua`, and CI's `bin/dashboard/verify_menu_list.lua` goes red where it was forgotten.
