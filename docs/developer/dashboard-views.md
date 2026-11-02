---
title: Dashboard fullscreen views
sidebar_label: Dashboard views
sidebar_position: 65
---

# Dashboard fullscreen views

What the dashboard widget shows when it is put full screen, and what happens after a button on
that screen is pressed. Both are decided in one module,
`src/rfsuite/widgets/dashboard/views.lua`: a list of views, a small stack of the ones that are
open, and one function that performs whatever follows a press.

With a theme that says nothing about fullscreen, full screen shows the battery prompt while it
is waiting for an answer and the [quick menu](../dashboard/quick-menu.md) otherwise, and every
button leaves full screen where it always has. A theme can instead take full screen itself
([dashboard themes](dashboard-themes.md#a-theme-that-takes-fullscreen)); it is then the base
layer described below, and the menu and the picker open over it.

## Where to find it

| File | What it holds |
| --- | --- |
| `widgets/dashboard/views.lua` | The view registry, the stack, the conditions, the actions and `navigate()`. |
| `widgets/dashboard/runtime.lua` | The fullscreen branch of `widget.refresh`, which asks `views.resolve()` which view to show, and `viewJobStep`, which builds it. |
| `widgets/dashboard/fullscreen_menu.lua` | The quick menu view. |
| `widgets/dashboard/battery_pick_menu.lua` | The battery picker view. It draws the quick menu's `battery_pick` record, whose options and close are what its presses run. |
| `widgets/dashboard/battery_profile_menu.lua` | The battery profile page. It draws the quick menu's `battery_profile` record, whose options are what its presses run, with the outcome of the last one in its foot line. |
| `widgets/dashboard/confirm_menu.lua` | The confirmation view. It draws the question an entry's `confirm` raises (see [Confirmations](#confirmations)); its two buttons run or discard the press held behind the question. |
| `widgets/dashboard/fullscreen_controls.lua` | The tool control, the menu glyph and the X the widget draws over a fullscreen theme that binds no control of its own; the info bar that carries them above a declarative theme at full screen; and the tool control alone on the connect splash at full screen. |
| `widgets/dashboard/tool_host.lua` | The suite's tool, run inside the widget while it is open — see [The tool](#the-tool). |

`views.lua` is loaded on the first fullscreen pass and never on a zone pass, so a dashboard
that is never put full screen does not pay for it. The exceptions are a call to
`rfsuite.batteryPick`, which loads it wherever it is made, and a free-form theme that registers
[zone views](#zone-views), whose conditions it asks on the zone pass. The in-flight tuning surface is not a view:
it takes full screen ahead of all of them while it is up, is decided before any of this runs,
and keeps its own close box.

## Views

A view is a registry entry and a module:

| Key | What it says |
| --- | --- |
| `id` | The view's name. It is the render key, and the job that builds the view is named after it: the widget's job log line reads `menu` and `battery_pick`, and the quick menu's job keeps its `menu` pass class in `bin/accounting/measure.lua`. |
| `module` | The file that draws it. The module has `build(children, widget)`, which appends the whole fullscreen tree, and may have `renderKey(widget)`; its result is appended to the id (`menu|<key>`), and the view is rebuilt whenever it changes. It may also have `back(widget)`, what a short press on RTN does while the view is on top (see [Keys](#keys)). |
| `openWhen` | Optional. The name of a condition that opens the view on its own — see below. |

The shipped registry, in this order:

| id | module | openWhen |
| --- | --- | --- |
| `battery_pick` | `widgets/dashboard/battery_pick_menu.lua` | `batteryPickPending` |
| `confirm` | `widgets/dashboard/confirm_menu.lua` | — |
| `battery_profile` | `widgets/dashboard/battery_profile_menu.lua` | — |
| `menu` | `widgets/dashboard/fullscreen_menu.lua` | — |

`confirm` has no `openWhen`: it only ever opens from `views.confirm`, which an entry's own
`confirm` reaches — see [Confirmations](#confirmations). `battery_profile` has none either: it
opens from the quick menu's BATTERY PROFILE row.

Each widget gets its own copy of the list, entries included. A view's module is loaded by the
job that first builds it and kept on that widget's entry; the state pass reads a view's own
`renderKey` only from a module that is already loaded, and never loads one. So the job that
loads and builds a view also records the key with the module's own part (`views.viewKey`), which
is the key the next state pass computes: a view is built once when it first opens, not a second
time because its key grew by the module's part.

### A theme's views

A free-form theme adds to this list with `views` in its `init.lua`
([dashboard themes](dashboard-themes.md#views-of-a-themes-own)). On the first fullscreen pass
after the theme on screen has changed, `views.register()` makes the registry anew:

- the core views, as above;
- an id the widget already has keeps its entry — its `module`, `openWhen`, and the `back` RTN
  runs — and gets the theme's module as its **look**: the job builds that instead;
- any other id is appended, in the theme's order.

A theme's module is read through the theme loader when the view is first built, and built as
`build(children, zone, state, ctx)`; its key is `renderKey(zone, state)`. Where it has
`sources(zone, state)`, the derived snapshot resolves that list after the theme's own sources while
the view is on top, and stops when it is not (`viewSnapshotSources` in `runtime.lua`). RTN on a
view of the theme's own is its `back(ctx)`, else `closeView`. A view that was on the stack and is not in the
new registry is taken off it, so no job is queued for a view no step can build. A theme module
that does not load, or whose `build` raises, is not asked for again, with one log line: a
replaced look falls back to the core module at once, and a view of the theme's own is closed and
from then on refused like an unknown id. A build that raised is not queued again on the next
pass.

## The stack and the base layer

Which view is on screen is a stack of view ids, held in one field, `widget._viewStack`. Each
entry is `{ id = <id>, auto = true | nil }`. The same table is the **session** of one visit to
full screen: what else belongs to the visit — the outcome of the work a theme ran through
`ctx.run` ([dashboard themes](dashboard-themes.md#the-theme-draws-the-widget-acts)), and what
each view's `openWhen` answered on the last pass ([below](#views-that-open-themselves)) — is
kept on it beside the views and goes with it. Once a visit has one, it stays a table while the
visit lasts, empty or not: closing the last view leaves an empty stack, not `nil`. `done` and
`exitFullscreen` start a new session — `done` carrying over only what the conditions last
answered — and so do the two clears below.

- The view on top of the stack is the one shown.
- Opening a view that is already on the stack returns to it — everything above it is closed —
  rather than opening it a second time.
- The stack holds at most **four** views. Opening a fifth is refused: nothing changes, nothing
  is rebuilt, and the refusal is logged once until the stack next changes.
- Opening a view the widget has no entry for is refused the same way, with a log line. A job
  for a view no module can build would otherwise be queued again on every pass.
- A pass that arrives without an event — full screen has been left, possibly by a long press
  on RTN that Lua never sees — drops the whole stack in one assignment. So does a reconnect.

The stack lies above a **base layer**, `widget._viewBase`. When the stack is empty the base
layer is what full screen shows. It is `"theme"` while the theme on screen has `fullscreen =
"theme"` in its `init.lua`, and `nil` otherwise. The runtime reads that key on the first
fullscreen pass after the theme has changed rather than when the theme loads, so a theme load
costs what it did. With a base layer and an empty stack, `views.resolve()` reports no view, and
the runtime builds the theme at the fullscreen size in a job of its own, `fs_theme`, keyed
`fs_theme|<the theme's render key>`. **With no base layer, an empty stack shows the quick
menu**, which is what full screen has always shown on entry.

Over a base layer, an action that changes the stack also drops a fullscreen build still queued
for the surface that was on top, so the old surface is not put up once more before the new one.

## Views that open themselves

A view with `openWhen` opens on its own when that condition **rises**. On every fullscreen pass
every view's `openWhen` is asked once, in registry order — the widget's views, then the
theme's in the order it lists them — and the answer is kept on the session for the next pass.
Then, in this order:

1. A view that its own condition opened (`auto = true`) and whose condition no longer holds is
   closed again. That is what keeps the battery prompt the way it was: it shows while it is
   pending, and three places end the pending state without closing anything — arming
   (`updateDerivedFlightState`), a pick (`batteryPickApplyStep`) and a reconnect.
2. A view whose condition has risen — false on the last pass, true on this one — is opened, or,
   where it is already on the stack, **brought to the top**: it is moved there, and the views
   that were above it stay open under it. Entering full screen with a condition already true is
   a rise, because a visit starts with nothing remembered. A condition that merely holds forces
   nothing. Where several rise on the same pass, each is brought up in turn, so the last of them
   in registry order ends on top: a theme's view rising together with the battery prompt lies
   above the picker, and the picker shows again when it is closed.
3. The top of the stack is shown; with the stack empty, the base layer, or with none the quick
   menu.

A view opened explicitly — by a button or by `rfsuite.batteryPick.open()` — carries no `auto`
mark, and opening a view explicitly that its condition had already opened takes the mark off.
Such a view stays open when its condition falls, until it is closed. An explicit open returns
to a view already on the stack and closes what lies above it; a rise moves it and closes
nothing.

**What a condition that holds does not do.** A view opened over one that its condition holds
open — the menu over a switch's view — stays on top and usable; the view under it is not raised
while the condition merely holds. A view closed while its condition still holds stays closed,
and so does a view of the theme's that the pilot has left with `done`: the new session `done`
starts carries over what the theme's views' conditions last answered, so none of them counts as
a rise until its condition has fallen and risen again. The widget's own views are not carried
over: the battery prompt, still waiting for an answer, rises again after `done` and comes back
— the menu's X pressed over the picker brings the prompt back, as closing the menu with a page
key does. Leaving full screen and a reconnect forget it all, so the next visit starts over.

**Whoever sets a condition that opens a view still clears it when the view is answered or
closed**, because that is what closes a view its condition opened. The battery prompt follows
it: its registry load raises `pending`, and a pick, the picker's close box,
`rfsuite.batteryPick.dismiss()`, arming and a reconnect all clear it. A pick clears it in two
steps — the press records the request, and `pending` falls when the runtime has applied it a
few passes later — so `batteryPickPending` is false as soon as a request is recorded.

The menu opened over the picker with a page key lies above it; the picker is not raised over it.
Closing the menu brings the prompt back.

## Conditions

`visibleWhen` on a quick menu entry and `openWhen` on a view name a condition from one list in
`views.lua`. A name that is not in the list is false: it hides the entry and never opens the
view, which is what an unresolvable condition does in `app/menu_registry.lua` as well.

An entry's `visibleWhen` is asked again when it is run: `fullscreen_menu.M.run` refuses an entry
whose condition does not hold now, and so does the answer to its question. A surface is built
again only when its key changes, so a menu built before the condition changed — open when the
model armed — still draws the row; the refused press does nothing, follows with no action, and
has the surface built again without it. The options and the `close` of an entry that names a
`view` are pressed in that view and are not asked: the battery picker keeps its own rules, and a
battery profile's press queues nothing while the model is armed.

| Condition | True while |
| --- | --- |
| `previewInflightTuning` | the in-flight tuning preview switch is on and the widget carries the overlay's state for this model |
| `batteryPickHasPacks` | the model is disarmed and the battery registry has a pack for it |
| `modelDisarmed` | the model is not armed (`state.armed`); MAIN MENU asks it |
| `connectionReadyDisarmed` | the connection is ready (`connectionReady`) and the model is not armed; ERASE BLACKBOX asks it, so a menu a key opens before the connection is ready offers no write |
| `batteryProfileOffered` | `connectionReadyDisarmed`, and the flight controller's battery configuration (`state.battery_config`) has a capacity above zero for at least one of the six profiles; the BATTERY PROFILE row asks it |
| `flightLogOffered` | the model is not armed, as for MAIN MENU; the *Flight Log* tile in the tool's own menu is locked while it is armed |
| `batteryPickPending` | the battery prompt is waiting for an answer (`state.batteryPick.pending`) and no pick has been recorded yet |

### What else a theme's view may open on

A view a theme registers may give `openWhen` in four forms (`views.opens()`):

| Form | True while |
| --- | --- |
| `"name"` | the named condition above holds |
| `{ switch = "SA", pos = "up" }` | the switch is in that position: `"up"`, `"mid"` or `"down"` |
| `{ switch = "L01" }` | the logical switch is on |
| `{ switch = { pref = "<key>", default = "SA" }, pos = "down" }` | the switch the theme's own settings name under `<key>` (`state.themeConfig`) is in that position; `default` where the settings name none |
| `function(state) ... end` | the theme's function returns anything but `nil` or `false` |

**A switch is named the way the radio's menus name it**, and the firmware looks the position up
by that name (`getSwitchIndex`): the switch followed by an arrow for up and down or a dash for
the middle, which the widget appends for `pos`, and a logical switch as `L` and two digits
(`L1` is read as `L01`). A setting that holds a **number** rather than a name is a switch
position as the radio's own switch picker stores it — the in-flight tuning interlock is kept that
way — and is read as it is, whatever `pos` says; `0` is no switch, the picker's "nothing chosen
yet", and the view then does not open on one. The position is looked up once, when the theme
is loaded and again when its settings are saved, and a pass reads one value (`getSwitchValue`).
A name the radio does not know never opens the view.

**A condition function** is called with the widget state and nothing else, on the passes where
its view can be shown — every fullscreen pass for a fullscreen view, the zone's 2 Hz tick for a
[zone view](#zone-views) — and under `pcall`: one that
raises counts as false and says so in one log line per theme and view, not on every pass. It
runs on every one of those passes, so it reads what the state already holds and computes as
little as a box's value function does. `bin/themes/validate.lua` calls it on its fixture state
of every phase and is red where it raises or costs more than **35 instructions** a call — what
asking the costliest of the widget's own conditions costs, counted the same way (see
[its README](../../bin/themes/README.md#a-themes-views)).

## Zone views

A view a free-form theme registers with `where = "zone"` — or `"both"`, which makes it a
fullscreen view as well — takes the widget's zone instead of the theme's zone picture **while
its `openWhen` holds**: a level, not an edge, the way the in-flight tuning surface takes the zone
while its interlock is closed. Where several hold, the first in the theme's list shows. It is
shown armed as well as disarmed.

- **Display only.** A zone view is not on the stack, answers no key, and is built without a
  `ctx` — `build(children, zone, state)` — so it binds no press; a widget zone receives no touch
  in any case. Its module may have `renderKey(zone, state)`, asked with the conditions, and it
  is rebuilt when that changes as well as whenever the theme's own zone key does.
- **On the zone's 2 Hz tick, through the job slot.** The conditions are asked on the pass after
  the zone's render-key throttle has ticked, and on no other: a zone view comes and goes within
  about half a second. When the view to show has changed, that pass marks the scene for a
  rebuild, and the scene job, in a pass of its own, builds the zone view or the theme. Nothing
  is built inline.
- **Paid for by the theme that has them.** The list is read by the scene build of a free-form
  theme — in the branch a declarative theme's module never takes — once per theme path, and the
  conditions are asked by a `refresh` wrapper that only a theme with zone views puts in place and
  that takes itself out once that theme is gone. So a theme without zone views, and every
  declarative theme, has the zone pass it had. The forms of `openWhen` and the rule for a
  condition function are those [above](#what-else-a-themes-view-may-open-on); a zone view's
  function runs on the tick of the zone pass. Counted offline with the accounting stubs, the
  wrapper costs such a theme 18 instructions on a zone pass and about 95 to 100 on the pass that
  asks, with one zone view.
- **A zone view that fails is dropped.** One whose module does not load, or whose `build` raises,
  is not shown again, with one log line, and the theme's own zone picture is built in its place.

## Confirmations

A press that must be agreed to first carries a `confirm` on its entry — or on one of its
options. A `choice` entry's own `confirm` guards every option it runs; an option that carries one
is held by its own question, which is used where both carry one. `fullscreen_menu.M.run` does not
perform such a press: it hands it to `views.confirm(widget, spec, work)`, which raises the
confirmation view and keeps `work` — the `press` and the `after` — on the visit's session until
the pilot answers. Both answers close the question first, through `views.closeConfirm`, which
forgets `work` and takes the view off the stack, so the surface under it shows again exactly as it
was; the agreeing button then runs `work`, so its `after` acts on the surface the press was written
for rather than on the question. Declining, and the view's `back` (a short press on RTN), run
nothing.

The one entry that carries a `confirm` today is the quick menu's **ERASE BLACKBOX**
(`fullscreen_menu.lua`, `BUILD.erase_blackbox`), which asks before it erases the flight
controller's blackbox. Its `spec` is a table of strings the entry resolved where it was built:

| Key | What it is |
| --- | --- |
| `title` | The question's heading. |
| `message` | The sentence that says what the press does. |
| `detail` | Optional, a line under the message — for the erase, how full the storage is. |
| `confirmLabel` | The label of the button that agrees (the action), drawn on the right in the warning colour. |
| `cancelLabel` | The label of the button that declines, drawn on the left. |

`views.confirm` answers `false` — and `M.run` then performs nothing — where the widget has no
confirmation view or the stack is full. A press that cannot ask its question is **not**
performed: on an irreversible action, refusing loses nothing where performing it loses the
logs. The confirmation view reads the pending press through `views.pendingConfirm` and answers it
through `views.closeConfirm`. The pending press goes when the visit does, so a full screen left
with the question standing never performs it.

The confirmation is reached the same way by a theme that draws the entry itself: `ctx.run` goes
through `M.run`, so a theme handing the menu its ERASE BLACKBOX record gets the question too,
and adds no work of its own.

## What follows a press

A press does its work and nothing else. What happens next is data: an `after` action on the
entry, the option or the button, which `views.navigate(widget, after)` performs. An action is a
string:

| Action | What it does |
| --- | --- |
| `openView:<id>` | Open that view, or return to it where it is already on the stack. |
| `closeView` | Close the view on top; what is under it shows again. |
| `done` | The interaction is finished: the stack is emptied. With no base layer that leaves full screen; with one, the base layer — the theme — shows again. |
| `exitFullscreen` | Empty the stack and leave full screen, base layer or not. |
| `openTool` | Open the suite's tool inside the widget, where the model is disarmed. The tool takes full screen until it is closed; see [The tool](#the-tool). The stack is emptied as for `done`, keeping what the theme's views' conditions last answered, so once the tool is closed the base layer shows, or with none the quick menu, and a theme's view whose condition still holds is not opened again. |
| `openTool:<menuId>` | The same, with the tool opened on that page instead of on its menu; the back key there closes the tool again, because the pilot came from the widget. Only for a page `views.lua` lists in `TOOL_LANDINGS` — `tools_flight_log_page`, while `flightLogOffered` holds — and nothing at all otherwise, so a key bound to it does nothing while the page is not offered. |
| `none` | Nothing. The press did whatever needed doing itself. |

A missing `after`, and anything that is not one of these, is `none`. `views.parseAction()` is
the one place an action is read, so a later form of it is added there and nowhere else.

`navigate()` is the only place a view leaves full screen. Every action but `none` drops what is
built, so the next pass builds the view now on top. The shipped buttons:

| Where | Button | after |
| --- | --- | --- |
| Quick menu | ERASE BLACKBOX | `done` — behind a [`confirm`](#confirmations): the press is held, and this is what runs once it is agreed to |
| Quick menu | IN-FLIGHT TUNING | `none` — its press raises the tuning surface's own flag |
| Quick menu | BATTERY | `openView:battery_pick` |
| Quick menu | MAIN MENU | `openTool` |
| Quick menu | FLIGHT LOG, where the pilot has put it in the menu | `openTool:tools_flight_log_page` |
| Quick menu | BATTERY PROFILE | `openView:battery_profile` |
| Quick menu | the header's X | `done` |
| Battery profile page | each profile | `none` — the page stays open and its foot line shows the outcome |
| Battery profile page | the header's < | `closeView` |
| Battery profile page | the header's X | `done` |
| Picker | each pack, and NO BATTERY | `done` |
| Picker | the header's X | `done` |
| Over a fullscreen theme that binds no control | the menu glyph | `openView:menu` |
| Over a fullscreen theme that binds no control | the X | `exitFullscreen` |
| Over a fullscreen theme that binds no control, and on the connect splash at full screen | the tool control | `openTool` |

So the picker's answers and its X leave full screen where there is no base layer, as they always
have, and the quick menu, with its BATTERY button, is what the next entry into full screen shows.
Over a fullscreen theme the same `done` puts the theme back instead.

`views.bind(widget)` returns the actions and building blocks bound to one widget, for code that
has no widget of its own to pass. It is the `ctx` a fullscreen theme's build receives:
`ctx.action(after)` performs `after` exactly as `navigate(widget, after)` does, and `ctx.keys`,
`ctx.condition`, `ctx.entries`, `ctx.menu` and the entry calls — `ctx.entry`, `ctx.list`,
`ctx.visible`, `ctx.run`, `ctx.status` and `ctx.info` — are described in
[dashboard themes](dashboard-themes.md#ctx).

## Keys

Radio-wide choices on [Keys](../pages/settings/dashboard/keys.md) apply with or without a base
layer, including the SYS/Main menu and the TELE and PAGE/Quick menu defaults. Keys on **Theme** return false
without a base layer, so LVGL can handle them. With the base showing and no view on top,
`ctx.keys[key]` wins over `init.keys[key]`; an unbound key is consumed without navigation.
`views.key(widget, event)` is called for every event of a fullscreen pass that is not idle,
ahead of the job the pass may run, so a key is not lost to a build. It acts on the release edge
of six keys, read from the firmware's `EVT_VIRTUAL_NEXT_PAGE`, `EVT_VIRTUAL_PREV_PAGE`,
`EVT_VIRTUAL_EXIT`, `EVT_MODEL_BREAK`, `EVT_SYS_BREAK` and `EVT_TELEM_BREAK` where the radio
defines them, and on nothing else. For keys on **Theme**:

| Key | A view on top | The base layer showing |
| --- | --- | --- |
| PAGE down / up | the menu on top: `closeView`; any other view: `openView:menu` | the theme's `ctx.keys.pageDown` / `pageUp`, then `init.keys` for that key, else nothing |
| RTN | the view module's `back(widget)` if it has one, else `closeView` | the theme's `ctx.keys.exit`, else nothing |
| MDL, SYS, TELE | nothing, unless bound to the view on top | the theme's `ctx.keys.mdl` / `sys` / `tele`, then `init.keys` for that key, else nothing |

A key the theme binds to `openView:<id>`, RTN aside, is `closeView` while that view is on top,
whatever the first column says for it: a bound key toggles its view.

Outside fullscreen MDL, SYS and TELE open the radio's own menus. A widget in fullscreen gets them
instead and the radio opens nothing, so they are free for a theme to bind; without a binding they
do nothing, as before.

The picker's `back` is its close box — the prompt is dismissed and `done` follows — because a
plain `closeView` would leave `pending` standing and the picker would open again on the next
pass. A long press on RTN leaves full screen in the firmware; Lua sees only its press edge,
which is not answered. Keys are not answered while the in-flight tuning surface or suite tool
is up. Radio-wide choices and manifest bindings to the widget's own actions and views already
act on the connection splash, before the theme's build supplies `ctx.keys`; a manifest binding
to one of the theme's views acts once the connection is ready and those views are registered.

## `rfsuite.batteryPick`

The handle the widget publishes for a theme or another widget
([dashboard themes](dashboard-themes.md#rfsuitebatterypick)) maps onto the same stack:

| Call | What it does here |
| --- | --- |
| `open()` | `openView:battery_pick`, and a request of its own on `state.batteryPick`, stamped with the last disarm. The stack is fullscreen state and is dropped by the next pass without an event, so a call made in the zone would otherwise never reach the screen; the next fullscreen pass takes the request as an explicit `openView:battery_pick`. It lapses where the model is armed or has disarmed since the call, and a reconnect drops it with the table. |
| `dismiss()` | Ends the prompt for this connection (`dismissed`, and `pending` cleared), then `closeView` if the picker is the view on top. |
| `select(id)` | Records the pick, as before; it opens and closes nothing. |

The handle runs outside the widget's own error guard, so it reaches `views.lua` through a loader
that returns nothing rather than raising when the file cannot be loaded.

## The tool

`openTool` hands full screen to the suite's tool until it is closed.
`widgets/dashboard/tool_host.lua` loads `ui/home.lua` into the widget's Lua state — the file the
tool script runs — and `widget.refresh` drives it in place of the whole pass, keys included, so
neither a view, the base layer nor the dashboard's own work runs beside it:

- **Opening** takes two passes after the press: one loads `ui/home.lua`, one calls
  `init({ hosted = true })` — with `landing = <menuId>` for `openTool:<menuId>`, which opens that
  page the way the pilot would reach it, through its root entry and its menu, under the menu's
  own conditions; where a step fails the tool opens on its menu instead. A hosted tool leaves alone what the widget's state already owns:
  it does not compile the tree, announce, reset the event runner, shut the card log, clear the
  chunk cache or drop `_G.rfsuite` on its way out.
- **Loading**, from the first of those passes until the tool closes, `loadScript` is the tool
  script's loader (`src/main.lua`) for the suite's own files: the suite's load mode in place of
  the one a caller passes, so a current `.luac` beside a file is read rather than its source, and
  every chunk but a page's own module kept until the tool closes. The widget's global table is
  shared with every other widget on the radio, so any other path reaches the radio's loader as it
  was asked for.
- **Running**, the tool's `run(event, touchState)` is called under the widget's event context, so
  the MSP queue bounds its loops by count and the event runner stays on the task list the widget
  has already worked through. A widget call is stopped at the instruction limit, which the tool
  script on a colour radio is not. EdgeTX raises that stop once per call and lets the rest of the
  call run, so the innermost `pcall` around the code it lands in catches it. A page whose `build`
  is stopped gets an empty body and is built again on the next pass, up to three passes in a row,
  before it shows *This page could not be drawn*; a build that is above the limit on its own
  therefore does not open hosted. A page whose `wakeup` is stopped is called again on the next
  pass, so a page that spreads its work over its wakeups keeps each one within what a pass leaves:
  hosted, the Logs page reads one unit of a log per wakeup and bounds its search by a count of
  entries rather than by the clock. A stop that escapes the tool is caught by the host, which runs
  the tool again on the next pass, and twelve such stops in a row give the tool up.
- **Closing** is the tool's own sequence: the back key at the top of its menu, or on the page
  `openTool:<menuId>` opened it on while that page is still the one up, or
  `requestClose()`, which the host calls on the first pass without an event (full screen has
  been left) and when the model arms. When `run` returns 2 the host detaches the tool's MSP
  client, puts back the MSP queue's default client and the `preferences` and `savePreferences` it
  found on `_G.rfsuite`, puts back the `loadScript` it replaced -- unless something has been put
  over it since, in which case its copy passes every call through -- and lets go of the kept
  chunks, drops the module cache entries under `app/` and `ui/`, and drops the
  scene, so the next pass builds the base layer, or with none the quick menu. No condition is
  asked while the tool is open, so that pass compares against what the conditions answered when
  it was opened: a theme's view whose condition held then and still holds stays closed, and one
  whose condition rises later opens as it would have. A widget sent to the background drops the
  tool without the sequence, because it cannot paint it; twelve instruction-limit stops in a row
  and an error that escapes the tool drop it the same way. Whichever way the host ends a tool
  that has loaded, it first calls the tool's `releasePages()`, the page release of the closing
  sequence, so every page the tool holds runs its `onClose`: a page switches its servo, mixer or
  motor override off there, and the theme settings page ends its edit scope. What those queue is sent by the widget's own
  MSP tick. After the closing sequence there is nothing left to release.

A theme that binds its own controls reaches the tool with `ctx.action("openTool")`, or with
`ctx.action("openTool:tools_flight_log_page")` on its *Flight Log* page.

## Related

- [Quick menu](../dashboard/quick-menu.md) — the menu's entries and their keys.
- [Dashboard themes](dashboard-themes.md) — `state.batteryPick` and `rfsuite.batteryPick`.
- [In-flight tuning overlay](../dashboard/inflight-tuning.md) — the fullscreen surface that is
  not a view.

*Documented against RFSuite 0.1.7.*
