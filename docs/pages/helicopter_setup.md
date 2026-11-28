---
title: Helicopter Setup
---

# Helicopter Setup

A guided helicopter setup based on the Configurator wizard, with ESC telemetry
before the spin test in the 19-step sequence.
See the [generated wizard flow](../reference/helicopter-wizard-flow.md) for cards, pilot actions, gates and MSP traffic.
It is the only entry in the Wizards menu. Remove the main
and tail blades before bench work. Keep servos unplugged until the connection gate.

## Where to find it

*Configuration* → *Wizards* → *Helicopter Setup*.

The Wizards group is hidden until *System* → *Settings* → *General* → *Preview* →
*Setup Assistant* is enabled (`visibleWhen = "previewSetupWizard"` on the parent).
The page is greyed out until the flight controller answers
(`enabledWhen = "fblConnected"`), locked while armed (`lockedWhileArmed = true`),
and offered only from MSP API 12.10 (`minApiVersion = {12, 0, 10}`, Rotorflight 4.7): on an older
flight controller the menu entries stay greyed out. The page checks the version again, and a 4.7
development build that reports 12.10 but has no cell count per battery profile is refused as well;
both show **Firmware too old** with the reported version instead of the steps. It works from
the TOOLS menu and when the tool is hosted by the dashboard widget.

## Colors

The wizard follows *Color scheme* on [*Settings* → *General* → *Appearance*](settings/general.md),
light as it comes, with a set of pictures for each scheme. A changed scheme shows the next time the
wizard opens. Its choice lists and its number and text fields are the radio's own controls; they
take the scheme's colors with the rest of the tool.

The menu's **?** explains the tiles: a tick marks a step this flight controller completed
before, and the last tile, **Setup history**, resets the ticks.

Receiver setup requires an already working receiver/MSP link. Run automatic
receiver wiring detection in USB Configurator: that test reinitializes the same
UART that carries the radio link. ESC wiring detection and board auto-alignment
remain available on the radio when supported by firmware.
The single ELRS card applies only to a serial CRSF receiver (provider 9, serial receiver feature enabled)
with CRSF telemetry. Otherwise its Result row explains that the link is unavailable and it cannot start
reads or writes. STATUS freshness and the wizard's arming lock guard the task; leaving the card
cancels its pending FC requests. A request already sent to the FC cannot be undone by leaving.
The card reads both sides once on entry and again after an action. A table shows packet rate and
telemetry ratio for the **Flight controller** and the **ELRS module**, and one **Result** row says
**Settings match** or **Settings differ**; while a side is not read it says so, never that they
match. For DVDA module modes such as D500 and D250, only the telemetry ratio is compared.
**Make them match** offers the two directions, **Module takes FC values** and **FC takes module
values**. **Or choose other values** has a packet-rate and a telemetry-ratio list and **Set on
both**: choosing in the lists writes nothing; Set on both asks once, writes the module (one value
after the other, each read back), and only then lets the flight controller take the module's
values and save them. If the module does not take a value, it stops there and the flight
controller is not changed; if the flight controller does not save, the card says so and the module
keeps its new values (Set on both tries again, and saves the flight controller even when it already holds them). Every change asks first because the link may drop briefly; the
receiver Advanced switch is not required. Unsaved wizard changes must be saved first. The card has no
text band, so the table starts at the top and the controls fit 480x272; the ? sheet says why both sides
must match. On the 480-wide screens the two groups show their controls without the group names.

The accelerometer calibration card reports **Calibrated: Yes/No** from the live FC
status (ACC calibration arming-disable flag, bit 23), or **Unavailable** without an
accelerometer. This reports stored calibration, independently of calibration progress.
Mode cards show **ON/OFF** for the live switch/mode state, retaining **Unavailable**
when there is no reading.

Profile-switch recording stops after its window and retains the found positions for
**Use switch**, reporting the recorded count. Fewer than two positions keep the
two-position hint; listening without movement still times out. The trim-button guide
appears only for the **Buttons** gain method and follows method changes immediately.
The channel plan fits on one card; a long plan continues on a second.

## Loading and fresh status

A dedicated loading view shows bounded-read progress, a power reminder and Back.
Its progress updates in the existing scene. The model-preparation card shows a
short instruction; **?** retains the complete model checklist and active name.

If the suite has no usable link when the page opens (the board's identity is not known yet), or
the model is armed, the loading screen says so instead of filling its bar, and nothing is sent. The
page reads on by itself once the link is usable. **Back** leaves at once while nothing has been
written in this visit; once something has been written, a lost link asks for the flight controller
to be powered off first, because test outputs cannot be confirmed off.

An unanswered attitude or power reading keeps its last value until the next one. Any other request
that goes unanswered shows the error with **Try again**. These requests are not sent twice, because
a late reply could not be told from the answer to a later one. A servo, mixer input, mode or
adjustment row counts as written only once the flight controller has answered its write: a row
whose write an error or a late status cut off is written again by the next Save or Discard.

A status older than three seconds immediately blocks editing. Active tests and
pending writes still fail closed and release overrides. During an idle read-only
visit, or while an accelerometer calibration runs, the page displays **Checking current FC status; controls paused** while the
fresh STATUS request completes. It does not extend the safety window. A switch moved
while that request runs takes its last position: moved back before the answer, it changes
nothing. Each switch moved meanwhile keeps its own change, and all of them apply with the answer. A failed
request displays an error and a receiver-link hint. **Try again** starts a new
arming-disable/readback handshake; the expired timestamp cannot abort that handshake.
Status processing continues during resumable scene assembly. On firmware without
override timeouts, **No test timeout in this firmware: keep the link connected** appears
when an untimed hold is actually used, rather than during model preparation; a message
that answers the pilot's own action (for example a refused check) takes its place.

Yes/no and off/on answers are switches. They are not lists: the page gets no update
while a list is open, so a running test would outlive its status window behind it. A
setting that can be unknown (not read yet, or servos of one group that disagree) keeps
its list while it is, so no answer is implied.

A list whose question is not answered yet, or whose stored value is not one of its entries,
shows **Not set** as its first entry. Choosing **Not set** changes nothing; nothing is
preselected for the pilot. Once a value is set, the list shows only its real entries.

## Before the 19 steps

Complete setup first shows **Prepare the radio model**, outside the numbered sequence. It
states the prerequisites once: the flight controller on USB without the flight battery, the
receiver bound and working, because the wizard talks over that link. The active model name is
displayed. Use the Rotorflight model template or check the model yourself, then switch on
**Radio model set up**: the active transmitter model, its control functions, channel outputs,
throttle travel and switches. **?** explains the full preparation and shows the unabridged model
name. This screen records a pilot confirmation, not an automatic model audit. Receiver mapping is
still checked in step 2.

The first row is **FC name**, the flight controller's own name (up to 16 characters, the same
field as on the Configuration page). An edit is written with the next saved step.

