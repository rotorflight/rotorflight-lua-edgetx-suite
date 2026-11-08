---
title: Background tasks
sidebar_label: Background tasks
---

# Background tasks

What the suite does on its own, without a page asking for it: which background jobs exist under
`src/rfsuite/tasks/events/`, when each one runs, what it does, and the rules a new task has to
follow. Other background work outside that folder is listed at the end.

## Who drives them

Nothing under `tasks/events/` runs by itself. `tasks/events/runtime.lua` (the event runtime) does
work only when something calls `Events.wakeup()`, and three hosts do. Each one first calls
`MspRuntime.tick()` (`tasks/msp/runtime.lua`) and then `Events.wakeup()`. The intervals below are
the shortest gap between two calls; a host can skip a pass for its own reasons.

| Host | How often | Context |
| --- | --- | --- |
| Dashboard widget (`widgets/dashboard/runtime.lua`) | every logic tick: 0.1 s, or 0.05 s while the link is up and the connection is not ready yet. Skipped while the startup compile holds the connect, on a pass that builds a scene, and while a tool is hosted (the tool then drives it) | `widget` |
| Service widget (`widgets/service/runtime.lua`) | every 0.1 s. Skipped on a pass that re-reads the settings, while the startup compile holds the connect, and while the dashboard's mark is fresh (below) | `widget` |
| The tool, while it is open (`ui/home.lua`) | every 5 `getTime()` ticks (50 ms). Not on a pass that changes menu, not while background work is deferred, and not on the MSP speed page | `tool` |

The service widget exists only to be a host. Put it on a model that does not use the dashboard
and the background work still runs. With both widgets on one model, the dashboard marks each
pass of its background step (`Events.markDriving`, also while its startup compile holds the
connect), and the service widget skips its runtime calls, its settings reload and its card-log tick
while that mark is younger than 0.5 s. When the mark goes stale -- the dashboard taken off the
model, its script stopped, or a tool open inside it -- the service widget resumes its own calls.
With a tool open inside the dashboard, the tool and the service widget then both drive the
runtimes, and before the dashboard's first mark both can run for a pass.

If a radio runs neither widget and the tool is closed, no connect chain runs and no flight is
recorded. Custom telemetry can still be decoded: the background function script
`SCRIPTS/FUNCTIONS/rfsbg.lua`, when the model runs it, loads `telemetry_bg/drain.lua` and
`telemetry_bg/adjustments.lua` itself, without the event runtime.

**Context.** `lib/env.lua` answers `Env.get()` from `rfsuite.session.event_context`. Both widgets
set it to `"widget"` around their call, and anything that sets nothing gets `"tool"`. A tool
opened from inside the dashboard (`widgets/dashboard/tool_host.lua`) runs its work in the
`widget` context.

**Lua states.** The standalone tool runs in its own Lua state, with its own copy of the event
runtime, every runner and `rfsuite.session`. The widgets share one state, so the dashboard, the
service widget and a tool hosted by the dashboard all use the same event runtime and session.

## What one wakeup does

`Events.wakeup(carry)` does the following, in this order:

1. **Link state, with hysteresis.** It reads `lastConnected` from the MSP runtime. The link has to
   stay up for 0.6 s before it counts as connected, and stay down for 2.0 s before it counts as
   disconnected. Within a wakeup, only those two edges change `session.isConnected`
   (`publishConnected`); `Events.reset()` also clears it directly.
   - On **connect** the previous session ends: the flight count is set to 0 and the flight
     record is reset. The exception is a link that came back after a loss in flight, covered
     below.
   - On **disconnect**, every cached runner is reset and a full garbage collection runs. So
     `onconnect` runs again after the next connect, and the arm and disarm runners start fresh
     on the next edge. Unless the craft was armed, `session.flightlog` is dropped and the
     arm-edge detector is cleared. The flight statistics are kept, so the post-flight screen
     still shows them after the pack comes off.
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
5. **Arm and disarm edges.** These are detected while the link is held up and no kept flight is
   still being settled. The first armed reading only sets the baseline and fires nothing. A change
   of the armed state resets that edge's runner (`onarm` or `ondisarm`), which is then called on
   every following wakeup until it reports no remaining work, not just once on the edge. A newer
   edge replaces an edge runner that has not finished.
