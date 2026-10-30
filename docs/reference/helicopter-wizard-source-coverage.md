---
title: Helicopter wizard source coverage
---

# Helicopter wizard source coverage

The port is compared with Configurator PR 491 at
[`b8f0eca5a73e8ea00a21a8122a8f7029ad705ee7`](https://github.com/rotorflight/rotorflight-configurator/tree/b8f0eca5a73e8ea00a21a8122a8f7029ad705ee7/src/tabs/setup_wizard).
The comparison runs in both directions: source behavior to Lua, then Lua controls,
wire values, failure paths and reactive properties back to the source intention.

The checked-in `bin/wizard/source-map.json` inventories every file in
`src/tabs/setup_wizard/`, plus the directly used shared helpers. Each entry records
its fingerprint, named functions, component properties, event kinds, Lua targets,
contract groups and visual/lifecycle adaptations. `audit_source.py --source <src>`
refuses a changed fingerprint, an unaccounted wizard file, a missing target or a
missing contract. Unrelated features in shared configuration/receiver/motor tabs
are outside this port. This is behavior traceability, **not a claim of 100% JavaScript
statement or branch coverage**.

`source_contracts.mjs` executes the pinned pure JavaScript helpers to generate
130 independent golden vectors in `source_vectors.lua`. Normal verification reads
those vectors; it needs neither the Configurator checkout nor a network connection.
They cover movement thresholds, switch bands, calibration signs/clamps, mapped and
stepped gain windows, collective units, style bytes and rounding. Regeneration is a
maintainer action against an explicit source snapshot, never a package build input.

## The 19 steps

Contract prefixes below refer to `bin/wizard/contracts.lua`. All step definitions,
including their conditional cards, also pass through the geometry/reactive-property
sweep in `verify.lua` at 480×272, 480×320 and 800×480.
The same cards are retained after navigation, cleanup, reload and teardown to
exercise the native LVGL sweep before a staged replacement is published. Rate
draft discard is also checked with the old curve and choices still present.

| # | Suite step | Read/write/check coverage | Contract prefix |
| --- | --- | --- | --- |
| 1 | Sensors | Accelerometer present/absent; preparation gate; calibration ACK and status completion; signed alignment; start/query, uncalibrated, timeout, rejection and successful auto-align; pending restart; physical orientation answer. | `S01`, `CORE` |
| 2 | Receiver | Receiver UART selection is intentionally omitted on the established radio/MSP link; generic port helpers retain their independent tests for other steps. RX feature group; explicit serial protocol IDs; USB guidance and a radio-side wiring-trial guard; all four channel presets; fresh pre-click FC snapshots; collective-first detection and exclusion of previously found channels; raw mapped bars; throttle-switch travel including its starting endpoint, margins, defaults, missing input and arming threshold; named input directions and raw CH numbers. | `S02`, `CORE` |
| 3 | Modes | Only advertised ARM/RESCUE/TRAINER; existing/free/full slots; ≥300 µs clear movement, 400 ms settle and detection timeout; indexed write and cleared linkage; remove; ARM switch feedback versus actual STATUS flags for other modes. | `S03` |
| 4 | Profiles & gain | Existing mode/channel readback; PID+rates, PID-only and None; detection thresholds and accumulated peaks; clustered positions and full travel; paired slot capacity; live profile/knob/button feedback; exact 83/84 gain functions and neutral windows; channel-use plan including channels beyond CH8; EdgeTX trim-mix instructions. | `S04`, `SOURCE` |
| 5 | Rates | Profiles actually selected by the adjustment range, or the active profile; individual reads on entry; matching preset/custom state; three-position suggestion; only chosen profiles written; collective preserved; original selection restored; chosen state cleared after save. | `S05`, `SOURCE` |
| 6 | Swashplate | Swash type, rotor direction and tail mode; Direct roles, common layouts, front/rear reference variants and tail servo number; signed yaw reset; TTA on every PID profile only when servo/motor kind changes; compatible BOTH pin state; unsupported pin command and refused switch. | `S06`, `CORE`, `VISUAL` |
| 7 | Servo type | Relevant PWM groups and bus exclusion; unplugged requirement; per-group types (swash 50/165/333 Hz at 1520 µs and 560 Hz at 760 µs, tail 200 Hz at 1520 µs and 333/560 Hz at 760 µs) where the Configurator offers 50/333/560 Hz to both; centre/travel/scale reset only across pulse bands; a trimmed centre keeps its type; restart on frame-rate change; servos matching no type, or differing within a group, read as no type; geometry correction on the same card; a picture per type and a cached live pulse reference otherwise, with a pulse-limit hint. | `S07`, `CORE`, `VISUAL` |
| 8 | Governor | Feature bit overrides a latent stored mode; mode/type writes; Switch only with headspeed control and reset when leaving it; restart; fast-RPM warning distinguishes RPM input/bidirectional DShot from serial ESC telemetry. Suite additions: FC headspeed per configured PID profile, exact RPM, edited-profile saves and restoration, three ramp times in seconds, read-only preset/CUSTOM filter check and missing-source warning even with governor Off. | `S08` |
| 9 | Motor & ESC | Versioned sparse protocol IDs, including API 12.09/12.10 Disabled; motor poles; main and tail gearing; motor-tail variant; Castle protocol/feature consistency. | `S09-S12` |
| 10 | Connection gate | Batch initial restart; unplugged confirmation before it; same visit/FC after reconnect; arming lock reasserted; actual main/tail outputs and required PWM servos; powered/connected/blades confirmations. | `S10`, lifecycle sweep |
| 11 | ESC telemetry | Battery connection with main and tail blades removed; versioned protocols; Off frees ESC function; Castle throttle-wire telemetry; free/current port; saved-config trial eligibility; successful combination kept live, cancel restores prior flags, Save & reboot persists it; V/A/temperature/RPM and explicit receiving/missing feedback. | `S11`, `S09-S12`, `CORE` |
| 12 | ESC & spin | Unplug battery first for PWM; keep connected for other protocols; PWM-only high→low→done; actual high/low output gates; cancel releases high output; fresh calibration on revisit; live output marker; main spin guards, 5–50%, default 10%, 250 ms refresh, changed power and release; physical direction answer. | `S12`, `CORE` |
| 13 | Servos | Centre all relevant servos; +20° test toggles; reverse preserves other flag bits and invalidates confirmation; affirmative answer returns to centre; mid pulse, band centre and >100 µs mechanics warning; actual output feedback. | `S13` |
| 14 | Control directions | Passthrough for stabilized roll/pitch/collective; live RC command bars; visible expected movement and rear/side viewing references; signed rate reversal invalidates physical confirmation; no automatic claim about mechanical response. | `S14-S15`, `VISUAL` |
| 15 | Level | Hold three axes at zero; trims are roll, pitch and collective, not servo numbers; ±100% in 0.1% units; individual numeric zero or Reset all; physical level confirmation. | `S14-S15` |
| 16 | Pitch | Toggle 9° on one axis, others zero; measurement only while held; 9/measured correction from the measured axis with signs preserved on both cyclic axes; 20–200% clamp; cyclic/collective 0–20°, total 0–36°; full-stick 0–25° on all supported rate profiles; unsupported types skipped; selection restored. | `S16`, `SOURCE` |
| 17 | Tail | Servo zero/passthrough/toggle holds; live yaw; centre ±25°; signed calibration 10–500%; ±22.5°/±60° and 24° per 1000 raw units; CW/CCW limits; servo confirmations; motor/bidirectional hold variants, idle/use-current-power and release. | `S17`, `CORE` |
| 18 | Gyro | All overrides released; pilot checks opposing correction; failure returns to orientation; motor tail omits servo yaw check; answers required again on revisit. No animation pretends to prove gyro correction. | `S18-S19`, lifecycle sweep |
| 19 | Finish | Readable swash/direction/tail, collective and cyclic limits, throttle protocol, Castle/serial telemetry, governor feature/mode/type, RPM and ARM assignment; final confirmation; save/cleanup and arming availability restored on exit. | `S18-S19`, lifecycle sweep |

## Shared behavior and deliberate adaptations

The governor targets, ramp editors and filter-signal warning are additions beyond
the pinned Configurator wizard. `source-map.json` explicitly inventories their four
new writes under `additions`; `audit_source.py` validates each against the Suite API
and implementation. The [governor write audit](helicopter-wizard-msp.md#governor-write-audit)
also distinguishes changed fields from preserved full-record payload fields.
`S08.headspeed-and-ramps`, `S08.headspeed-scope-and-help` and
`S08.rpm-filter-signal` cover individual readback, profile bounds/fallback,
selection/restore, exact wire records, discard/failure, shared units/limits,
translated help, all governor modes and all three CUSTOM notch axes.

- Browser promises/timers become bounded queue jobs. API loading, decoding,
  indexed writes, snapshots and profile transactions resume across calls.
- STATUS preempts long jobs and running detection. Expiry is checked **before**
  waiting for an MSP reply, releases holds and disables editing. Initial loading
  finishes with a fresh lock readback. A stale or lost lock cannot be bypassed by
  an ACK or a busy transaction.
- Timed support is proved separately for commands 193 and 191 using OFF-only
  valid/invalid-length parser checks. Command 196 does not prove mixer support.
  The source's version-only assumption is intentionally corrected. API 12.10
  without firmware PR 541 uses three-byte permanent holds with explicit warning
  and cleanup.
- Every task/step exit drops unsent keepalives and releases held outputs.
  Wiring STOP belongs to the cleanup queue, so it survives page teardown.
  Errors block EEPROM/advance; profile transactions attempt to restore selection.
- Suite menu entries support direct entry and the complete 19-step sequence.
  Entry and exit resolve pending changes, release overrides and ask for the
  relevant physical preparation before entering automatic holds. Visit-local
  step state survives an expected reboot. It is not persisted across a new visit
  or transferred to another FC. RTN/EXIT uses the same Back route.
- Receiver wiring detection is redirected to USB Configurator. Firmware
  `rxSerialTrialApplyCombo` closes/reinitializes the receiver UART, which carries
  this wizard's MSP link. A radio-side guard sends no START, even on compatible
  firmware. The wizard therefore requires an already working receiver/MSP link.
  ESC wiring detection and board alignment use independent facilities.
- ARM is detected on AUX1 only, where the receiver step maps the arm switch; the
  Configurator searches every AUX. ExpressLRS 4.x outputs its arm flag on CH14
  (AUX9 on Rotorflight) as well, so a free search sees two equal movements.
  RESCUE and TRAINER keep the free search.
- AUX wire indexes remain identical. Displayed receiver channel numbers follow
  RX_MAP (firmware `rx.c/readRxChannels`, `MSP_RC` versus `MSP_RX_CHANNELS`). For
  example, an ELRS preset can make AUX1 correspond to transmitter CH5; it must
  not be labelled CH6 simply because five control functions precede it internally.
- Advanced web-tab shortcuts become task help and the Suite menu routes documented
  on the page. Ethos screenshots become explicit EdgeTX MAX/trim mix instructions.
  Decorative receiver/ESC/gear artwork can become labelled fields; it is not
  required to copy browser SVGs onto the radio.
- Motor tests additionally stop after 15 seconds. Tail idle is capped at 25.5%,
  the U8 protocol ceiling, rather than offering a value that wraps on the wire.
- Mechanical, servo-arm, tail and gyro drawings are labelled references. Blade
  pitch uses a blade cross-section, gauge and horizontal datum; the swash uses a
  closed rim, linkages and a neutral plane. Nick and roll gyro checks have distinct
  side/rear views. Board verification follows fresh cached MSP roll/pitch; stale
  data hides the model. Stick/output markers and assigned mode cues follow cached
  MSP values; layout, rotation arrow, rate curve and pulse train follow settings.
  No scene is rebuilt on an MSP reply. No canvas or image rotation is used.

The telemetry transport adaptation is covered separately: all 42 adjustment records
and PWM/bus servo records are indexed reads, with raw-to-packed mapping, atomic
publication, progress, malformed-record failure and long-save STATUS preemption.
Every step is also entered through its Suite entry with the shared lazy page.
Direct-step preparation and completion use explicit fixture answers. Per-FC
history covers all bits, isolated FCs, validated completion, recheck hints, advisory
prerequisites, explicit reset, bounded reads, interrupted writes and visible
retry/continue/cancel failure paths. No history bit can supply a safety answer. Packed telemetry feedback
covers absence, stale values, error priority and the independence of MSP locking.
The complete-setup path retains all 19 steps, with a deliberate deviation from
PR 491: ESC telemetry is step 11, before the spin test at step 12. The source map
records the swap as an adaptation; `CORE.esc-before-spin` checks the order,
positional menu IDs, labels and polling. History remains keyed by index without migration. An unnumbered
radio-model preparation precedes each new setup visit: template/manual selection
and current-model confirmation must both be supplied. It loads no step definition
and enters no holds; a new visit always asks again. The reset page omits this gate.

The desktop renderer now honors native theme palette colors for filled rectangles.
Earlier previews masked a dark-background contrast defect; source-level color
checks and light-background renders now cover it. Desktop rendering still cannot
prove native font sizes, touch behavior or actual mechanics.

## Verification and limits

Run:

```text
lua5.3 bin/wizard/verify.lua
lua5.3 bin/wizard/verify.lua --locale de
python bin/wizard/audit_source.py
python bin/wizard/verify_negative.py --lua lua5.3
```

The negative controls restore oversized USB bulk reads, wrong FBUS ID, false-positive
mode feedback and stale status hidden behind a busy request, and also inject a
premature history write before validation. Further mutations restore discarded pitch drafts,
lose a dirty step commit on Back, reuse the earlier blade confirmation, share the
servo timeout capability with the mixer, and unlock arming after failed OFF. Each
must fail its named assertion, alongside a passing positive control in the same run.
These are additional checks; assertions and budget thresholds are not weakened.

The per-call instruction probe covers step definitions, view preparation, scene
slices, reactive sweeps, API decode, save callbacks and real page wakeup/build.
A second complete traversal uses the rendered page's own choice and navigation
callbacks, measuring wakeup, scene assembly and every reactive getter together
in each frame under the same 14,000-instruction test ceiling.
The Suite's package, syntax, translation, accounting and host page-budget checks
remain separate required checks.

[480×272 live-command example](../images/helicopter_setup/motion-command-small.gif) ·
[800×480 live-command example](../images/helicopter_setup/motion-command-large.gif)

[Rate selection](../images/helicopter_setup/motion-rates-small.gif) ·
[Servo pulse selection](../images/helicopter_setup/motion-pulses-small.gif) ·
[Layout selection](../images/helicopter_setup/motion-geometry-small.gif) ·
[Switch hint](../images/helicopter_setup/motion-switch-small.gif)

These previews resolve the **same Lua scene** at explicit example inputs. They use
desktop fonts and do not establish radio rendering, touch usability, telemetry
latency or mechanical correctness. Native EdgeTX 2.12 and isolated FC acceptance
remain required before flight. No EdgeTX or flight-controller simulator is needed
for these checks.