The confirmation is remembered per flight controller and radio model, because one board can be
flown from another transmitter model: a file of its own beside the completion history
(`wizard-history/<board id>-prepared-<radio model file>-<hash>.lua`, keyed on the model's file on the card; the hash of the whole name keeps two names apart that the file name alone would join). Complete setup always shows the card. A
step opened on its own shows it the first time for that flight controller and radio model; after
that it passes the card by itself as soon as both state sensors below are live, and shows it only
while one of them is missing. A radio model without a file or a name is never remembered. The history/reset page needs no model-configuration confirmation. The 19 numbered steps
deliberately deviate from the Configurator's order at one place: Connect the servos
is step 10, ESC telemetry step 11 and the spin test step 12. The restarts the earlier
steps owe are done at Connect the servos, with the servos still out. The ESC link and
its live values then exist before the motor first spins, so an ESC with a working link
does not have to be calibrated.

The same card checks two prerequisites up front: the Rotorflight telemetry sensors
*System Status* and *System Config*, named in their rows. Each row reads **OK** in the scheme's
ok colour, **Checking**, or, after four reads without a value, **missing** in its error colour.
The wizard uses them for its hints about unsaved
settings, a pending restart and a lost receiver link, and **Continue** stays refused until both
are live. On API 12.10 both are in the flight controller's default telemetry list, so a missing
one is usually on the radio side: the Rotorflight model template has both, or the model can
discover new sensors. The card also reads the flight controller's own telemetry list over MSP;
only when a sensor is missing from it does **Add missing sensors to FC** appear, which writes
them into free slots of the flight controller's own buffer, saves and restarts it. A sensor that
is listed but not live has nothing a button could add.

Channel detection starts stick-travel measurement again, even when it learns the
same channel map. The guided **Check sticks** card therefore needs fresh travel to
both end stops of every control. Changing the channel map or stick range also
restarts measurement. Each control has a live bar with its receiver channel and its
reading in percent; on screens 400 pixels and wider the two directions stand at the
ends of the bar. A reading turns to the accent colour once its control has reached
95% in both directions, and the completion message appears when all four have.
**Measure again** clears the measurements and starts the guide over.

## Navigation

Every card shows where it is in its header: the step, the card's own name and its place
(for example **Receiver › Check sticks (3/7)**), and **Step n/19** on the right. Where a long
name does not fit, the header gives up space in this order: the large step font (800×480),
then the **Step n/19** text (the arrow stays), then the card's name for its place **(3/7)**. Tapping the
header opens the step menu: all 19 steps, the current one marked, done steps with a mark.
Opening it releases whatever the card holds, and nothing the card would start is started
behind the menu or behind the Save or Discard question. While an ESC read or write runs the menu does not open
and no jump is made, as Back waits for it too.
Choosing another step first offers Save or Discard when something changed, then opens that
step at its first card; the mode stays (Complete setup carries on from there, a single step
stays a single step). In Complete setup the chosen step starts with its *Before this step*
card where it has one, because the steps in between were skipped; for the same reason Back
from its first card enters the step before it afresh, with that step's own *Before this step*
card where it has one, and so on for each step Back reaches that way. Back on the open step
menu returns to the card the menu was opened from. A step that needs the owed restart first is
refused until it has happened. The preparation cards have no
step menu.

**Exit** sits at the bottom centre, between Back and Continue. It leaves the step, or the
complete setup, at once; unsaved changes first offer Save or Discard.

The Suite menu offers **Complete setup**, each of the 19 individual steps, and
**Setup history**. All entry points share the same lazy-loaded page: only the
selected step definition is loaded. Complete setup starts at step 1 in the original
order. An individual step starts directly, using current FC settings. Its last card
moves on to the next step, which is again a single step with its own preparation card;
Exit returns to the Suite menu after saving or discarding pending changes. RTN/EXIT
follows the same Back route. The wizard's code stays in memory while you move between
these entries; once you leave the Helicopter Setup menu for another menu or page, it is let go,
and the next opening reads it from the card again, which takes a little longer than a reopening
inside the menu. A step's own file is read when you enter the step and kept while you stay on it.

Direct configuration steps ask for blades removed and servos unplugged; direct
servo/control tests, including a servo tail, ask for blades removed and the servo
type/rate checked before entering their holds. Level and Blade pitch ask for the motor
unplugged instead of the blades removed, because measuring may take the blades. Motor tests retain their own gates.
These confirmations do not validate the mechanics. An existing restart requirement
is handled before direct entry to ESC telemetry or to a test after the connection gate: remove blades,
unplug servos, restart, then confirm the test prerequisites.

| Control | What it does |
| --- | --- |
| Back | Previous task. At the start of a step entered from the Suite, return to its menu, with Save/Discard when changes are pending. RTN/EXIT follows the same route. |
| Continue | Next task within this step; no EEPROM write, except when leaving a changed Power card at ESC telemetry: that saves everything the step has changed so far, the protocol and port included. |
| Next step | On a step's last card, in both modes: commit this step, write EEPROM only when something changed, and open the next step. A refused or missing reply blocks advance. |
| Exit | Leave the step, or the complete setup, at once; unsaved changes first offer Save or Discard. |
| Header | Opens the step menu (not on the preparation cards). |
| Reboot | At the connection gate, keep servos unplugged until restart completes. ESC telemetry restarts with the servos connected: their frame rate is already live. |
| Finish | On the last card of step 19: save pending settings, release overrides, and leave; a step opened from the wizard's own step list returns to that list. Leaving the wizard restores arming availability; it never arms the model. |
| Hold | A momentary motor control. Releasing the button stops the motor; motor overrides also lapse in firmware without refresh. |
| ? | Full instructions for the current task and the navigation help. |

Every card leads with its explanation across the full width, two lines, or three where the
rows still fit; the rows follow below. The ? sheet carries the whole text. The orientation
check is the exception: its live helicopter takes the left half, its hint and answer the right. Without a picture, each control follows right after
its label; illustrated tasks put the Configurator picture or mechanical reference on the
left and centre their rows on it. Action buttons are as wide as their label. The side-view cards show a picture of the helicopter in the
Configurator wizard's three poses: blades crossed out where they must come off (Board
orientation, Motor & ESC, ESC & spin test), level for the accelerometer calibration, and the
tail lifted 20 degrees for finding the board orientation. The three Swashplate cards show the
Configurator's drawings of the chosen value: the servo layout seen from above (numbered
servos, servo 1 in front or behind, servo 4 with a servo tail; Direct names each servo's
function), the main rotor turning, and the kind of tail. A picture changes with its value
without rebuilding the scene.
Control directions show the Configurator's roll, pitch and collective swash-motion
pictures alongside live input meters. Swash trimming and the level check show the
level-motion picture; the blade card shows blades at 0°. Both blade-pitch calibration cards show the 9°
reference. Tail centre and direction use separate servo-tail pictures, and motor
tails show the selected motor or bidirectional picture. The 22.5° tail calibration
shows the tail blades end-on with a 45° paper fold between them. Gyro checks show the roll, pitch and yaw correction
pictures. The rescue card shows the helicopter turned over or levelled, following its flip answer. Both servo connection cards show the Configurator servo picture.
The final Board orientation card has its own layout: a live helicopter above the
confirmation on small screens, and a larger model beside it on 800×480. Tilt the
real helicopter right/left and nose down/up; the picture must follow. Roll and
pitch are secondary readouts. The fixed view omits heading and fits the complete
model into the available space even at steep tilts. No fresh attitude for two
seconds hides the picture and displays a waiting message. Confirmation remains
manual; a level picture cannot prove correct mounting.

This view uses the existing MSP attitude read. While checking orientation, reads
alternate attitude/status/attitude/servo at the existing request cadence, without
increasing total request frequency. Projection runs once per changed sample in
wakeup; native getters only read fixed point tables. No reply rebuilds the scene.

Receiver, mode and profile detection capture a fresh FC-channel baseline when the
button is pressed; stale/missing samples ask the pilot to wait. Receiver mapping
uses raw wire-order RX_CHANNELS. Modes/profiles use RC in the FC function order,
with the displayed channel translated back through RX_MAP. Throttle may be a
switch: record its OFF/ON positions and finish OFF. The current endpoint is included
immediately. Control checks show the requested direction, FC channel and expected
physical response; **?** explains the viewing reference and the servo-direction remedy.

