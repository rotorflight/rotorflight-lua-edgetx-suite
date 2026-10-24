---
title: ELRS Link
sidebar_label: ELRS Link
sidebar_position: 30
---

# ELRS Link

The transmitter module and the flight controller each hold their own idea of how fast the link
runs and how much of it is telemetry, and nothing makes the two agree by itself. This page reads
both and, on request, writes one side to match the other.

Module parameter reads share one bounded, read-only provider with the dashboard standby screen
and audio alerts. This prevents readers from consuming each other's CRSF replies; diagnostics
still owns its existing confirmation, arming, and write gates.

## Where to find it

*Tools* → *Diagnostics* → *ELRS Link*

The menu entry is locked while the model is armed. The page needs a connected model on CRSF
telemetry; without one it says so and reads nothing.

A page that was already open when the model was armed stays open — the lock is on entering the
entry, not on leaving the page. While the model is armed the tool runs none of the page's work, the
Status row reads *Unavailable while armed* and the buttons do nothing; see *Settings* below.

## What it shows

| Row | What it is |
| --- | --- |
| Status | What the page is doing, or what it last did |
| Rotorflight | The flight controller's telemetry mode, link rate and link ratio, as they are stored on the board |
| ELRS Module | The packet rate and telemetry ratio the transmitter module is set to |
| TX Power | The module's *Max Power* and whether its *Dynamic* power is on (*dynamic*) or off (*fixed*). Read only. |
| Action | Which of the three buttons the last run was started with |

Opening the page reads the flight controller and then asks the transmitter module for its
parameters. The three buttons become available once that has finished.

The *TX Power* row is what the TX power alert under *Settings* → *Audio* → *Events* → *Link*
measures against: the transmitter's power as a share of *Max Power*, and only while dynamic power
is on. ExpressLRS registers both fields in its *TX Power* folder after *Packet Rate* and
*Telem Ratio*, so the module's parameters are read up to them, a few fields further than the rate
and ratio alone need. A part the module does not give reads *?*: a module without the fields, and
a dual-band module built for the CE domain, whose *Max Power* labels are pairs, one limit per band,
and do not say which band applies. To change either value, use the module's own ExpressLRS script.
The packet rate also sets the link's **sensitivity floor**: the weakest signal, in dBm, ExpressLRS
specifies its receiver to decode at that rate -- about -105 dBm at 500 Hz LoRa, down to -123 dBm at
25 Hz. The RSSI and Downlink alerts under *Settings* → *Audio* → *Events* → *Link Quality* speak a
signal's headroom above that floor, so a faster rate gives the same signal less headroom (see
[Audio Events](../../../audio/events.md)).

## Settings

| Setting | What it does |
| --- | --- |
| Probe | Reads both sides again. Writes nothing. |
| RF -> ELRS | Sets the module's packet rate and telemetry ratio to the flight controller's link rate and ratio. |
| ELRS -> RF | Sets the flight controller's telemetry mode to *Custom* with the module's rate and ratio, and saves it to the board. |

Both write buttons ask first, and the question quotes the two sides as the rows above show them,
i.e. as the last probe read them.
Answering no writes nothing. Where the radio cannot put the question up, nothing is written either
and the Status row says so.

Neither sync writes while the model is armed, and a yes does not outlive an arming. Pressing a
sync while armed puts no question up and sends nothing; the state is read again when the question
is answered, so arming the model while the question stands cancels the write. A press is not the
write — the module is read parameter by parameter first and the writes follow over the next
several seconds — so a transfer can still be running when the model is armed. It does not resume
when the model is disarmed: it stops there, sends nothing more, and the Status row reads
*Stopped: model was armed* — also when the arming cleared a write to the flight controller that
was waiting to be sent. A write that had already left before the arming is not undone, so run the
sync again. *Probe* only reads, but it too does nothing while the model is armed, and a probe that
had already started its walk when the model was armed stops the same way instead of finishing on half a walk;
press *Probe* again.

The Status row reads *Unavailable while armed* for as long as the model is armed, and shows what
the page last did again once it is disarmed.

All of this rests on the flight controller's arming flags reaching the radio as telemetry; the
radio sees the model armed only when such a reading says so. Two limits follow from that:

- An arming that begins and ends between two readings of the arming flags is not seen at all, and
  a sync confirmed before it carries on. How often the flags arrive depends on the link's telemetry
  ratio — the setting this page manages — so a low ratio such as 1:64 widens that gap.
- Where the flight controller does not report the arming flags at all, the radio cannot tell
  armed from disarmed. The question is still asked, says so in its last line, and answering yes
  writes; nothing then stops a sync at an arming. A save elsewhere in the suite asks the same
  question for the same reason.

Where the arming state cannot be read because a part of the suite itself is missing, nothing is
written and the Status row reads *Arming state unknown*.

## Notes

The module the page writes to is the **ExpressLRS transmitter module**: it is identified by the
serial number ExpressLRS reports in its device information, or failing that by its name, and it
has to answer on the CRSF transmitter address as well. Another CRSF module in the bay answers the
same query and is ignored; the log names the device that was turned away.

*RF -> ELRS* changes a live radio link. The module applies the new packet rate immediately, so run
it with the model on the bench rather than in the air.

*ELRS -> RF* writes the flight controller's configuration and commits it to permanent storage, the
same as a save on any other page.

The same link task also drives the ExpressLRS cards in the receiver step of the Helicopter
Setup wizard. The wizard runs it under an owner of its own, so a flight controller write still in
flight is dropped when the wizard leaves the card; this page runs it without an owner, and a sync
it has started runs to its end, the permanent save included, as before.

## Related

- [Rotorflight documentation](https://doc.rotorflight.org/) — the `crsf_telemetry_mode`,
  `crsf_telemetry_link_rate` and `crsf_telemetry_link_ratio` settings this page writes.
- [ExpressLRS documentation](https://www.expresslrs.org/) — what packet rate and telemetry ratio
  do to the link.

*Documented against RFSuite 0.1.7.*
