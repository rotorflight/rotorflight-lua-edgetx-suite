-- Manifest for ondisarm tasks (ordered)
--
-- flight_log runs FIRST on purpose. The runner takes the first task in this list that has not
-- finished and stays on it until it reports complete or gives up, and both tasks below put a
-- request on the MSP queue -- so a flight controller that stops answering holds the sequence
-- here for DEFAULT_TASK_TIMEOUT_SECONDS and its retries. `session.flightlog` is dropped the
-- moment the link goes down with the craft disarmed (tasks/events/runtime.lua, publishConnected),
-- so a pilot who unplugs the pack shortly after disarming would lose the record while it waited
-- its turn.
-- This task needs nothing but session memory and writes the card immediately.
--
-- flight_record runs ahead of all three. It closes the record of the flight that has just ended,
-- moving it to `last`, so every task behind it reads a finished flight instead of one still open.
-- It touches nothing but session memory either, so it cannot hold the sequence up.
--
-- tune_history runs LAST, and only marks the flight's Tune Advisor numbers as owed: it reports
-- itself complete in the call that marks them, so it never holds the sequence either. The
-- capture itself -- three paced reads, the save, the clear -- is driven by the event runtime
-- from five seconds after the disarm, after the reads above have had the link to themselves
-- (tasks/events/tune_capture.lua says why it cannot be a task that waits here).
return {
  { name = "flight_record", context = "widget" },
  { name = "flight_log", context = "widget" },
  { name = "flight_stats", context = "widget" },
  { name = "dataflash_summary", context = "widget" },
  { name = "tune_history", context = "widget" },
}