The left/right mode-switch picture follows the actual assigned ARM input range or the FC's
Rescue/Trainer flag. Unavailable input shows the switch at rest and says that the input is unavailable. ARM feedback describes
the switch while the wizard inhibits arming. The profile-switch reference stays
still, using the left-switch picture labelled as an example. Each servo type has its
own picture, the Configurator's servo drawing with that type's pulse train above it.
Servos that match no type, including groups whose servos differ, use the live pulse reference, cached on edits;
visibility changes keep the same scene objects and native getters do not generate waves. Timing beyond the pulse limit displays
a restart/readback hint instead of a physically impossible waveform. Receiver bars and control-command meters already follow live inputs;
swash, rotor and tail pictures follow the selected values. All other mechanical illustrations remain
test references: commanded output or board attitude cannot measure actual servo,
swash, blade or gyro-correction movement. Verify these on the real helicopter.
The short instruction area may show only its first lines; **?** opens the full text.

## Step sequence and settings

| # | Step | Controls and checks |
| --- | --- | --- |
| 1 | Board orientation | Four cards. Confirm servos unplugged and all blades removed. Calibrate the accelerometer with the model standing level and still. Enter roll, pitch and yaw in degrees, or **Detect** them below the three values by lifting the tail. Angles go to the flight controller as they are typed or detected, so the live model shows them; compare it with real roll/pitch movements and confirm the directions. Changing an angle takes that confirmation back. Automatic alignment requires firmware support. |
| 2 | Receiver | The first card shows the Configurator receiver picture; channel-order detection shows the stick icon for the requested function (centred for ARM or while idle). The throttle-range card shows the blades-off side view. Receiver protocol, Save & reboot, channel detection and presets stay locked until **Advanced** is switched on, under a bold warning: a setting that cuts the receiver link ends the setup, because the wizard talks over that link. From API 12.10 the protocol list offers FBUS only, because the firmware detects FBUS or F.Port2 speed on either id; a stored F.Port2 id stays listed, as FBUS. Keep the established receiver UART; receiver wiring detection belongs to the USB Configurator (a trial interrupts the radio MSP link). The channel-order card says that choosing the radio's standard order and continuing is enough; detection is the alternative. Detect collective, roll, pitch, yaw, the throttle switch (hold / governor) and the arm switch one control at a time, with **Skip this control** for one that is not there, or select ELRS, FrSky, Futaba/Hitec or DSM/Graupner/JR presets. Detection uses a fresh pre-click snapshot, so an immediate stick/switch movement is retained. **Check sticks** shows one live bar per control and is guided: it asks for one end stop at a time (roll right, roll left, pitch forward, pitch back, yaw right, yaw left, collective up, collective down), counts a direction at 95% of the FC's stick range, and says when the asked control moves the wrong way (reverse that channel in the transmitter) or another control moves (wrong channel order). The throttle-range card and its Minimum/Maximum limits are available without Advanced: **Record travel**, visit all throttle-switch positions (or both proportional endpoints), starting and finishing OFF, then **Use measured range**, which needs at least 300 µs travel and adds a 20 µs margin at each end; Minimum and Maximum can be edited. **(low)** beside the live throttle compares the mapped input with the low threshold; it is not permission to arm. The single ELRS link card reads the FC's declared rate and telemetry ratio and the transmitter module automatically and shows both in a table with one result; it aligns either side after confirmation, or sets chosen values (333 Hz, 500 Hz, D500; 1:4, 1:8, 1:16, 1:32) on both with **Set on both** (described above); save wizard changes first, keep the model disarmed, and keep telemetry running. **Stick center** follows the throttle range, as in the Configurator: with the roll, pitch and yaw trims centred, any subtrim removed and the sticks centred and let go, **Detect** reads roll, pitch and yaw five times as the FC receives them (its own channel readings, about 0.3 s apart; collective is left out because it does not spring back) and sets the stick centre to their rounded average when it differs from the stored one by more than 3 µs. It names a stick that does not match the other two by more than 5 µs (centre its trim and subtrim) and changes nothing when a stick moved more than 10 µs, a channel reads 0, the receiver signal is lost, or the result is outside 1400-1600 µs. Leaving the card, the exit question, the step menu or a flight controller that stops answering STATUS ends a running detection without a change. Right after the card opens, one reading shows a hint when the resting sticks agree, sit within 60 µs of the stored centre and differ from it by more than 3 µs. A new centre is saved with Next step, with the rest of the RC configuration; the stick travel measured on **Check sticks** was measured from the old centre, so the step asks for the sticks to be checked again. **Receiver done** closes the step with the protocol, the channel order, the throttle range (**Automatic** when Minimum and Maximum are 0) and the stick centre. **Throttle range** has the switch **Automatic throttle range**, as in the Configurator: on sets Minimum and Maximum to 0, the firmware then uses the stick centre ∓ 90 % of the stick range (1041-1959 us with the defaults), and the card shows that range; off starts from that range and shows Minimum, Maximum and Record travel. Opening the card writes nothing. **Check sticks** marks each end of each bar in the ok colour once that direction has reached 95 %. While the receiver step is open, the wizard polls only STATUS and the channels, so the bars follow the sticks about twice as often as before. |
| 3 | Mode switches | Assign ARM, RESCUE and TRAINER when the FC exposes them. Move the switch to its intended ON position; a clear AUX movement and settled position determine the active window. ARM is read from AUX1 only, the arm channel set in step 2, because ExpressLRS 4.x also outputs its arm flag on CH14 (AUX9), which moves with the arm switch. Reassign or Remove an assignment; both clear every range of that mode, because the firmware ORs them and a second ARM range would keep arming. ARM assignment is required. No unrelated mode slots are overwritten. Each card says what its mode does, and ARM carries a *Required* badge. Its first row says where the switch stands now; for ARM that is whether arming would be ON or OFF at that switch position, while the wizard itself keeps arming inhibited. Left/right switch pictures follow the same live state; unavailable input keeps its text cue. A last card, **Switches done**, shows one block per mode with its channel, its range and where the switch stands now, and says whether Next step has anything to store. |
| 4 | Profiles & gain | Detect a two- or three-position switch; select PID + rate profiles, PID only or None. Visit the positions and Use switch. Optional gain uses a knob, or four trim-button values on one spare channel. Mapped gain is 50–150%; button gain is ±5%, bounded to 25–200%. For Buttons only, the trim guide gives MAX mix weights 30/40/50/60%, with 100% at rest. Configure those mixes in EdgeTX; this page does not rewrite the transmitter model. The switch picture remains a labelled example. The last card, **Rescue**, turns rescue on or off and sets whether it flips the helicopter upright. The flight controller keeps these per PID profile; the card shows the active profile's setting, read again each time the card opens, and Save writes what was changed to every PID profile, keeping every other rescue value, then selects the active profile again. Rescue on keeps a profile's own mode (climb or altitude hold) and gives a profile that had rescue off the active profile's mode, or climb; a flip change leaves every mode alone. It needs a rescue switch from Mode switches and names the switch's channel. The picture follows the flip answer. The rescue tuning (gains, times, collective) stays on Flight Tuning > Rescue. A **Channel use** card shows each mode with its live ON or OFF, and says so when a channel past the eighth is in use. |
| 5 | Rates | One card per offered rate profile, in switch-position order, or one for the active profile. Each has four tiles: Custom, which keeps the profile's own rates, Trainer, Sport and 3D, two to a row below the 800×480 layout. The tile in the accent colour is the style the profile will have: the one chosen, or the one its rates already match, or Custom when none does. Under the curve, which follows that style, stand the cyclic and yaw rates with their expo and the collective the profile will hold; below the 800×480 layout they share one line, without the expo. Unmatched rates keep the sketch and explain replacement; **Suggest styles** sits above the first profile and, for a three-position switch, pre-selects Trainer, Sport and 3D on the three profiles' cards in switch order; one line names the profiles it set, and each card can still change its own. Trainer uses 180/270°/s, Sport 250/400°/s and 3D 400/600°/s. Collective pitch, its expo and its shape are preserved; only a change of rates type writes what the new type needs to keep the same degrees. Profiles are selected, read and written sequentially, then the original rate profile is restored. A last card, **Rates set**, shows everything the step sets in a table with a column per rate profile: the rates type, the Rotorflight curve shape or the Actual centre rates, roll, pitch and yaw rate with their expo, and the collective with its expo; it says whether Next step has anything to store. |
| 6 | Swashplate | Three cards, as in the Configurator, and a fourth, **Swashplate set**, with the layout picture beside everything the step sets: swash type, rotor direction, tail type, tail output, yaw input rate and TTA gain (*Unchanged* unless the tail changes between servo and motor). It says whether Next step has anything to store: select Direct, 120, 135, 140, 90L or 90V and, for 120/135/140, whether servo 1 sits in front of the shaft or behind it (behind, the usual layout, until the pilot chooses; the choice only picks the picture); the main rotor direction, clockwise or counterclockwise seen from above; the variable-pitch, motorised or bidirectional tail with the tail output it uses. The *Tail output* row shows the output the tail uses once saved: a pin the save still has to move reads, for example, *MOTOR 2 on save*, and both outputs or none read *set in Mixer*, because the wizard does not move them. Tail changes reset the yaw input rate to ±250 or ±1000. Switching between servo and motor tail sets TTA to 0 or 100 on every PID profile; motor-to-bidirectional changes preserve custom TTA. If supported and required, the tail pin is moved between SERVO 4 and MOTOR 2; a refusal is shown with the firmware's reason and the step can be left on the next Next step, so the tail is wired by hand (CLI `resource`) and the rest of the setup goes on. A missing command is reported as unsupported. |
| 7 | Servo type | One card per group, the swash servos and, with a servo tail, the tail servo; a motorised tail has no tail card. Only the PWM servos belonging to the selected swash/tail are used; bus channels are excluded. Servos must be unplugged before a type is chosen. Each group offers the types made for it: swash servos Analog (1520 µs, 50 Hz), Digital (1520 µs, 165 Hz), Hi-end digital (1520 µs, 333 Hz) and Narrow band (760 µs, 560 Hz); tail servo Digital (1520 µs, 200 Hz), Specific digital (760 µs, 333 Hz) and Hi-end specific (760 µs, 560 Hz). Use a type your servo maker allows: too fast a frame rate can burn a servo out. A type sets the centre pulse and frame rate of every servo in the group; changing the pulse band resets centre, travel and scale to the band's defaults, while a centre trimmed within the band keeps its type. Frame-rate changes require a restart, and the firmware may lower a rate for pulse limits or shared timers, so check the values after the restart. The type list stays locked until Servos unplugged is confirmed again after a restart. **Custom** is always the last entry: servos that share a centre band and a frame rate that no type has read Custom, and picking it changes nothing. **Frame rate (Hz)** sets a rate by hand for every servo of the group, within the band: 50–333 Hz for wide band (1520 µs), 200–560 Hz for narrow band (760 µs); it also needs a restart. A group whose servos differ opens the list on *Not set* and takes no hand-set rate until a type is chosen; nothing is written until a type or a rate is set. The picture shows the type's servo with its pulse train above it, drawn to scale over 20 ms, and the type's name and values below; for Custom it shows the nearest type of the band, captioned Custom with the servos' values; a group whose servos differ shows the live pulse train of what the servos hold, captioned *No type chosen*. The same card switches geometry correction for its group (bit 1; the reverse bit is kept). It turns the servo arm's arc into straight link movement. Use it with the arm at 90 degrees to the link at centre and large servo travel. Leave it off if the arm is not at 90 degrees at centre, a bellcrank or the mechanics already make the movement linear, or the helicopter manual says so. It changes travel near the end stops: recheck blade pitch and tail limits after switching it. No restart is needed. |
| 8 | Governor | Governor Mode offers Off, Limit, Direct, Electric or Nitro. While on, it is followed by **RPM source**, then Throttle Type: Normal, Switch or Function on Electric and Nitro, Normal alone below Electric, where a type stored by another route goes back to Normal. Choose **RPM wire (frequency sensor)** or **Bidirectional DShot**. The two are never on together: RPM wire enables the frequency-sensor feature without changing pin/resource mapping and turns bidirectional DShot off; DShot disables that feature and enables bidirectional telemetry. Both need Save and reboot. Zero motor poles and a DShot selection with a protocol outside 6..8 (DShot 300, DShot 600, ProShot) point to the Motor step first; DShot 150 sends no bidirectional DShot RPM. Pending feature/motor changes report the required restart. After reboot, Electric/Nitro report the FC RPM_SIGNAL verdict, including a missing RPM wire/pin; Limit/Direct report configuration only. Serial ESC telemetry is too slow for the governor. Check actual live RPM in the ESC telemetry step with the motor running and all blades removed. The Finish fast-RPM row follows the same checks. |
| 9 | Motor & ESC | Throttle Protocol holds the protocol, bidirectional DShot and blades confirmation. The protocol list starts with PWM, DShot 150 and DShot 300, the usual heli protocols; DShot 600 (fussy about long, noisy ESC leads) and the rest follow. DShot 150 gives no motor RPM: choosing it turns bidirectional DShot off, and the card says that the governor and the RPM filter then need DShot 300 or an RPM sensor. With the governor on, a protocol change also sets the RPM source: DShot 300 and DShot 600 take bidirectional DShot, every other protocol the RPM wire. Switching bidirectional DShot on turns the RPM wire off. **Motor poles** holds the main motor's magnet poles. **Main gear ratio** asks for the gear train: **One stage** (pinion : main gear), **Two stages** (pinion : intermediate gear, then intermediate pinion : main gear, as on a SAB Goblin) or **Ratio only** (for example 9.70:1). Each pair of tooth counts sits on one row, a : b, under the gearing picture. The flight controller keeps two numbers per rotor, so two stages are stored as products (pinion × intermediate pinion, intermediate gear × main gear) and a ratio as the smallest whole pair (9.70:1 as 10:97); a count whose product passes 50000 is refused. Switching between one and two stages keeps the ratio. **Tail gear ratio** asks where the tail is driven from: the **Main shaft** (drive gear : tail rotor gear), the **Intermediate shaft** (intermediate pinion : main gear, then pulley : tail rotor pulley; not with Ratio only) or **Ratio only**; the ratio is always counted from the main rotor shaft. A motor tail asks for the tail motor poles instead. The tooth counts are kept while the wizard is open; opened again, it starts from the stored ratios as one stage. **Motor & ESC set** closes the step with the protocol, poles, gear train, main ratio and tail ratio (or tail motor poles). Castle telemetry and the ESC_SENSOR feature are kept consistent. Set up a new ESC first (BEC voltage, motor timing, ESC governor off with the FC governor, and direction) under Configuration > Setup > ESC & Motors > ESC Tools for AM32, BLHeli_S, Bluejay, Flyrotor, Hobbywing V5, OMP, Scorpion, XDFly, YGE and ZTW; entries are available when the FC's ESC telemetry protocol matches. Where the Suite can open pages from a page, an **Open ESC Tools** button goes there; an unsaved change in the wizard has to be saved or discarded first. |
| 10 | Connect the servos | After the unchanged restart gate, one card lists the outputs and the connection confirmations. One restart applies pending board, servo-rate, mixer, governor and motor settings; keep the servos unplugged during it. The flight battery stays unplugged while the servos go in, because a powered ESC or BEC could move them at once; the card says so. Afterwards, check that the required main/tail motor outputs exist, that all required servo outputs exist, and confirm servos connected/powered with blades still removed. Going back in front of this step clears the servos-unplugged answer, so a later restart asks again. The restart gate and servo connection card show the Configurator servo picture. |
| 11 | ESC telemetry | First connect the flight battery with the main and tail blades still removed to power the ESC. ESC telemetry then selects the protocol; Castle explains its throttle-wire telemetry. Port appears only for a protocol using a telemetry port, with its own Save & reboot; FBUS and SRXL2 telemetry comes over the receiver link and takes no ESC port. A restart from this step reopens on Check. Check shows voltage and temperature with Detect wiring; Telemetry readings continues with current, RPM and reception status. Optional protocol and free/current ESC UART, wiring detection when supported, and Save & reboot. Choosing an ESC this wizard can program (OpenYGE, Hobbywing V5) also sets half-duplex and pin swap, saved with Save & reboot, because Detect wiring keeps the first wiring that delivers frames and an ESC that sends telemetry by itself would otherwise end the search on a wiring that cannot program it; F4 boards have no pin swap and leave it off. If the wire does not suit that setting, telemetry stays silent after the restart until Detect wiring has found the wiring. Choosing an ESC it cannot program before saving takes the setting back. On such an ESC already saved without half-duplex, Use half-duplex on the ESC parameter link card does the same. When only telemetry is found, the status line says so and the ESC parameter link stays unavailable. Reading the ESC afterwards is what confirms the link. Turning ESC telemetry on with no port chosen takes the first free port; a port already chosen is kept. Check live volts, amperes, temperature and RPM. Known board designs show the printed socket name with the UART name, for example Port A [UART4]; unknown designs keep the UART name. A restart here happens with the servos connected: their frame rate is already live. Off needs no serial ESC telemetry; Castle uses its throttle wire. The battery-connection card shows the Configurator ESC picture. |
| 12 | ESC & spin test | PWM calibration has three cards: Full throttle (the flight battery comes off again: unplug it first; blades off and the pinion out of mesh or the helicopter held down, because an ESC that does not enter calibration may run the motor at full throttle; battery unplugged, FC on USB, with live output), Connect the battery (wait for the ESC tones, then Low throttle), and Low throttle (confirm the tones and stored range; the motor must not run). Other protocols have one Connect the battery card reminding the pilot to keep it connected, or connect it now if unplugged. The spin test and motor-direction check follow. The full-throttle hold continues from the first calibration card to the battery card without a wizard-side deadline; Cancel, Low throttle, Back, other navigation, Exit, link loss or an error release it. Low throttle requires at least 99.5% actual output; calibration confirmation requires a positive output at or below 1005 µs. For the spin test, confirm blades removed, hold the helicopter down with hands clear of the head and gears, and hold at 5–50%, initially 10%. Release to stop, then confirm actual rotor direction. The first card shows the Configurator ESC picture. |
| 13 | Servo direction & centre | An intro card shows the servo-arm picture and three steps: fit the arms square, test the upward movement, then adjust the centres. Continue opens one card per swash servo, followed by the tail servo when a servo tail is fitted, on every screen class including 320x240. Each servo card shows its name and role, centre and offset, reversal, the servo-arm picture, and -10 / -1 / +1 / +10 us buttons. Swash cards offer Move up 20° and Yes / No (reverse); the tail card sets its centre only. All servos are held at centre while a servo card is open; only its servo moves for the test. An offset beyond 100 us uses the warning colour and shows the full spline warning on that card. Back and Continue move freely between servo cards; Next step on the last card requires all swash directions confirmed and all centres within 100 us, naming the blocking servo and role if refused. Back from the first servo returns to the intro and releases the holds. In an individual step, Before this step still precedes the intro. |
| 14 | Control directions | Roll, pitch and collective use mixer passthrough. Check live RC commands and physical swash response. Wrong reverses the corresponding mixer input rate, and its button says when an axis is reversed. The first row names the input the check needs and shows where the stick is now (a direction and its travel in percent, or centre); the expected movement stays visible below it; roll is viewed from behind, pitch from the side with the nose right. Confirm each axis. Roll, pitch and collective show their Configurator swash-motion pictures with the live input meters. |
| 15 | Level the swash | Four cards. **Motor unplugged** comes first: the main motor stays off until Finish, because measuring may take the blades, or a marking on the rotor head, or a gauge directly on the blade grip. Then roll, pitch and collective are held at zero: set the links until the swash is level, then use the trims for the fine adjustment, in 0.1% units, ±100%; Reset clears them. Use a leveller or measure links and confirm level. With the swash level, set the blade links until each blade reads 0° and confirm that too. A helicopter with no swashplate set gets one card saying so, with a button to the Swashplate step. The trim and level cards show the level swash-motion picture; the blade card shows blades at 0°. |
| 16 | Blade pitch | A first card shows the helicopter from above, nose left: turn the rotor head by hand until both main blades lie along the tail boom, and switch on **Blades along the boom**; the measuring cards are not reached before. **Collective**: hold 9°. **Cyclic**: leave the head where it is and hold 9° over roll, with pitch and collective at zero; there is one cyclic calibration, and its rate goes to roll and pitch alike. The first row holds an angle: it starts at 9° on every entry, the flight controller follows it while held, within the stored limit and negative too, and release goes back to 0°, so other angles can be checked; it is never stored. Calibration is at 9°: enter the measured angle in 0.1° units and Apply, which works only while holding exactly 9°; a stored limit below 9° is named on the card; the mixer rate is corrected by 9/measured, preserving sign and limiting magnitude to 20–200%, and the status line asks to measure again. Three cards set the cyclic limit (**Use 10 degrees**), the collective limit (**Use 12 degrees**) and the total limit. **Collective at full stick** has one row per rate profile on the profile switch, else the active profile; each profile is read first, only a changed value is written, at Save, in that profile's own rates type, and the selected profile is restored. The range is 0–25°; a value above the collective limit is flagged. A last card confirms no binding at full travel. Both calibration cards show the Configurator 9° blade-pitch reference. |
| 17 | Tail rotor | Servo tail: hold neutral, set centre trim, check yaw passthrough (the card names the yaw input and shows the stick) and reverse if needed; command ±22.5° to calibrate rate (at 22.5° each way the tail blades open to 45°: without a pitch gauge, a square of paper folded corner to corner sits flush between them), then ±60° to set CW/CCW limits. Raw yaw limits use 1000 units per 24°. Motor tail: hold controls for forward (tail blades off, or the helicopter held down with hands clear of the tail), and reverse for bidirectional tails. Idle test is limited to 15 seconds; idle is limited to 25.0%, the CLI range. Centre and direction show separate servo-tail pictures, with a live yaw meter for direction; the 22.5° calibration shows the blades end-on with the paper fold. The motor picture follows motor/bidirectional mode. |
| 18 | Gyro check | With all overrides released, tilt roll/pitch and, for a servo tail, turn yaw. Confirm correction against motion. If it moves with the model, return to Board orientation. A motor tail omits the servo yaw check inside this step. Each axis shows its Configurator gyro-correction picture. |
| 19 | Finish | Review readable swash, rotor direction, tail, collective/cyclic limits, ESC protocol, telemetry, governor/throttle type, fast RPM and ARM assignment. A card offers the Governor and PID pages; going there ends the setup cleanly, arming allowed again. Confirm the final checks, then Finish. Plug the motor back in, fit the blades, check failsafe, governor behaviour and every control before flight, and keep the first hover careful. |

