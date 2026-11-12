---
title: What a page is built with
sidebar_label: Page context
---

# What a page is built with

`ui/home.lua` builds the page on screen with `pageModule.build(ctx)`. Besides the layout
(`children`, `x`, `y`, `w`, `h`) and the shared state (`i18n`, `preferences`, `menu`, `manifest`),
this build context carries the calls a page needs to act on the tool around it. `wakeup` gets a
smaller table with the shared state and `requestRebuild` only, so a page that needs one of the
other calls later keeps it from its build:

`build` appends the page's widgets to `children` as tables; `lvgl.build` makes them afterwards. In
the tool opened from the dashboard that happens on the pass after the page's first build of a
visit (see [Dashboard views](dashboard-views.md)), so a page's `wakeup` can run once before its
widgets exist, and a page reaches its widgets only through the functions it binds to them.

| Field | What it does |
| --- | --- |
| `requestRebuild()` | Builds the scene again on the next pass. |
| `requestClose()` | Leaves the page as the last step of the back key does, without the back key's unsaved-changes prompt and without the page's `onBack`. |
| `askUnsavedChanges(answers)` | Asks the unsaved-changes question for a page about to drop an edit of its own accord. |
| `openHelp(message, title, subtitle)` | Opens the help dialog. |
| `openPage(menuId)` | Leaves this page and opens another one by its menu id. |

## `openPage`

For a page that sends the pilot on to the page where a setting lives, for example a wizard
step that points to the ELRS Link page. The call only parks the target; the next pass of
`run()` takes it, as it takes a tile press:

1. The menu goes up to its root. The page on screen is released by the next build like any page
   that is left, so its `onClose` runs and can switch its tests off or roll back a live change.
2. The target is opened through the root entry that leads to it and then through each menu
   below it, however deep: the same path the pilot would take, so the conditions on every
   entry on the way (`visibleWhen`, `enabledWhen`, `minApiVersion`, the armed lock) are the
   menu's. The tool's landing page, which a host opens it on, takes the same route.
3. A page the menu would not offer at that moment is not opened, and the menu stays at its root.
4. While the unsaved-changes prompt or the save overlay is on screen, or a save action is
   pending, the request is dropped: leaving then would answer the prompt for the wrong page.

Back on the opened page returns to its own menu, not to the page that opened it. A page with
unsaved edits should settle them before it calls `openPage`, because leaving releases it.

```lua
-- In a page's build: a button that sends the pilot to the ELRS Link page.
{ type = "button", text = "@i18n(...)@", press = function() ctx.openPage("diagnostics_elrs_link_page") end }
```
