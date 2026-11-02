---
title: Background tasks
sidebar_label: Background tasks
---

# Background tasks

What the suite does on its own, without a page asking for it: which background jobs exist under
`src/rfsuite/tasks/events/`, when each one runs, what it does, and the rules a new task has to
follow.

## Who drives them

Nothing under `tasks/events/` runs by itself. `tasks/events/runtime.lua` (the event runtime) does
work only when something calls `Events.wakeup()`, and three hosts do. Each one first calls
`MspRuntime.tick()` (`tasks/msp/runtime.lua`) and then `Events.wakeup()`:

| Host | How often | Context |
| --- | --- | --- |
| Dashboard widget (`widgets/dashboard/runtime.lua`) | every logic tick: 0.1 s, or 0.05 s while the widget is starting | `widget` |
| Service widget (`widgets/service/runtime.lua`) | every 0.1 s | `widget` |
| The tool, while it is open (`ui/home.lua`) | every 5 `getTime()` ticks (50 ms). Not on a pass that changes menu, not while background work is deferred, and not on the MSP speed page | `tool` |

The service widget exists only to be a host. Put it on a model that does not use the dashboard
and the background work still runs. If a radio runs neither widget and the tool is closed, nothing
advances: no connect chain, no custom telemetry sensors, no flight record.

**Context.** `lib/env.lua` answers `Env.get()` from `rfsuite.session.event_context`. Both widgets
set it to `"widget"` around their call, and anything that sets nothing gets `"tool"`. A tool
opened from inside the dashboard (`widgets/dashboard/tool_host.lua`) runs its work in the
`widget` context.

The tool and each widget are separate Lua states. Each one has its own copy of every runner and
every task module, and its own `rfsuite.session`.

## What one wakeup does

`Events.wakeup(carry)` does the following, in this order:

1. **Link state, with hysteresis.** It reads `lastConnected` from the MSP runtime. The link has to
   stay up for 0.6 s before it counts as connected, and stay down for 2.0 s before it counts as
   disconnected. Only those two edges set `session.isConnected` (`publishConnected`).
   - On **connect** the previous session ends: the flight count is set to 0 and the flight
     record is reset. The exception is a link that came back after a loss in flight, covered
     below.
   - On **disconnect**, every runner is reset so that it runs again on the next connect, and a
     full garbage collection runs. Unless the craft was armed, `session.flightlog` is dropped and
     the arm-edge detector is cleared. The flight statistics are kept, so the post-flight screen still shows them
     after the pack comes off.
   - While the link is held down, the widget context puts back a model name that
     `model_name_sync` replaced (`restorePendingModelName`). Because this is a check of the
     current state rather than an event, it also catches a radio that was switched off while
     connected.
2. **A flight kept across a link loss.** If the link dropped while the craft was armed, the
   flight is kept. Once the link is back, the runtime waits up to 5 s for an armed reading
   received since then (`settleFlightAfterGap`). If the craft is armed, it is the same flight. If
   it is disarmed, or no such reading arrives in time, the kept flight is ended.
3. **`onconnect`.** This runs while the link is held up, the craft is not armed, and the MSP API
   version was not refused. When the chain finishes, a garbage collection runs.
4. **`telemetry_bg`.** This runs while the link is held up. In the widget context it waits until
   `onconnect` has finished, unless the craft is armed. The wait exists because of the firmware's
   per-call instruction limit for widgets. The tool does not wait: a standalone script has no such
   limit, and while the tool is open the background function script is paused, so this is the
   only decoder running.
5. **Arm and disarm edges.** These are watched while the link is held up and no kept flight is
   still being settled. A change of the armed state resets that edge's runner (`onarm` or
   `ondisarm`). The runner is then called on every following wakeup until it reports no remaining
   work, not just once on the edge.
6. **Widget context only:** the flight record samples the flight in progress
   (`telemetry/flight_record.lua`), then the Tune Advisor capture advances
   (`tune_capture.lua`, see below).