<!-- radio pictures: begin -->
## Power and battery cards (step 11)

After **Check** and **Telemetry readings**, step 11 adds **Voltage and current** (both
sources with their live readings on one card), **Batteries** and SmartFuel Mode. On a flight
**Batteries** asks first how many
different packs are flown (**Different packs**, 1-6; it starts at the number of battery profiles
that hold a capacity) and then shows one row per battery profile with its cell count, picked from a list (Auto or 1S-24S), and
capacity. Profiles beyond that number are not changed, and a profile that leaves the table goes
back to the values read. The existing ESC throttle-range
and operating-mode cards follow this block. Settings use the wizard's normal
Save/Discard/EEPROM boundary; no source, battery-profile or SmartFuel setting is
written by opening a card. Existing ESC reboot requirements still apply.

| Setting | Meaning and availability |
| --- | --- |
| Voltage Source | FC voltage input, using the exact Power > Sources options: NONE, ADC, ESC, FBUS; CRSF from known API 12.0.10. An unknown stored ID remains selectable and is preserved. |
| Voltage | Live ESC voltage in V from motor telemetry, including an explicit missing-voltage message. Other sources show the FC's selected-source analog reading as soon as the changed source has been written to the FC, before the card is saved; until then the row reads *Applying source...*. Missing or stale readings show no telemetry. |
| Current Source | FC current input with the same options and version rule as Voltage Source. |
| Current | Live ESC current in A, or the FC's selected-source analog reading once the source is written. Zero current can be normal at rest. A source not yet written never claims another source's reading. |
| Different packs | 1-6: how many kinds of flight battery are flown, one battery profile each. Starts at the number of profiles that hold a capacity. |
| Battery n | One row per battery profile: the cell count from a list, Auto (stored as 0, the FC detects the cells) or 1S-24S, and the capacity, 0-40000 mAh. Editing a row does not activate that profile; the active profile's values are also the FC's current ones. |
| Firmware Source | SmartFuel OFF (LOCAL), VOLTAGE, CURRENT or COMBINED. A line under the choice says what the chosen mode does: the radio estimates the remaining capacity itself, or the FC estimates it from the pack voltage, counts the used mAh against the capacity, or takes the lower of both. VOLTAGE and COMBINED show a warning when the draft Voltage Source is NONE. The three tuning values are preserved. |

