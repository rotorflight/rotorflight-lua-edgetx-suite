---
title: The module loader
sidebar_label: Module loader
---

# The module loader

`rfsuite.require(path)` (`src/rfsuite/lib/require.lua`) loads a suite module once and hands the
same result to every later caller. A relative `path` is taken under `/SCRIPTS/TOOLS/rfsuite-core/`;
the loaded results are kept in `rfsuite.modules`, keyed by that full path.

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

## Reloading and releasing

- `rfsuite.require(path, true)` runs the file again even when it is cached. If it now returns
  nothing, the cached value is dropped; if it fails to load or raises, the cached value stays.
- `rfsuite.clearModule(path)` drops one entry and `rfsuite.clearAllModules()` drops all of them;
  the next `rfsuite.require` runs the module again. In the tool, `loadScript` keeps the compiled
  chunk of most files (`src/main.lua`), so that run need not read the card.
