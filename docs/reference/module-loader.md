---
title: The module loader
sidebar_label: Module loader
---

# The module loader

`rfsuite.require(path)` (`src/rfsuite/lib/require.lua`) loads a suite module once and hands the
same result to every later caller. A relative `path` is taken under the code root,
`rfsuite.paths.core` (see below); the loaded results are kept in `rfsuite.modules`, keyed by that
full path.

## Card paths

Where the suite sits on the card is stated once, in `src/rfsuite/lib/paths.lua`:

| Field | Value today | Holds |
| --- | --- | --- |
| `core` | `/SCRIPTS/RFSUITE/core` | the suite's code |
| `user` | `/SCRIPTS/RFSUITE/user` | the pilot's data: preferences, flight log, user themes |
| `legacyUser` | `/SCRIPTS/TOOLS/rfsuite.user` | where an earlier install kept that data, read only to move it |

`lib/require.lua` loads that file and publishes it as `rfsuite.paths`. Every Lua state of the
suite -- the tool, both widgets and the special-function script -- loads `lib/require.lua` before
any other suite module, so every module can build its paths from the table instead of spelling
them: `loadScript(rfsuite.paths.core .. "/lib/log.lua", mode)`. Neither root ends in a slash.
If `lib/require.lua` cannot be loaded or run, no module finds its paths, and the state does not
start.

`lib/require.lua` also decides, once per Lua state, which folder `user` means. While the old folder
exists and the new one holds no `moved.txt`, `user` stays the old folder and `moveTo` names the new
one; `lib/precompile.lua` then runs the copy (`lib/user_move.lua`). A module keeps the path it read
when it loaded, so the switch happens at the next start and never inside a running state.

Only `lib/paths.lua` itself, `lib/require.lua` (to load it), the files that load
`lib/require.lua` (`src/main.lua`, the two widgets' `main.lua`, `src/functions/rfsbg.lua`), and
the model template (`src/templates/5.Rotorflight/Rotorflight.lua`), which runs without it, name
the code root directly. `bin/core/verify_card_path_literals.lua` fails on any other file that does.

A desktop test that loads a suite module without `lib/require.lua` provides the table itself,
from the same file, for example `_G.rfsuite.paths = dofile("src/rfsuite/lib/paths.lua")` when it
runs from the repository root.

## What a load returns

| The module's file | `rfsuite.require` returns | Kept in the cache |
| --- | --- | --- |
| returns a value (a table, a function, `false`, ...) | that value | yes -- later calls get the same value without running the file again |
| returns nothing | `nil` | no |
| cannot be read or compiled | `nil` and the error, and prints a `[require] Failed to load` line when the radio gives a reason | no |
| raises an error while it runs | `nil` and the error, and prints a `[require] Error executing` line | no |

A caller can therefore treat any falsy result as "not available", which is what
`rfsuite.require(path) or false` followed by `if not mod` relies on.

## A module that has to run once returns its table

Only a value is kept. A module that returns nothing is run again on every `rfsuite.require` of it,
as is a file that failed to load, so a module whose body must run only once ends in
`return M`.

## A failed load is not remembered, so the caller remembers it

Because a failure is not cached, a caller that asks again on every pass loads the file again every
time -- from the card, unless the tool already holds its compiled chunk (see below). Callers that run on every pass therefore keep the answer themselves:

- The background telemetry runner (`tasks/events/telemetry_bg/tasks.lua`) and SmartFuel record
  `false` for a module that did not load and do not ask for it again until the Lua state restarts.
- The custom telemetry drain (`tasks/events/telemetry_bg/drain.lua`, which has a loader of its
  own -- `loadScript` and `pcall`, not `rfsuite.require`, so a failed load there prints nothing)
  and the MSP API version read, which every connection waits on, ask
  again for a module that did not load after one second rather than on every pass. For the drain
  that is its decoder table (`lib/rf2tlm_sensors.lua`) and `lib/crsf.lua`; while one is missing it
  takes nothing off the link. A load can fail without the file being broken -- the loader's
  `pcall` also catches the radio's instruction limit when it stops a pass while the module's chunk
  runs -- so a failure that does not last costs about a second.
- The background function script (`functions/rfsbg.lua`) waits the same second before it asks
  again for the adjustment teller, which it loads only while *Adjustment events* is on.

## Reloading and releasing

- `rfsuite.require(path, true)` runs the file again even when it is cached. If it now returns
  nothing, the cached value is dropped; if it fails to load or raises, the cached value stays.
- `rfsuite.clearModule(path)` drops one entry and `rfsuite.clearAllModules()` drops all of them;
  the next `rfsuite.require` runs the module again. In the tool, `loadScript` keeps the compiled
  chunk of most files (`src/main.lua`), so that run need not read the card.

## Chunks a page lets go when the pilot leaves its area

The tool's `loadScript` keeps a compiled chunk until the tool closes, except a page's own
`page.lua` -- in the tool started from the Tools menu (`src/main.lua`) and in the tool opened from
the dashboard (`widgets/dashboard/tool_host.lua`). A page module can ask for the chunks under its
own folder to go earlier, by naming the menu its entries sit in:

```lua
local M = { visitMenu = "helicopter_setup_menu" }
```

When the page is released, the page registry (`app/pages/init.lua`) notes the page's folder. On
every change of menu or page the tool then calls `registry.endVisits(currentMenuId)`
(`ui/home.lua`): while the pilot is on that menu or on a page whose file is in that folder, the
chunks stay; once neither holds, the registry calls `rfsuite.utils.releaseChunksUnder(folder)`,
which both loaders publish for their own cache, and the next visit reads the files from the card
again. So several menu entries that open the same page keep its code while the pilot moves between
them.

Only chunks under the page's folder go. Files it loads from elsewhere -- MSP APIs, libraries other
pages use too -- stay cached, and no module instance is touched: the page drops its own in its
`onClose`, and a module someone else still holds keeps its code alive. Nothing is collected at that
moment, because the old scene is still on screen until the next build replaces it; the memory comes
back with the collector's normal work. With the debug log level, the tool writes a line
`page area left for <menu>: N visit(s) ended, M chunk(s) let go`.

The helicopter setup is the page that uses it; it also reads each step's file past the cache
(`rfsuite.utils.loadScriptUncached`), so a step's code goes with the step's cards.