Battery and Sources have no API-version gate in the current Power pages. The
wizard uses optional, single-message startup reads for battery_config and
battery_profile; reply length determines per-profile-cell support, which the wizard
requires. SmartFuel follows the Power menu's API 12.0.9 gate and
is hidden if its optional read fails. The wizard's existing overall API 12.10
requirement remains in force.

On these cards only, one nine-byte analog live read replaces the unused servo
poll. It does not add a startup read or delay STATUS/motor_telemetry polling.
ESC uses the already-polled motor_telemetry values. Both caches expire after two
seconds; analog readings also retain the source IDs the FC held when they were
requested. A source change is written to the FC at once, without saving to EEPROM: the
firmware reads the source on every battery update. Each Power card is saved when the
pilot moves on to the next card, so Discard only undoes the card on screen. Voltage meter calibration is unchanged and voltage_meter_config is not
read or written.

## ESC throttle range and operating mode (step 11)

Throttle range appears for PWM, ONESHOT125, ONESHOT42 and MULTISHOT. It is split
into task cards and never scrolls. DShot, ProShot, Castle and SRXL2 omit the range
cards. The choice lasts for this wizard visit and is not stored on the radio.

| Setting | Behaviour |
| --- | --- |
| How is the ESC's throttle range set? | Calibrate the ESC is offered only for PWM and uses the existing step 12 procedure. Set in the ESC by hand / already set requires explicit pilot confirmation. Set through the ESC link is offered only for OpenYGE (telemetry protocol 9). |
| I confirm the ESC range is set | Confirms that the manually set ESC range agrees with the FC outputs; sends no configuration writes. |
| Use half-duplex | A switch showing the ESC port's half-duplex state. On sets half-duplex with the board's pin swap; off goes back to receive-only telemetry and takes the pin swap back to the FC's own, or none. Either way the change is saved with the restart. |
| Read ESC parameters | Requires a powered ESC, live voltage or temperature, the matching saved telemetry protocol, an assigned ESC UART and half-duplex. Save and reboot after wiring changes. Timeout or a family-signature mismatch reports battery, wire, half-duplex and protocol checks; calibration/manual routes remain available. |
| ESC model / ESC firmware | Shows the model identifier and firmware exposed by the API. |
| Stick zero (us) / Zero + range (us) | Shows the current YGE zero and the sum of its zero and range fields. |
| Stop pulse (us) | Proposed FC firmware default: 1000. |
| Minimum pulse (us) | Starts at 1070; editable within the motor API's pulse limits. It must exceed the stop pulse. |
| Maximum pulse (us) | Starts at 2000; editable within the motor API's pulse limits. It must exceed the minimum. |
| Use these values | Explicitly reads the ESC again, saves and reads back FC mincommand/minthrottle/maxthrottle through the existing save path, then writes the complete YGE block with the selected zero/range. Other ESC parameters remain unchanged. Only matching ESC readback confirms the range; FC changes retain the existing reboot requirement. Editing a number sends no writes. |
| Current ESC mode | Read-only named mode for YGE and Hobbywing V5 (telemetry protocol 3), independently of the throttle protocol or range route. HW1128/HW1132 report that the mode is unavailable and omit the mode card. Nitro omits ESC parameter cards. |
| Expected ESC mode | Electric requires YGE Ext or Hobbywing Heli (Linear Throttle)/Fixed-wing. Direct requires YGE Heli/Store or Hobbywing Heli (Elf Gov)/Heli (Store Gov). Off/Limit display the current mode without an expectation. The first listed heli option is preselected. Returning after changing step 8 re-evaluates the expectation. |
| Set ESC mode | Appears with a mismatch warning. Only this button reads again, overlays the selected mode on the complete block, writes it and verifies by reading. Range and mode share the same transaction owner; neither can overwrite the other's earlier change. |
| Battery unplugged and reconnected | Explicit acknowledgement after the FC requests an ESC restart or acknowledged values do not yet match. Remove all blades, unplug and reconnect the flight battery. |
| Re-read after battery restart | Verifies the requested values; acknowledgement alone never confirms them. |
| Throttle range (Finish) | Distinguishes set via ESC link, confirmed by pilot and calibrated. PWM spinning accepts pilot confirmation or verified link range as alternatives to calibration. |

