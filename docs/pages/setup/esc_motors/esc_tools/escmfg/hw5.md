---
title: Hobbywing V5 Configurator
sidebar_label: Hobbywing V5
sidebar_position: 50
---

# Hobbywing V5 Configurator

Reads the parameter block out of a Hobbywing V5 ESC and writes it back, so the ESC can be set
up from the radio instead of from a computer. The controls follow the ESC that answers: the
hardware version it reports decides which of these settings it carries and what each of them
offers, and a setting the connected ESC does not have is not shown.

## Where to find it

*Configuration* → *Setup* → *ESC & Motors* → *ESC Tools* → *Hobbywing V5*

Lit only while the flight controller reports this ESC telemetry protocol. Read-only while
the model is armed.

## Settings

Option names are shown in the radio's language; maker abbreviations such as CW/CCW and BEC remain in English as in the maker's software.

The page opens on the ESC's model, firmware and hardware version. *Section* switches between
two groups of settings.

| Setting | What it does |
| --- | --- |
| Section | *Basic* or *Advanced*. Switching it rebuilds the list below; nothing is read from the ESC again. |

### Basic

| Setting | What it does |
| --- | --- |
| Flight Mode | The ESC's operating mode: *Fixed-wing*, *Heli (Linear Throttle)*, *Heli (Elf Gov)* or *Heli (Store Gov)*. Not shown on a model whose parameter block does not carry it. |
| Rotation | Which way the motor turns, *CW* or *CCW*. On some models the same control offers *Forward*, *Reverse*, *4D* and *4D Reverse* instead. |
| BEC Voltage | The BEC output, 5.0 V to 8.4 V in 0.1 V steps. Other models offer 5.4 V to 8.4 V, 5.0 V to 12.0 V, or only 6.0 V, 7.4 V and 8.4 V. Not shown on an opto model, which has no BEC. |
| Lipo Cells | The pack's cell count. Every list starts with an automatic entry that leaves the count to the ESC; the fixed counts follow the model -- 3S to 14S on most, elsewhere 3S to 8S, the even counts 6S to 14S, or 2S to 4S. |
| Cutoff Type | *Soft Cutoff* or *Hard Cutoff*. |
| Cutoff Voltage | The per-cell cutoff: *Disabled*, or 2.8 V to 3.8 V in 0.1 V steps. Some models start at 2.5 V instead. |

### Advanced

| Setting | What it does |
| --- | --- |
| Governor P Gain | 0 to 9. Not shown on a model whose parameter block does not carry it. |
| Governor I Gain | 0 to 9. Not shown on a model whose parameter block does not carry it. |
| Startup Time | 4 s to 25 s, in 1 s steps. Not shown on a model whose parameter block does not carry it. |
| Auto Restart Time | 0 s to 90 s, in 1 s steps. Not shown on a model whose parameter block does not carry it. |
| Restart Time | *1s*, *1.5s*, *2s*, *2.5s* or *3s*. Not shown on a model whose parameter block does not carry it. |
| Motor Timing | Commutation timing, 0 deg to 30 deg in 1 deg steps. |
| Startup Power | 1 to 7, where 1 pushes least. |
| Active Freewheel | *Enabled* or *Disabled*. |
| Response Time | 1 to 10. Carried by only a few models, and not shown on the others. |
| Brake Type | *Disabled*, *Normal*, *Proportional* or *Reverse*. A model may offer only *Disabled*, *Normal* and *Reverse*, or only *Disabled* and *Normal*. Not shown on a model whose parameter block does not carry it. |
| Brake Force | 0 % to 100 %, in 1 % steps. Not shown on a model whose parameter block does not carry it. |

## Notes

- The page opens behind a safety warning: remove the main and tail blades before configuring
  the ESC. The settings appear once that notice is dismissed.
- Saving writes the whole parameter block to the ESC, not only the settings that were
  changed. A setting the page does not offer is written back as the byte it was read from, so
  a Save with nothing edited changes nothing in the ESC.
- After a save the page reads the ESC again on its own. The flight controller turns that first
  read down until it has re-cached the parameters from the ESC, so it is retried: a short wait
  after a save is normal, and a further save is not accepted until that read has come back.
- The ESC is read when the page opens. Switching *Section* does not read it again.
- An unsaved edit is marked below the list, and is lost if the page is left without saving.

## Related

- [Rotorflight documentation](https://doc.rotorflight.org/)
- [Hobbywing](https://www.hobbywing.com/) -- what each of these settings does inside the ESC,
  and the manual for the model in question.

*Documented against RFSuite 0.1.7.*
