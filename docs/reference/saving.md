---
title: Saving configuration
sidebar_label: Saving configuration
---

# Saving configuration

The **Save** action on a configuration page writes the values that page has read and edited.
A page can display initial values before the flight controller has answered; those values are
not a configuration that is ready to save.

On the pages listed below, Save requires a successful read of every record in the page load.
If loading is still running, failed, or returned data the parser rejected, Save reports **Not
saved** and explains that the complete configuration must be read first. It queues neither the
page writes nor the host EEPROM commit. Wait for loading to finish, or use **Reload** to try
again. A reload invalidates the previous completion until its own reads succeed.

The check also runs after a save confirmation, immediately before the deferred save executes.
A page change cancels that pending save and reports **Not saved**, asking you to return to the
page and save again. Arming continues to prevent FC writes. Both checks of the arming state use
the configured warning style: the notice, or the transient banner when the armed warning is
disabled. Local radio settings do not need an FC read and keep their existing save behaviour.

## Pages covered

- Flight Tuning: PIDs, Rates and Governor.
- Flight Tuning > Advanced: Autolevel, Filters, Main Rotor, PID Bandwidth, PID Controller,
  Rescue, Tail Rotor, and all three Rates Advanced pages.
- Setup > Alignment.
- Setup > Governor: General, Time, Filters and Curves.
- Setup > ESC/Motors: RPM, Throttle and Telemetry.
- Setup > Controls: Modes, Failsafe, Stats, both Beepers pages, and Blackbox Configuration
  and Logging.
- Setup > Power: Battery and Sources.

A chained load must finish successfully even if an earlier error allowed the page to continue
reading other records. Previously read session values alone do not grant permission to save.
The page's existing parameter help and save/reboot sequence are otherwise unchanged.

## ESC Configurator pages

*Setup* > *ESC & Motors* > *ESC Tools* opens one page per ESC firmware. These pages do not use
the shared Save action above; each writes the ESC's whole parameter block over MSP, not the
settings that were changed. Two rules follow from that.

A page reads the block only if it is that ESC's. The flight controller names the ESC family it
detected in the first byte of the block, and the *BLHeli_S*, *Bluejay*, *Hobbywing V5*, *OMP*,
*Scorpion*, *XDFly*, *YGE* and *ZTW* pages refuse a reply from another family rather than
decoding it with their own field list. BLHeli_S and Bluejay report the same family, so those
two decide on the ESC's main revision instead. A refused read leaves the page on its own
initial values; use *Reload* after selecting the page for the ESC that is actually fitted.

On every ESC Configurator page, Save is refused until the read of the current visit has
succeeded, and reports the reason. A block that was never read cannot be written back: every
setting the page does not itself show would go to the ESC as zero. The page is kept between
visits, so a block read on an earlier one does not authorise a save on a later one: a read that
fails -- a different ESC, another *ESC Target*, an ESC that did not answer -- cannot be saved
from what the previous one sent. The settings on screen, the ESC's name and its firmware go back
to the page's own initial ones when the page is left as well, so a visit whose read fails does not
show the previous ESC's either.

The ESC Tools grid lights AM32, BLHeli_S and Bluejay together, because what lights them is the
ESC telemetry protocol, which all three share. Which of the three pages fits is still the
pilot's choice; on the BLHeli_S and Bluejay pages these checks make a wrong choice visible
instead of writing it to the ESC.

## Scope

The shared check protects the Save action from absent page data. It does not change wire
encodings, validate every field inside an accepted parser result, or alter the transport policy
for writes already queued. ESC encoding and telemetry-catalog issues have separate fixes.

Checked against RFSuite 0.1.7. Related: [issue 273](https://github.com/rotorflight/rotorflight-lua-edgetx-suite/issues/273).