Parameter reads run after the step has loaded and live telemetry is present;
they are not in startup READS or page construction. Reads retry FC cache error
replies with a bounded transport job. No ESC write is possible without a
successful read in the current visit and an explicit button press.

## The steps on the radio

Taken on the EdgeTX simulator (TX16S MK3, 800x480, English, the default light scheme) against a
Rotorflight SITL flight controller, each step opened from its own menu entry and shown on its first
card (after *Before this step* where the step has one).
Smaller screens use the compact layouts described above.

**1. Board orientation** (first card)

![1. Board orientation](../images/helicopter_setup/radio/step-01.png)

**2. Receiver** (the first receiver card, and the channel-order card after it)

![2. Receiver](../images/helicopter_setup/radio/step-02.png)
![2. Receiver, second picture](../images/helicopter_setup/radio/step-02b.png)

**3. Mode switches** (first card)

![3. Mode switches](../images/helicopter_setup/radio/step-03.png)

**4. Profiles & gain** (first card)

![4. Profiles & gain](../images/helicopter_setup/radio/step-04.png)

**5. Rates** (first card)

![5. Rates](../images/helicopter_setup/radio/step-05.png)

**6. Swashplate** (first card)

![6. Swashplate](../images/helicopter_setup/radio/step-06.png)

**7. Servo type** (first card)

