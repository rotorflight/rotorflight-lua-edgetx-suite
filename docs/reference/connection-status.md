---
title: The connection status button
sidebar_label: Connection status
---

# The connection status button

The tool's header carries a button that says what the connection is doing. Its symbol is the
state at a glance; pressing it opens the detail, including what is connected once everything
has been read.

It exists because the start screen leaves before the connection is finished. The suite stops
holding it as soon as the flight controller has answered two questions -- its MSP API version
and its unique id -- or the wait runs out, and the compile pass has walked the installed tree;
the rest of the reading then carries on behind the menu. Without the button there is nothing on
screen that separates a flight controller which is still being read from one that never
answered at all.

The button reports; it changes nothing. It does not decide when the start screen leaves, and it
does not decide when a tile becomes usable -- a tile stays greyed out until the flight
controller has answered, exactly as before.

## Where to find it

At the left end of the header's button row, before *Back*. It is on every screen the header is
on -- the main menu, a sub-menu and a page -- because the state matters on a page as much as on
the menu: a save refused because the flight controller stopped answering is read on the page it
was refused on.

It is always pressable, in every state.

## The four states

| Symbol | What is true | What to do |
| --- | --- | --- |
| **A cross** | No telemetry link. The radio is not receiving telemetry from the model. The suite raises the link on the receiver's RSSI, so this is the model being off, out of range, or telemetry being off for it -- it is not yet a statement about the flight controller. | Power the model, and check that telemetry is enabled for it. [No connection to the flight controller](../troubleshooting/no-connection.md) is the order to check things in. |
| **Circling arrows** | Connecting. Either telemetry is arriving and the flight controller has not completed the MSP handshake yet -- the tiles that need it are still greyed out -- or the handshake is through, the tiles are usable, and the connect sequence is reading the configuration. Press the button to see which of the two, and which step. | Give it a few seconds. Opening a page while the sequence runs is fine; the page reads what it needs itself. |
| **A tick** | Connected. Everything is read. | Nothing. |
| **A warning triangle** | Either the handshake failed -- no answer, or a firmware whose MSP API version the suite does not speak (12.09 and 12.10 are the ones it does) -- or the connection finished with one or more connect steps given up on. Press the button for which. | For a failed handshake, the page above is the order to check things in. For a step that was given up on, see below. |

## What pressing it shows

A notice with the state as its title and the detail as its message. It is composed when you
press the button, so it shows the connection as it stood at that moment; close it and press
again for a fresh reading.

| State | The notice says |
| --- | --- |
| Not connected | that the radio is not receiving telemetry from this model; the row above says what to check |
| Connecting -- handshake | that telemetry is arriving and the flight controller has not answered yet |
| Connecting -- connect sequence | the step being read and its number in the sequence, for example *Reading governor configuration (5/10)* |
| Connection error -- handshake | the reason: an unsupported MSP API version, or that telemetry is arriving while the flight controller is not answering |
| Connection error -- after the sequence | how many connect steps were not completed, and the craft name |
| Connected | the craft name, and the Rotorflight and MSP API versions |

A field the flight controller did not supply is left out rather than shown empty, so a
connection that answered only part of the way still reads sensibly.

A board that answers with an MSP API version the suite does not support is refused. That is
different from a board that does not answer. The home screen's notice, the service widget and
the dashboard's standby line name that version. The *Info* page's *Loading failed* notice
names it too when loading times out; its *Supported MSP API* row lists the supported
versions. When the board does not answer, the home screen and the *Info* page ask you to check
`FEATURE_TELEMETRY` and the MSP serial port configuration.

On a fast link the connect sequence can be through before the start screen leaves, so the menu
opens straight on the connected state and the step count is never seen. That is not a fault:
the step count is shown for as long as there is a step still to read.

## When a step did not complete

Each step of the connect sequence is retried and then given up on, and the sequence moves on
either way. So "finished" is not the same as "everything was read", and the button says so: it
shows the warning symbol, and the notice opens with *Connect steps not completed: n*.

What that costs depends on the step. A page reads what it needs when it is opened, so most of
it is made good the moment you go there; what is lost is what only the connect sequence does --
the clock, the craft name and the values the dashboard shows before you touch anything. A
reconnect runs the whole sequence again.

The notice keeps to two lines, so its text never runs down to the button that closes it. That
is why the count takes the first line here and the firmware versions give up theirs, and why the
MSP transport is not shown at all: *System* → *Tools* → *Diagnostics* → *Info* carries the
versions and the transport whatever this notice says.

The log on the card names each step as it finishes, and names the one that was given up on. See
[Collecting logs](../troubleshooting/collecting-logs.md) for switching it on.

## In the rotary quick menu

The header of [the rotary style](../dashboard/quick-menu.md#the-rotary-style) says the same four states in words, from the same
module (`lib/connection_status.lua`): *Not connected*, *Connecting*, *Connection error*, *Connected*. A tap on them shows this notice.

## Related

- [No connection to the flight controller](../troubleshooting/no-connection.md) -- what to check
  when the button stays on the cross or the warning symbol.
- [Collecting logs](../troubleshooting/collecting-logs.md) -- the log the connect sequence
  writes, and what to attach to a report.

*Documented against RFSuite 0.1.7.*
