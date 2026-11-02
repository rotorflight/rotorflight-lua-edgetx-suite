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
| `core` | `/SCRIPTS/TOOLS/rfsuite-core` | the suite's code |
| `user` | `/SCRIPTS/TOOLS/rfsuite.user` | the pilot's data: preferences, flight log, user themes |

`lib/require.lua` loads that file and publishes it as `rfsuite.paths`. Every Lua state of the
suite -- the tool, both widgets and the special-function script -- loads `lib/require.lua` before
any other suite module, so every module can build its paths from the table instead of spelling
them: `loadScript(rfsuite.paths.core .. "/lib/log.lua", mode)`. Neither root ends in a slash.
If `lib/require.lua` cannot be loaded or run, no module finds its paths, and the state does not
start.

Only `lib/paths.lua` itself, `lib/require.lua` (to load it), the files that load
`lib/require.lua` (`src/main.lua`, the two widgets' `main.lua`, `src/functions/rfsbg.lua`), and
the model template (`src/templates/5.Rotorflight/Rotorflight.lua`), which runs without it, name
the code root directly.

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

Because a failure is not cached, a caller that asks again on every pass goes back to the card for
the file every time. Callers that run on every pass therefore keep the answer themselves:

- The background telemetry runner (`tasks/events/telemetry_bg/tasks.lua`), SmartFuel and the
  custom telemetry drain record `false` for a module that did not load and do not ask for it again
  until the Lua state restarts. For the drain that is its decoder table (`lib/rf2tlm_sensors.lua`)
  and `lib/crsf.lua`; without them it takes nothing off the link in that state.
- The MSP API version read, which every connection waits on, asks again for a module that did not
  load after one second rather than on every tick, so a failure that does not last still lets the
  connection come up.

## Reloading and releasing

- `rfsuite.require(path, true)` runs the file again even when it is cached. If it now returns
  nothing, the cached value is dropped; if it fails to load or raises, the cached value stays.
- `rfsuite.clearModule(path)` drops one entry and `rfsuite.clearAllModules()` drops all of them;
  the next `rfsuite.require` runs the module again. In the tool, `loadScript` keeps the compiled
  chunk of most files (`src/main.lua`), so that run need not read the card.