![7. Servo type](../images/helicopter_setup/radio/step-07.png)

**8. Governor** (first card)

![8. Governor](../images/helicopter_setup/radio/step-08.png)

**9. Motor & ESC** (first card)

![9. Motor & ESC](../images/helicopter_setup/radio/step-09.png)

**10. Connect the servos** (first card)

![10. Connect the servos](../images/helicopter_setup/radio/step-10.png)

**11. ESC telemetry** (first card)

![11. ESC telemetry](../images/helicopter_setup/radio/step-11.png)

**12. ESC & spin test** (first card)

![12. ESC & spin test](../images/helicopter_setup/radio/step-12.png)

**13. Servo direction & centre** (first card)

![13. Servo direction & centre](../images/helicopter_setup/radio/step-13.png)

**14. Control directions** (first card)

![14. Control directions](../images/helicopter_setup/radio/step-14.png)

**15. Level the swash** (first card)

![15. Level the swash](../images/helicopter_setup/radio/step-15.png)

**16. Blade pitch** (first card)

![16. Blade pitch](../images/helicopter_setup/radio/step-16.png)

**17. Tail rotor** (first card)

![17. Tail rotor](../images/helicopter_setup/radio/step-17.png)

**18. Gyro check** (first card)

![18. Gyro check](../images/helicopter_setup/radio/step-18.png)

**19. Finish** (first card)

![19. Finish](../images/helicopter_setup/radio/step-19.png)

<!-- radio pictures: end -->

## Completion history and prerequisites

The Suite stores a small history for each connected FC's MCU identity. A step is
recorded only after its required answers and successful settings save; incomplete,
discarded or failed steps are not marked. A former completion is shown as
**Completed before. Check again.** It never supplies a physical answer or skips a
preparation, direction, blades-off, arming-lock or restart check.

If related earlier steps have no recorded completion, a short footer hint gives the
count and **?** lists them. These are advisory dependencies: for example receiver
mapping before modes, swash/servo type/connection before servo centring, and
control directions/levelling before pitch measurement. A correctly configured FC
may have been set up elsewhere. History does not prove the current FC settings or
mechanics, and does not block such a model merely because no visit is recorded.

**Setup history** shows the recorded count. Select **Clear this FC history**, then
**Reset history**, to clear all 19 markers for that FC. It changes no FC settings,
transmitter settings, other FC's history or old Setup Assistant data. Readable FC
identity and a connected, disarmed model are required. This page reads only the
arming status needed to keep the visit locked; resetting never writes FC EEPROM.

An unwritable card or failed record readback reports that history was not saved.
Retry is explicit. For a completed setup step, **Continue without history** finishes
the action without claiming a stored completion. Back cancels that notice without
advancing. Unreadable history must be explicitly reset before it can record more
steps. Records are separate, versioned files under `rfsuite.user/wizard-history/`.

## Loading and live feedback

Startup reads adjustment ranges and servo settings one indexed record per request.
The progress text updates in place while loading. A reload after a restart shows
the same count in the status line, under the card that is still on screen, until
the wizard is ready again. The larger USB bulk replies do not fit the firmware
telemetry response buffer and are never requested here.

When live System Status (`STAT`) or System Config (`SCFG`) telemetry is available,
the footer can show FC saving, unsaved changes, restart needed, active override,
missing receiver link, accelerometer calibration or active PID/rate/battery profiles.
Specific operation messages, errors and permanent-override warnings take priority.
Missing or stale packed words add no hint and do not prevent normal MSP operation.
Their values never acknowledge a save, clear a local restart requirement or replace
the fresh MSP arming-lock check. EdgeTX can retain per-sensor current status for up
to 20 seconds; treat these as supplementary observations.

## Overrides, connection loss and saving

MSP_ARMING_DISABLE blocks arming while the page is open and is asserted again after
a restart. The MSP arming-disable flag is independently read back before controls
are enabled and checked throughout the visit. Servo, mixer and motor overrides are explicitly released on each task/step
exit and on page teardown. Leaving drops unsent override keepalives. Configuration
writes are acknowledged before EEPROM and before moving to the next step.

Timeout support is **probed independently** for servo and mixer commands, never
inferred from API 12.10. An OFF request with a valid five-byte timeout payload must
succeed and an invalid four-byte OFF payload must be explicitly refused. A timeout
does not prove support. Firmware that ignores trailing bytes therefore stays on
legacy three-byte holds. Supported holds use a 3000 ms timeout; releases always
use the legacy payload. Motor overrides retain the fixed one-second expiry.

Leaving a task waits for OFF acknowledgements before another hold can start.
Normal exit restores arming availability only after confirmed cleanup and
Save/Discard. Failed cleanup keeps arming disabled and offers explicit retry.
On link loss, Back explains that the FC must be powered off before leaving:
permanent overrides cannot be released over a missing link. Reconnect allows
cleanup to resume for the same FC.

An externally interrupted visit retains the FC's arming lock. On reopening in the
same Suite session, a recovery gate asks for an FC power cycle before continuing;
this clears permanent overrides and unsaved RAM changes. Power-cycle the FC after
an unexpected tool/widget termination even if the radio has also restarted.
The Suite's independent ARMED banner remains visible above the wizard's frame.

Back across a dirty step asks to save or discard before loading another step, so
profile-specific changes retain their originating commit. Discard clears pending
pitch/rate drafts. ESC calibration has its own fresh blades-removed confirmation;
reloading configuration invalidates all physical answers.

Do not switch helicopters during a visit. The wizard binds itself to the FC identity.
An armed transition, lost connection, refused operation or malformed response blocks
progress; it does not report a successful save. Retry is an explicit action.
Returning to a physical-check step requires fresh answers.

The connection gate batches the initial restart. Receiver wiring and ESC
telemetry can need their own restart, as in the Configurator sequence; ESC
telemetry restarts before the connection gate, while the servos are still unplugged. Unsupported
automatic wiring/alignment commands do not prevent using the manual settings.
If automatic board alignment is refused, the status line explicitly asks for the
angles to be entered manually; that refusal does not change the current angles.

## Feedback and detailed settings

The governor's headspeeds appear only in **Electric** and **Nitro**, where
the FC governs, on one card with a row for each PID profile. All editors start with values read
from the FC. A row is offered for each PID profile selected by the Profiles & gain adjustment range,
bounded by the configured positions (at most three) and the FC profile count.
Without a known assignment, only PID profile 1 is offered. Entry reads every
offered profile's target: it selects each profile in turn, reads it and selects the
active profile again, writing nothing; a target shows **--** until its read is back.
Save uses the same transaction for edited targets only.
The native wizard editor retains exact RPM
values, including values between the Governor page's 10-RPM increments.
The wizard does not set the spoolup, spooldown and recovery times; they stay as
they are on the FC and are set on the Suite's Governor page
([Ramp Time](setup/governor/time.md)).

- **Full headspeed (rpm)**: Full-throttle target for the named PID profile, 0–30000 RPM; no recommended target is substituted.
- **RPM source**: Frequency sensor or bidirectional DShot for the governor and RPM filter. The card also appears with governor Off when RPM filtering is enabled.
- **RPM filter**: A separate warning card says when filtering has no selected RPM source. Choose a source here or turn RPM filtering off on the Filters page. The wizard never changes filter settings.

