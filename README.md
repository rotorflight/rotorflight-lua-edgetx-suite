# RFSuite for EdgeTX

[![Website](https://img.shields.io/badge/Website-rotorflight.org-2ea44f)](https://www.rotorflight.org/)
[![Discord](https://img.shields.io/badge/Discord-Join%20Chat-5865F2?logo=discord&logoColor=white)](https://discord.gg/FyfMF4RwSA)
[![License: GPLv3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)

[Rotorflight](https://github.com/rotorflight) is a flight control software suite designed for
single-rotor helicopters. It consists of:

- Rotorflight Flight Controller Firmware
- [Rotorflight Configurator](https://github.com/rotorflight/rotorflight-configurator), for flashing and configuring the flight controller
- [Rotorflight Blackbox Explorer](https://github.com/rotorflight/rotorflight-blackbox), for analyzing blackbox flight logs
- Rotorflight Lua Scripts, for configuring the flight controller using a transmitter running:
  - EdgeTX with LVGL, using RFSuite (this repository)
  - [EdgeTX or OpenTX](https://github.com/rotorflight/rotorflight-lua-scripts), using the classic scripts
  - Ethos

RFSuite configures the flight controller from the transmitter over the model's telemetry link —
no cable, no computer. The same installation also provides dashboard widgets that put flight
controller telemetry on the transmitter's main screens, and voice announcements for arming,
profiles, adjustments and fuel.


## Information

Documentation can be found at [doc.rotorflight.org](https://doc.rotorflight.org/), and tutorials and flight videos
on the [Rotorflight website](https://www.rotorflight.org/).

The page-by-page reference for the tool itself, what each configuration page does, its
settings, and when a page is hidden or read-only, is in [docs/](docs/README.md), and the same
pages are published with search as the [RFSuite documentation site](https://rotorflight.github.io/rotorflight-lua-edgetx-suite/). Every
page also carries a short explanation in the tool, behind the `?` button in its header.


## Requirements

- A colour transmitter running **EdgeTX 2.11 or later**. RFSuite is built on LVGL, which
  EdgeTX exposes to Lua from 2.11 onwards; on an older firmware the tool reports
  `LVGL support required` and stops.
- A **CRSF link** — Crossfire or ELRS. RFSuite carries MSP over CRSF telemetry, and that is
  the only transport it implements. S.Port and F.Port receivers are not supported.
- Rotorflight firmware speaking **MSP API version 12.09 or 12.10** — Rotorflight 4.6 or
  later. A flight controller on an older firmware (Rotorflight 4.5 speaks 12.08) is refused on
  connect with a notice naming its version. Pages that need a newer API than the connected
  flight controller reports are hidden automatically.


## Installation

### Automated Installation (Recommended)

The easiest and recommended way to install or update RFSuite is using the standalone [RFSuite Updater](https://github.com/rotorflight/rotorflight-lua-edgetx-suite-updater) application. It automatically detects your radio's SD card, downloads the latest release in your chosen language, and safely installs all scripts, widgets, and sound packs while preserving your custom settings and user themes.

1. Download the latest version for Windows, macOS, or Linux from the [RFSuite Updater Releases](https://github.com/rotorflight/rotorflight-lua-edgetx-suite-updater/releases).
2. Connect your powered-on transmitter to your computer via USB and select **USB Storage (SD)** on the radio screen.
3. Launch the **RFSuite Updater**, select your release track and language, and click **Install / Update**.
4. Once completed, safely eject the drive and disconnect the USB cable.


### Manual Installation (ZIP Archive)

Alternatively, you can manually download and unpack the release archive:

1. Download the latest release from [GitHub Releases](https://github.com/rotorflight/rotorflight-lua-edgetx-suite/releases/). Releases are published per language — pick `rfsuite-radio-install-v<version>_en.zip` or the `_de` archive. The language is baked into the package, so switching languages later means installing the other archive.
2. The archive holds `SCRIPTS`, `WIDGETS` and `SOUNDS` folders that are unpacked over the root of the transmitter's SD card.

#### USB Method

1. Connect your transmitter to a computer with a USB cable (select **USB Storage (SD)** on the radio)
2. Open the new drive on your computer
3. Unzip the archive and copy its `SCRIPTS`, `WIDGETS` and `SOUNDS` folders to the root of the new drive
4. Eject the drive
5. Unplug the USB cable

#### SD Card Method

1. Power off your transmitter
2. Remove the SD card and plug it into a computer
3. Unzip the archive and copy its `SCRIPTS`, `WIDGETS` and `SOUNDS` folders to the root of the SD card
4. Eject the SD card
5. Reinsert the SD card into the transmitter
6. Power up your transmitter

---

You will know that you've done it correctly when you find `rfsuite.lua` in the
`/SCRIPTS/TOOLS` directory. *RFSuite* now appears in the *Tools* menu of your transmitter, and
*RFSuite* and *RFSuite Service* appear in the widget list when you configure a screen.

To update manually, unpack a newer archive over the existing installation. Your settings, model
preferences and any user dashboard themes live in `/SCRIPTS/RFSUITE/user/`, which the
release archive does not write to. A card from before that folder has its data copied over
on the first start; [Configuration files](docs/reference/configuration-files.md) says what happens.


## Quick start

After installing, put one of the two RFSuite widgets on a screen of each model you fly with
RFSuite. The suite's background work — the link to the flight controller, the custom telemetry
sensors, the connect events and the voice announcements — only runs while the tool is open or
one of the widgets is running. EdgeTX keeps screen layouts per model, so this is done once per
model.

**If you want the dashboard:**

1. In the model's screen setup, add a screen (a full-screen layout suits the dashboard best).
2. Choose **RFSuite** as the widget for it.
3. Optionally pick a theme in the tool under *System* → *Settings* → *Dashboard* → *Theme*.

The dashboard runs the background work itself, also while its screen is not shown. There is
nothing else to set up. Do not add *RFSuite Service* as well: both would run the same background
work, twice.

**If you do not use the dashboard:**

Add **RFSuite Service** instead — this is recommended. Place it in a small zone on a screen you
do not use; it only draws a small status tile. Without it, the link and the announcements stop
as soon as the tool is closed.

After the first install or an update, restart the radio when the suite asks for it; until then
the widgets do not connect. What runs the background work, what the service tile shows and what
to avoid is described in [docs/dashboard/service-widget.md](docs/dashboard/service-widget.md).


## Usage

Start the tool from the *Tools* menu of your transmitter. The home screen shows the connection
state and, once the flight controller answers, the configuration and system sections.

Changes are only written to the flight controller when you explicitly save them. While the
model is armed, RFSuite refuses writes and locks the pages that would perform them; telemetry
keeps running, so the dashboard and the announcements continue to work.

Two widgets come with the installation:

- **RFSuite** — the dashboard. It renders a theme built from live telemetry, and switches
  between separate preflight, inflight and postflight layouts as the flight progresses.
- **RFSuite Service** — a background service. It keeps the link to the flight controller and
  the announcements alive when the configuration tool is not open. It draws nothing worth
  looking at, so it belongs in a small zone on a screen you do not use.


## Features

An overview of every feature, with a link to its page, is on the
[documentation site](https://rotorflight.github.io/rotorflight-lua-edgetx-suite/features/)
and in [docs/features.md](docs/features.md). In short:

* Flight tuning: PIDs, rates, governor, filters, PID controller and bandwidth, autolevel,
  main and tail rotor, rescue, and the advanced rate tables
* Tune Advisor: suggestions for each axis from the flight controller's own rate-flight
  measurements, applied with *Save* and recorded in a change journal on the SD card
* Setup: general configuration, radio configuration, telemetry, accelerometer, board
  alignment with auto-align, ports, GPS, and the model's name and pilot configuration
* Mixer: swash, swash geometry, tail and trims
* Servos: PWM servos and bus servos
* Controls: modes, adjustments, failsafe, beepers, blackbox and flight statistics
* Power: battery, alerts, sources, SmartFuel and per-model preferences
* Governor: general, ramp time, filters and bypass curve
* ESC & Motors: throttle, ESC telemetry with wiring detection, RPM, and ESC configuration for
  AM32, BLHeli_S, Bluejay, Flyrotor, Hobbywing Platinum V5, OMP, Scorpion, XDFly, YGE and
  ZTW, unlocked automatically for the ESC telemetry protocol that the flight controller reports
* Motor Override, for spooling up main and tail motors on the bench behind an explicit disarm
  confirmation, an arming switch check and a deadman timeout
* Dashboard widget with ten shipped themes (among them Urban, Grid and Deck), separate
  preflight, inflight and postflight screens, and user-supplied themes
* Customizable dashboards: choose what each value tile shows before the flight, in flight and
  in the post-flight statistics, bind the full-screen keys per theme, show any of the radio's
  telemetry sensors by name on Urban, Grid and Deck, and set colours and gauge ranges — as
  standard values for every model, or per model
* An event log on the Urban status page: arming, connection, governor and ESC state changes
  with the radio's time
* Dashboard in full screen: a quick menu, a standby screen before the flight controller
  connects, and radio-wide keys
* In-flight tuning overlay (preview feature, off by default) that drives the flight
  controller's adjustment functions from the dashboard
* Diagnostics: flight controller status, RF status, ELRS link, sensor validation, SmartFuel,
  CRSF sensors, System Status, session logs and system information
* Flight Log: one line per flight with its model, pack, armed time and telemetry extremes,
  browsable by flight, model and pack; a battery registry that counts each pack's cycles, the
  pack picked on the dashboard after connecting, and optionally the matching battery profile
  set on the flight controller
* A log browser that reads the transmitter's own telemetry CSV files on the radio and
  plots channels against flight time
* Voice announcements for connect, arming, governor, voltage, profiles, ESC and MCU
  temperature, adjustments, SmartFuel, link quality and rescue, with a Volume page
* Copying and selecting flight and rate profiles
* English and German user interface

## Audio

The release archive installs the announcement pack under `/SOUNDS/rf/`, so no extra copying is
needed. Which events are spoken is configured in the tool under *System* → *Settings* →
*Audio* → *Events*; some announcements are off by default.

To have your model announced by name, place a `.wav` file directly in `/SOUNDS/` on the SD
card, named after the model name reported by the flight controller — or after the transmitter's
model name, which is used when the flight controller has not reported one yet. Spaces may be
replaced by underscores, so both `My Heli.wav` and `My_Heli.wav` are found.


## Model images

The dashboard can show a model image. It is resolved in this order:

1. `/IMAGES/<model name>-<cells>S`, using the model name reported by the flight controller and
   the cell count currently detected — a picture per battery size for the same airframe
2. `/IMAGES/<model name>`
3. the image assigned to the model in the transmitter's own model settings
4. the Rotorflight logo

For the first two, any extension EdgeTX can read is accepted and tried in the order `.png`,
`.bmp`, `.jpg`, `.jpeg`; upper and lower case make no difference. The cell-count variant is
skipped while no cell count is known.

The image is fitted to the widget box with its proportions kept, so it fills as much of the box
as its shape allows. Standard EdgeTX model image dimensions (for example 192x114 or 160x128)
give the best result.

The caption under the image is the model name reported by the flight controller, or the
transmitter's own model name while none has been reported.


## Safety

Helicopters can be dangerous. Rotorflight is provided free of charge and without any warranty —
you use it entirely at your own risk.

- Always remove the main and tail rotor blades before configuring or testing on the bench.
- Always double check your configuration before flying.
- Keep a safe distance from the helicopter whenever the battery is connected.


## Development

Building the installation archive, deploying to a radio or to the EdgeTX simulator, and the
conventions the sources follow are described in [DEVELOPMENT.md](DEVELOPMENT.md).


## Contributing

Rotorflight is an open-source community project. Anybody can join in and help to make it better by:

* helping other users on [Rotorflight Discord](https://discord.gg/FyfMF4RwSA) or other online forums
* [reporting](https://github.com/rotorflight?tab=repositories) bugs and issues, and suggesting improvements
* testing new software versions, new features and fixes; and providing feedback
* participating in discussions on new features
* create or update content on the [documentation website](https://doc.rotorflight.org/contributing/editing-the-docs/)
* [contributing](https://doc.rotorflight.org/contributing/) to the software development - fixing bugs, implementing new features and improvements; what a pull request to this repository carries is in [CONTRIBUTING.md](CONTRIBUTING.md)
* [translating](https://doc.rotorflight.org/contributing/) Rotorflight into a new language, or helping to maintain an existing translation


## Origins

Rotorflight is software that is **open source** and is available free of charge without warranty.

Rotorflight is forked from [Betaflight](https://github.com/betaflight), which in turn is forked from [Cleanflight](https://github.com/cleanflight).
Rotorflight borrows ideas and code also from [HeliFlight3D](https://github.com/heliflight3d/), another Betaflight fork for helicopters.

Big thanks to everyone who has contributed along the journey!


## License

RFSuite is free software licensed under the GNU General Public License v3.0 (GPLv3).
See the [LICENSE](LICENSE) file for the full license text.


## Contact

Team Rotorflight can be contacted by email at rotorflightfc@gmail.com.

Please note that this email address is **not** for support. For help and questions, please use
the [Rotorflight Discord](https://discord.gg/FyfMF4RwSA).