`carry` comes from the dashboard. It is true on a pass that also runs the dashboard's telemetry
read, and work that does not need that pass (today, the SmartFuel wake) waits one logic tick.
Every other host passes nothing.

## The ordered runners: `onconnect`, `onarm`, `ondisarm`

Each of these categories is a folder with a `manifest.lua`, a `tasks.lua` that returns
`Runner.new("<category>")`, and a `tasks/` folder. The runner is `tasks/events/common/runner.lua`.

**How a runner works:**

- The manifest is an ordered list. An entry is either a name or
  `{ name = ..., context = "both" | "tool" | "widget" }`. A plain name means `both`. A task runs
  only in a context its entry allows.
- Each wakeup, the runner takes the **first** eligible task that is neither complete nor failed,
  calls its `wakeup(args)`, and then asks `isComplete()`. That makes at most one task per wakeup,
  so the tasks run strictly one after another.
- A task's module is loaded from `<category>/tasks/<name>.lua`. If that file does not exist, the
  runner loads `common/<name>.lua` instead. The module is released once the task completes or
  fails.
- A task that has not completed after **25 s** is re-queued, with a back-off of 1 s, 2 s and then
  4 s, and gets a fresh module instance each time. After 3 re-queues it is marked failed and
  skipped. A failed task counts towards `done` in `getProgress()`, and `failed` says how many of
  those gave up.