The suite's Filters page calls preset zero **CUSTOM**, not Off. Low/Medium/High
presets enable RPM filtering; CUSTOM needs a signal if any of its 16 notch sources
on any of the three axes is nonzero. With all custom sources zero it is off. Filter
configuration and custom notches are read once after entering the governor step;
they add no MSP work to scene construction or the startup read chain. The warning
applies in Off, Limit, Direct, Electric and Nitro. Selecting a source still requires
Save and reboot; existing status feedback remains the FC/configuration verdict.

Test buttons show when a held command is active; pressing a servo/mixer test again
returns it to neutral. Motor controls are momentary and remain disabled until the
required preparation and output checks pass. The status line distinguishes staged
changes, live edits, pending restart, running detection and a found combination.
A successful wiring trial changes Continue to **Save & reboot**. Cancel restores
the previous wiring flags. No ESC data is labelled as received until voltage or
temperature confirms reception.

The profile/gain cards show the existing assignments, the current mapped profile
and knob/button feedback, followed by a paginated channel-use plan. For the trim
method, create a spare channel with a MAX source at 100% when no button is pressed.
Add replacement mix actions for cyclic down/up at 30/40%, yaw down/up at 50/60%,
and disable those trims' effect on the flight sticks. The guide lists the expected
channel values. Confirm each button in the live feedback before flying.

For detailed adjustments beyond the guided fields, save and leave the wizard,
then use the Suite's Receiver, Modes, Adjustments, Rates, Mixer, Servos, Governor,
Motor or Power pages. The wizard's **?** opens the complete current task text.
It does not jump out of an active bench test through a web-style tab shortcut.

## When radio memory runs low

Each new card takes some of the radio's memory, and a radio that runs out stops all of its Lua
scripts at once. A servo or mixer test held at that moment would stay active on firmware without the
override timeout (a motor test stops by itself a second later), and the flight controller refuses to
arm while one is. So after each new card the wizard reads how much memory the
radio has left:

- below 350 kB the status line says *Radio memory is low: save and leave soon.* Nothing else
  changes; finish the card, save and leave the wizard;
- below 250 kB the wizard stops. It releases every test first, then shows *Not enough radio memory
  to go on* with **Save & exit** and **Discard & exit** when there are unsaved changes, otherwise
  **Close**. Back closes it when nothing is unsaved. No other card opens from this screen. Restart
  the radio before opening the wizard again.

A save, a restart, an ESC parameter transfer or an ELRS link sync already running (with Set on both, all of it) finishes before the stop. The stop screen says the tests were released only when every release was answered; with the link lost it says they were not confirmed off. **Save & exit** also writes a live change the stop cut off on its way to the flight controller, and when the save has something to say (a tail output the flight controller refused to move) the stop screen shows it above **Close**. Where the radio does not report its
free memory (the EdgeTX simulator), the wizard does not check it.

## Session Logs

For troubleshooting, the wizard writes short English lines under the tag
`rfsuite.helicopter_setup` once *Debug Level* in the developer settings is above *OFF*; at
*OFF* it writes nothing. *ERROR* records a failed MSP step with its reason, and a stop for low radio memory with the free figure. *WARN* adds what
degrades and carries on: low radio memory, an edit dropped, a late status, a lost link, an override cleanup not confirmed, a refused
tail pin move with the firmware's result code, a trial that found nothing, a missing output. *INFO* records loading (start, ready, or the error with the MSP name
and reason), each step and card entered, every change of the status line as it is shown (the
wizard's own messages, the flight controller hints and the cleanup and recovery notices) by its
label key, where a line filled in from a template is named by the template's key, save, discard,
live writes, restart and reconnect, the memory stop screen shown, what a step queues for the flight controller (a mode's range, a calibrated rate, collective and styles per
profile, an ESC range or mode), and closing. *DEBUG* adds the picture file shown, the helpers loaded and released on
demand, whether a step's cards were reused or built anew, the profile loops, a refused Next, a
reversal and a row written again because its last write was not answered. *TRACE* adds the flow, for reading live over the serial port: each move between cards, a hold and its
release, an edit, an answer given, a row write answered, a gear or servo centre change, the published scene, the free memory read after it, and a build request
left out while the loading view is shown. The lines appear under *Session
Logs* and, with *Log Session To Card* on, in the card log; the level is read when the wizard
opens.

## Implementation and verification

[Artwork sources and PNG export workflow](../developer/helicopter-wizard-artwork.md)
describe the illustration collection maintained alongside the wizard.

The reference is [Configurator PR #491](https://github.com/rotorflight/rotorflight-configurator/pull/491),
snapshot `b8f0eca5a73e8ea00a21a8122a8f7029ad705ee7`. Timeout/tail-output semantics follow
[firmware PR #541](https://github.com/rotorflight/rotorflight-firmware/pull/541).
The sequence is fixed; conditional variants stay inside their steps.

API loads, reply decoding, indexed writes, profile transactions and scene assembly
are resumed across calls. MSP replies update cached values; they do not rebuild LVGL.
Reactive properties read cached page state. A move to another card shows the loading view in
one build: while that view is on screen and no finished scene is current, the wizard asks for no
further build, and the finished scene replaces it in the next one. `bin/wizard/verify.lua` exercises the
protocol, failure paths, lifecycle, geometry and per-call instruction costs without
starting an EdgeTX or flight-controller simulator.
The previously published native tree remains valid while a replacement scene is
staged. Its getters tolerate navigation, reload, discarded rate drafts and teardown;
controls from a replaced card cannot edit the new step. Regression checks retain
every old card across these transitions at all four supported preview sizes.
Consumed MSP batches are released when a new idle batch starts, keeping completed
polling jobs from accumulating throughout a visit.
Completion history uses a separate versioned Lua data file per FC under
`rfsuite.user/wizard-history/`. Each record is read directly within 64 bytes;
compiled overlays are ignored. Unreleased text records are ignored; there is no
text-format migration or compatibility path.

[Source-to-port coverage and deliberate adaptations](../reference/helicopter-wizard-source-coverage.md)
record the function inventory, behavior contracts and independent golden vectors.

The preview images are approximate renders of the actual scene definitions, using
desktop fonts. They are not native EdgeTX screenshots or radio acceptance evidence.

[Compact live orientation](../images/helicopter_setup/01-small-task-4.png) ·
[Compact roll movement](../images/helicopter_setup/motion-attitude-roll-small.gif) ·
[Compact pitch movement](../images/helicopter_setup/motion-attitude-pitch-small.gif) ·
[800×480 orientation](../images/helicopter_setup/01-large-task-4.png) ·
[Swash layout](../images/helicopter_setup/06-small.png) ·
[Rotor direction](../images/helicopter_setup/06-small-task-2.png) ·
[Tail](../images/helicopter_setup/06-small-task-3.png) ·
[Swashplate set](../images/helicopter_setup/06-small-task-4.png)

[Switches done](../images/helicopter_setup/03-small-task-3.png) ·
[Rates set](../images/helicopter_setup/05-small-task-2.png) ·
[800×480 stick check](../images/helicopter_setup/02-large-task-3.png)

[Stick check](../images/helicopter_setup/02-small-task-3.png) ·
[Throttle-switch endpoints](../images/helicopter_setup/02-small-task-4.png) ·
[Swash servo type](../images/helicopter_setup/07-small.png) ·
[Tail servo type](../images/helicopter_setup/07-small-task-2.png) ·
[Servos with no type](../images/helicopter_setup/07-small-task-type-none.png)

[480×272 illustrated tasks](../images/helicopter_setup/illustrations-small.png) ·
[800×480 illustrated tasks](../images/helicopter_setup/illustrations-large.png)

[Small-display preview sheet](../images/helicopter_setup/overview-small.png) ·
[Large-display preview sheet](../images/helicopter_setup/overview-large.png)

*Documented against RFSuite 0.2.1. Physical-radio acceptance remains required.*
