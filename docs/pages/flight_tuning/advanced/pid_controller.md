---
title: PID Controller
sidebar_label: PID Controller
sidebar_position: 20
---

# PID Controller

Sets how the flight controller's I-term behaves: how fast the accumulated error decays on the ground and in flight, how far it may grow, and where I-term accumulation is held back during fast stick movements. The settings belong to the active PID profile, whose number the page title shows.

## Where to find it

*Configuration* → *Flight Tuning* → *Advanced* → *PID Controller*

Read-only while the model is armed.

## Settings

| Setting | What it does |
| --- | --- |
| Ground Error Decay | Time constant for the decay of the accumulated error while the helicopter is on the ground, so it does not tip over before take-off. 0.0 to 25.0 s, default 2.5 s; 0 leaves the ground phase to the in-flight decay. |
| Inflight Error Decay (Time / Limit) | Time is the time constant of the decay in flight, 0.0 to 25.0 s, default 25.0 s; 0 switches it off. Limit caps how fast the decay may remove the error, 0 to 250, default 12; 0 removes the cap. |
| Error Decay Stick Gain | *MSP API 12.10 and later.* Makes the roll and pitch error decay faster the further the cyclic stick is deflected, on the ground and in flight, so the I-term does not wind up while the stick is held against a helicopter that cannot follow, for example on a slope take-off. 0 to 250, default 0 (off). |
| Master Gain (Cyclic / Yaw) | *Firmware carrying rotorflight-firmware#538.* It did not change the MSP API version, so the row is shown when the flight controller's PID profile carries the two gains, not by version; a 12.10 firmware without them shows no row. Cyclic scales the roll and pitch P, I, D and Offset gains together; Yaw scales the tail P, I and D gains together. The ratios between the gains, and the tail CW/CCW stop gain balance, are kept. Feedforward, Boost and the precompensations are not scaled, so the stick response stays as tuned. 25 to 200 %, default 100 %. |
| Error limit (R / P / Y) | Angle limit for the I-term on roll, pitch and yaw. 0 to 180°, defaults 45°, 45°, 60°. |
| HSI Offset limit (R / P) | Angle limit for the High Speed Integral (O-term) on roll and pitch. 0 to 180°, default 90°. |
| Error rotation | *MSP API 12.08 only.* Lets the accumulated error be shared between the axes. |
| I-term relax | Off, RP or RPY: the axes on which I-term accumulation is limited during fast stick movements, which reduces bounce-back after them. Default RPY. |
| Cut-off point (R / P / Y) | Cut-off frequency of the I-term relax on each axis. 1 to 100 Hz, default 10 Hz. |

## Notes

- Save writes the whole PID profile and then stores it on the flight controller. PID Bandwidth, Autolevel, Main Rotor and Tail Rotor write the same profile; a save there writes back the Error Decay Stick Gain and Master Gains it read and changes nothing.
- The flight controller applies Error Decay Stick Gain in its default PID mode (`pid_mode = 3`) only. The CLI name of the setting is `error_decay_gain_cyclic`.
- A master gain changed in flight, with the Cyclic or Yaw Master Gain adjustment function, does not disturb the trim already held by I and Offset; only how fast they build up changes. The CLI names are `cyclic_master_gain` and `yaw_master_gain`.

## Related

- [Rotorflight documentation: Profiles tab](https://doc.rotorflight.org/configurator/tabs/profiles/)

*Documented against RFSuite 0.1.7.*