- `reset()` (on disconnect, and on every arm or disarm edge for that edge's runner) marks every
  task as not done and calls each loaded module's `reset()`.

**The task module contract:**

```lua
local M = {}
function M.wakeup(args) end   -- called once per wakeup while this task is the current one;
                              -- args.context is "tool" or "widget". Do not keep `args`:
                              -- the same table is reused for every call.
function M.isComplete() end   -- true once the work is done; the runner then moves on
function M.reset() end        -- optional; forget everything, so the next run starts fresh
return M
```

A task that sends an MSP request latches it in a module-local flag, so it does not send the
request again on the next wakeup, and reports complete when the reply has been handled. Put a
request on the MSP queue with a `maxRetries` that keeps its total give-up time under the runner's
25 s. Otherwise the runner re-queues the task while its first request is still in flight.

### `onconnect`: once per connection

Runs in manifest order after each connect. Every task in this table reads from the flight
controller unless it says otherwise:

| Task | Context | What it does |
| --- | --- | --- |
| `apiversion` | both | Waits for the MSP runtime's API version read and shows the unsupported-version notice when the version is refused. |
| `uid` | both | Waits for the MSP runtime's MCU UID read and resolves the per-model preferences file from it. |
| `rtc` | both | Sends the radio's clock to the flight controller (`MSP_SET_RTC`). |
| `status` | both | `MSP_STATUS`: the active PID and rate profiles and the profile counts. |
| `telemetry` | both | `TELEMETRY_CONFIG`: the telemetry port settings, the enabled sensors and the CRSF telemetry mode and rate. |
| `flight_stats` | widget | The board's flight count and total flight time. |
| `dataflash_summary` | widget | The state of the blackbox flash. |
| `battery_config` | both | The battery settings. |
| `governor_config` | both | The governor feature, mode and settings. |
| `esc_sensor_config` | tool | The ESC telemetry protocol and ESC type. |
| `smartfuel_config` | both | The SmartFuel settings. |
| `name` | both | The craft name (`session.modelName`). |
| `model_params_sync` | widget | Writes the flight controller's model parameters onto the radio model's timers and global variables, when *Synchronize Model Parameters* is on. |
| `model_name_sync` | widget | Renames the radio model to the craft name when *Synchronize Model Name* is on, and puts the model's own name back when the link goes. |
| `function_script` | widget | Adds the special function that runs `SCRIPTS/FUNCTIONS/rfsbg.lua` (the background decoder) when the model has none. It reads nothing from the flight controller. |

The last three are `widget` because they change the pilot's model. That is background work that
belongs to whatever runs during flight. If they ran in both contexts, the tool and the widget
would each attempt the same rename from Lua states that cannot see each other.

The dashboard and the service widget show the chain's progress through
`Events.getOnconnectProgress()` and `Events.getOnconnectPendingTaskName()`. A reboot of the flight
controller that is too short to bring the link down does not re-run the chain on its own.
`Events.rerunOnconnect()` resets this runner only.

### `onarm`: on every arm edge

Widget only.

| Task | What it does |
| --- | --- |
| `flight_record` | Opens the flight record. It is first so that the record is open before anything behind it looks at it. |
| `flight_log` | Notes the start of the flight for the flight log. It writes nothing to the card while the pilot is taking off. |

### `ondisarm`: on every disarm edge

Widget only.

| Task | What it does |
| --- | --- |
| `flight_record` | Closes the record and moves it to `last`, so every task behind it reads a finished flight. |
| `flight_log` | Writes the flight log line to the card. It is near the front because a pack unplugged soon after the disarm drops `session.flightlog`. |
| `flight_stats` | Reads the board's flight count and total flight time again. |
| `dataflash_summary` | Reads the blackbox flash state again. |
| `tune_history` | Marks the flight's Tune Advisor numbers as owed. It completes in the same call, so it never holds up the chain. |

## The continuous job: `telemetry_bg`

`tasks/events/telemetry_bg/tasks.lua` is not a runner. Its `wakeup` runs on every eligible pass
(see step 4 above) and never completes. On its first three passes it loads one module each, so no
single pass loads all three.

| Module | What it does |
| --- | --- |
| `drain.lua` | Takes the flight controller's custom telemetry frames off the CRSF link, decodes them and publishes them as radio sensors. It also sets `session.telemetryFrameAt`. |
| `smart.lua` | Computes the SmartFuel fuel and consumption values, at most once a second. It skips the dashboard's `carry` passes. |
| `adjustments.lua` | Announces an in-flight adjustment (function and new value) after the decode has published it. |

When the background function script (`rfsbg.lua`) is already decoding for the whole radio,
`drain.lua` and `adjustments.lua` step aside together, so no sensor is published twice and no
adjustment is announced twice. `smart.lua` keeps running because its state is per Lua state.

## Not a runner: the Tune Advisor capture

After a disarm that `tune_history` marked as owed, the runtime loads `tasks/events/tune_capture.lua`
no earlier than 5 s later, so that the disarm chain has the link to itself first. The capture reads
the three axes, saves them on the radio and clears the flight controller. Arming stops a capture
in progress. The module is released when nothing is left to do. It runs in the widget context
only and skips the dashboard's `carry` passes.

## Adding a task

- **Put it in the right category.** Work per connection goes in `onconnect`, work per flight in
  `onarm` or `ondisarm`, and work on every pass in `telemetry_bg`. A new continuous job costs
  instructions on every pass, so measure it with `bin/accounting/measure.lua`.
- **Pick the context deliberately.** A task that writes to the radio model is `widget`. A task
  only a configuration page needs is `tool`. Everything else is `both`.
- **Mind the order.** A task that reads what another task fills in goes after it in the manifest.
- **If it shares a read with another category**, put it in `common/<name>.lua` and give each
  category a manifest entry with that name. The runner falls back to `common/`, as
  `flight_stats` and `flight_record` do. A wrapper in the category folder works as well, as
  `onconnect/tasks/status.lua` shows.
- **Keep each wakeup short.** It runs inside a widget call that the firmware stops at its
  instruction limit. Do one step per wakeup and return, rather than waiting in a loop.

## Related

- [Connection status](../reference/connection-status.md)
- [Flight statistics](../reference/flight-statistics.md)
- [Background decoder](../reference/background-decoder.md)
- [Saving](../reference/saving.md)