6. **Widget context only:** the flight record samples the flight in progress
   (`telemetry/flight_record.lua`): its clock runs while armed, and its statistics are sampled at
   most every 0.5 s while the link is up. Then the Tune Advisor capture advances
   (`tune_capture.lua`, see below).

`carry` comes from the dashboard. It is set on a pass that is going to run the dashboard's
telemetry read, when logic ticks come closer together than the read interval, so the next tick is
free. Work that does not need that pass waits one logic tick: the SmartFuel wake and the Tune
Advisor capture. Every other host passes nothing.

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
- A task's module is loaded from `<category>/tasks/<name>.lua`. If that cannot be loaded, the
  runner loads `common/<name>.lua` instead. The module is released once the task completes or
  fails.
- A task that is still not complete more than **25 s** after it started is retried after 1 s,
  2 s and then 4 s, each time with a fresh module instance. Nothing behind it in the list runs
  while it waits. If the fourth attempt also times out, the task is marked failed and skipped. A
  failed task counts towards `done` in `getProgress()`, and `failed` says how many of those gave
  up.
- `reset()` (on disconnect, and on every arm or disarm edge for that edge's runner) marks every
  task as not done and calls each loaded module's `reset()`.

**The task module contract:**

```lua
local M = {}
function M.wakeup(args) end   -- called once per wakeup while this task is the current one;
                              -- args.context is "tool" or "widget". Do not keep `args` and do
                              -- not write to it: the same table is reused for every call.
function M.isComplete() end   -- true once the work is finished or deliberately stopped
function M.reset() end        -- optional; forget everything, so the next run starts fresh
return M
```

`isComplete()` returning true means the task is finished with, not that its read succeeded. The
`status` task, for one, reports complete on an MSP error too, so `failed` in the progress counts
tasks that timed out, not every read that failed.

A task that sends an MSP request latches it in a module-local flag, so it does not send the
request again on the next wakeup. If the queue drops the request (reason `"cleared"`), it
releases the latch so the next wakeup sends again (`common/status.lua` shows the pattern). The
runner's 25 s start when the task starts, and the queue starts a message's timeout only when the
message is sent, so a request's waiting time and all of its retries have to fit inside the 25 s.
Otherwise the runner retries the task while its first request is still in flight.

### `onconnect`: once per connection

Runs in manifest order after each connect. Every task in this table reads from the flight
controller unless it says otherwise:

| Task | Context | What it does |
| --- | --- | --- |
| `apiversion` | both | Waits for the MSP runtime's API version read. A refused version stops the whole chain, and the tool and the dashboard report it. |
| `uid` | both | Waits for the MSP runtime's MCU UID read and resolves the per-model preferences file from it. |
| `rtc` | both | Sends the radio's clock to the flight controller (`MSP_SET_RTC`). |
| `status` | both | `MSP_STATUS`: the active PID and rate profiles and the profile counts. |
| `telemetry` | both | `TELEMETRY_CONFIG`: the telemetry port settings, the enabled sensors and the CRSF telemetry mode and rate. |
| `flight_stats` | widget | The board's flight count and total flight time. |
| `dataflash_summary` | widget | The state of the blackbox flash. |
| `battery_config` | both | The battery settings. |
| `governor_config` | both | The governor settings. The governor feature flag is read too, and its reply may arrive after the task has completed. |
| `esc_sensor_config` | tool | The ESC telemetry protocol and ESC type. |
| `smartfuel_config` | both | The SmartFuel settings, from MSP API 12.0.9. On an older or still unknown version it completes without a read. |
| `name` | both | The craft name (`session.modelName`). |
| `model_params_sync` | widget | Reads the pilot configuration and keeps it in `session.pilotConfig` for `model_name_sync`. When *Synchronize Model Parameters* is on, writes the three model parameters onto the radio model: a timer's start value or a global variable in flight mode 0. |
| `model_name_sync` | widget | Renames the radio model to the craft name and puts the model's own name back when the link goes. Whether to rename is the flight controller's `MODEL_SET_NAME` flag (MSP API 12.09 and later), or the radio's *Synchronize Model Name* setting where there is no flag. |
| `function_script` | widget | Adds an always-on special function that runs `rfsbg` when the model has none, an empty slot exists, and no competing decoder such as `rf2bg` is enabled. It reads eight of the 64 slots per wakeup, reads nothing from the flight controller, and the entry takes effect the next time the model is loaded. |

The last three are `widget` because they change the pilot's model. That is background work that
belongs to whatever runs during flight. If they ran in both contexts, the tool and the widgets
would each attempt the same rename from Lua states that cannot see each other.

Both widgets show the chain's progress through `Events.getOnconnectProgress()`. The dashboard
also names the task that is still running, through `Events.getOnconnectPendingTaskName()`. A
reboot of the flight controller that is too short to bring the link down does not re-run the
chain on its own. `Events.rerunOnconnect()` resets this runner only.

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
| `flight_log` | When the flight log is on and the flight lasted at least the minimum duration (30 s by default), writes its line to the card and counts a use of the selected battery, once per battery per connection. It is near the front because a pack unplugged soon after the disarm drops `session.flightlog`. |
| `flight_stats` | Reads the board's flight count and total flight time again. |
| `dataflash_summary` | Reads the blackbox flash state again. |
| `tune_history` | Marks the flight's Tune Advisor numbers as owed. It completes in the same call, so it never holds up the chain. |

## The continuous job: `telemetry_bg`

`tasks/events/telemetry_bg/tasks.lua` is not a runner. Its `wakeup` runs on every eligible pass
(see step 4 above) and never completes. On its first three passes it loads one module each, so no
single pass loads all three. After that, each pass runs them in this order:

| Module | What it does |
| --- | --- |
| `drain.lua` | Takes the flight controller's custom telemetry frames off the CRSF link and publishes the sensors they carry. Per pass it takes at most 15 frames and fully decodes the newest 4. |
| `smart.lua` | Updates the SmartFuel values in the session at most once a second, from the flight controller's own fuel value or from a local estimate, with the reserve applied. It skips the dashboard's `carry` passes. |
| `adjustments.lua` | Announces an in-flight adjustment (the function and its new value) once the value has settled, when the adjustment announcements are switched on. It reads what the drain has just published. `adjustment_words.lua` beside it supplies the spoken names. |

`tasks.lua` also sets `session.telemetryFrameAt` whenever frames arrived on this pass or the
background function script is decoding them.

When the background function script (`rfsbg.lua`) is decoding for the whole radio, `drain.lua`
and `adjustments.lua` step aside together, so sensors are not published twice and adjustments are
not announced twice. The script signals that through a counter it advances when it takes frames;
when the counter has not moved for 1 s, both take over again. `smart.lua` keeps running because
its state is per Lua state.

## Not a runner: the Tune Advisor capture

`tune_history` marks the flight as owed on the disarm, and so does a kept flight that turns out to
have ended during a link loss. Five seconds later the runtime loads
`tasks/events/tune_capture.lua`, so that the disarm chain has the link to itself first. The
capture needs MSP API 12.10 or later and a known MCU UID. It reads the three axes with 2 s between
the requests, saves them on the radio, then clears the flight controller and reads the tuning
context that goes with the saved flight. A failed save does not clear the flight controller.
Arming stops a capture in progress. The module is released when nothing is left to do. It runs in
the widget context only and skips the dashboard's `carry` passes.

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

## Other background work

These run on the same hosts but are not part of `tasks/events/`:

- **The MSP runtime** (`tasks/msp/runtime.lua`) reads the API version, the flight controller
  version and the MCU UID by itself, works through the MSP queue, and empties the queue while the
  craft is armed.
- **The background function script** (`src/functions/rfsbg.lua`, installed as
  `SCRIPTS/FUNCTIONS/rfsbg.lua`) decodes custom telemetry for the whole radio. See
  [Background decoder](../reference/background-decoder.md).
- **Announcements** (`lib/audio.lua`) run from the dashboard and the tool. See
  [Audio announcements](audio-announcements.md).
- **The card log** (`lib/log_sink.lua`) is flushed from the widgets, the tool and the background
  function script.
- **What these tasks log**, at which level and under which tag, is in
  [Collecting logs](../troubleshooting/collecting-logs.md#reading-a-dashboard-log).

## Related

- [Connection status](../reference/connection-status.md)
- [Flight statistics](../reference/flight-statistics.md)
- [Background decoder](../reference/background-decoder.md)
- [Saving](../reference/saving.md)
