# Development

Everything in this file is about working on RFSuite. If you only want to install and use it,
the [README](README.md) is the whole story.

The project conventions the sources follow — module loading, UI helpers, logging, memory
handling and the i18n rules — are in [GEMINI.md](GEMINI.md). What every pull request carries —
a release note, its documentation — is in [CONTRIBUTING.md](CONTRIBUTING.md).


## Repository layout

| Path | What it is |
| --- | --- |
| `src/main.lua` | The tool entry point, deployed as `SCRIPTS/TOOLS/rfsuite.lua` |
| `src/rfsuite/` | The core package, deployed as `SCRIPTS/TOOLS/rfsuite-core/` |
| `src/rfsuite/app/` | Menu manifest, registry and the configuration pages |
| `src/rfsuite/core/` | Viewport abstraction and the per-radio display profiles |
| `src/rfsuite/layouts/` | The Border, Grid and Flow layout engines |
| `src/rfsuite/ui/` | Screens and the shared controls in `controls.lua` |
| `src/rfsuite/lib/` | Logging, preferences, sensors and other supporting libraries |
| `src/rfsuite/tasks/` | MSP transport, the MSP API modules and the background event tasks |
| `src/rfsuite/widgets/` | Dashboard runtime, objects and themes |
| `src/rfsuite/i18n/` | Locale bundles, one Lua file per language |
| `src/widgets/rfsuite/` | The dashboard widget, deployed as `WIDGETS/rfsuite/` |
| `src/widgets/rfsuitesvc/` | The background service widget, deployed as `WIDGETS/rfsuitesvc/` |
| `docs/` | The user-facing reference, one file per page, and the contributor guides; see below |
| `bin/package/` | The installation ZIP builder |
| `bin/accounting/` | The instruction-budget accounting that gates every pull request; its own notes are in `bin/accounting/README.md` |
| `bin/sensors/` | The simulator sensor tool |
| `simulator/` | The SD card root the EdgeTX simulator is pointed at; see below |
| `.vscode/` | Deploy and simulator tasks, and the i18n build scripts |

The deployed layout — on the simulator's SD card, on a radio and inside the release archive
alike — is:

```
SCRIPTS/TOOLS/rfsuite.lua        tool entry point
SCRIPTS/TOOLS/rfsuite-core/      core package
SCRIPTS/TOOLS/rfsuite.user/      user settings, model preferences, user themes
WIDGETS/rfsuite/                 dashboard widget
WIDGETS/rfsuitesvc/              background service widget
SOUNDS/rf/                       announcement pack, one folder per language
```


## The `simulator/` folder

`simulator/` is a checked-in SD card root for the EdgeTX simulator: a radio configuration, one
model, and the SD card version markers the firmware expects. It exists so that a fresh clone
can run the suite without hand-building a card, and it is a development aid only — nothing in
it ships to users, and the release archive does not contain it.

The deploy task copies the sources into this folder, and the simulator tasks start
`simulator.exe` with `--sd-path` pointing at it. `.gitignore` excludes `simulator/*`, so the
deployed `SCRIPTS`, `WIDGETS` and `SOUNDS` folders stay out of the repository; only the card
files themselves are tracked.


## Running it

The `.vscode` folder carries run configurations and tasks for the usual loop.

| Run configuration | What it does |
| --- | --- |
| `RFSuite: Deploy to Simulator` | Copies the sources into `simulator/` |
| `RFSuite: Deploy to Radio` | Copies the sources onto a mounted radio SD card |
| `RFSuite: Build Radio Install ZIP` | Builds the installation archive |
| `RFSuite: Deploy + Run Simulator (TX16S MK3)` | Deploys, then starts the simulator |
| `RFSuite: Deploy + Run Simulator (TX16S)` | as above, for the TX16S |
| `RFSuite: Deploy + Run Simulator (TX15)` | as above, for the TX15 |
| `Sensors: Run Tool` | Starts the simulator sensor tool |
| `Sensors: Build + Run Tool` | Rebuilds the sensor tool first |

The simulator tasks pass one of the radio targets `edgetx-tx16smk3`, `edgetx-tx16s` or
`edgetx-tx15`. The matching `RFSuite: Start EdgeTX Simulator (…)` tasks start the simulator
without deploying first.

### Simulator path

The simulator executable is taken from the `rfsuite.simulatorPath` setting, so no task
definition has to be edited when a Companion release moves. Set it once in your **User
Settings** (`Ctrl+Shift+P` → `Preferences: Open User Settings (JSON)`):

```json
{
  "rfsuite.simulatorPath": "<the simulator executable shipped with EdgeTX Companion>"
}
```

That is `simulator.exe` in Companion's `bin` folder on Windows, and the `simulator` binary
beside Companion elsewhere. Backslashes have to be escaped in JSON.

### Radio SD card path

`RFSuite: Deploy to Radio` auto-detects mounted radio storage. If it picks the wrong volume, or
finds none, set the SD card root explicitly:

```json
{
  "rfsuite.radioSdPath": "<the mounted radio storage>"
}
```

This must be the root of the mounted storage — the folder that holds `SCRIPTS`, not `SCRIPTS`
itself.

### Deploy language

Deploys resolve their language from `rfsuite.deploy.language`, read from workspace settings,
the workspace file, user settings or a settings profile, in that order, and falling back to
`en`:

```json
{
  "rfsuite.deploy.language": "en"
}
```


## Building the installation archive

The archive builder is `bin/package/build_package.py`; `package.cmd` and `package.sh` are thin
local wrappers around it.

```bash
cd bin/package
./package.sh en 0.1.0-local        # or: package.cmd en 0.1.0-local
```

Both arguments are optional and default to `en` and `local-test`. The result is
`rfsuite-radio-install-v<version>_<lang>.zip` next to the script.

The build stages the deployed layout in a temporary folder, generates the dashboard theme index
from the themes it finds, resolves the i18n markers for the chosen language, and zips the
result. Bytecode (`.luac`) is never packaged.


## Localization

User-visible strings are never written into the code. A source carries an `@i18n(key)@` marker,
or calls `i18n.t(key)` at runtime, and the locale bundles in `src/rfsuite/i18n/` hold the text.
Every language present there is a language the packager can build.

Two scripts turn the markers into text at package and deploy time:

- `.vscode/scripts/precompile_i18n.py` collects the strings a page builds dynamically
- `.vscode/scripts/resolve_i18n_tags.py` substitutes the markers from one locale bundle

A key that has no entry in the chosen bundle used to survive into the package as a literal
`@i18n(...)@` marker and show up that way on the radio. Since #286 the build stops instead: the
resolver exits 1 on an unresolved key and the packager refuses to write an archive, so a run
that reaches an unresolved key produces no artefact rather than a card full of markers. The
same applies to a file that needed a change and could not be written.

The precompiler is the step *before* the resolver and is a separate tool: it adds
`@i18n(...)@` markers to source files in place, and it still reports a failed read or write
without failing. Run it on a copy, not on your checkout.

The call forms this covers — the page-local family and the full-key forms beside it — are written
down in [docs/developer/i18n.md](docs/developer/i18n.md).

**A packaged card carries no locale bundle.** `build_package.py` copies `src/rfsuite/` without
`i18n/` and puts back `i18n/init.lua` alone, so on an installed card a runtime `i18n.t(key)` finds
nothing and answers with the key. A pilot therefore sees the **fallback** the precompiler baked
into the marker, and a string the precompiler did not rewrite is English in every locale, whether
or not its key is translated. Three shapes have to hold for a **page-local** call to be rewritten
at all — a call that misses any of them still reads correctly on the desktop, which is what makes
them easy to miss:

- **The call is named `t` or `pageText`** (or `Common.t` for the cross-page form). The precompiler's
  pattern knows those two names and no others -- a wrapper called anything else is a runtime
  lookup, and its callers are what get rewritten, not it.
- **The file offers a prefix to derive**: a `pageT("...")` or `Common.pageT("...")` call, a
  `keyPrefix` local, or a `buildSimplePage` second argument. Without one the whole rewrite block is
  skipped for that file.
- **The fallback is one string literal.** The pattern reads it out of the call; a `..` chain spread
  over several lines is not a string it can take, and a call that has none still resolves as long as
  the key exists in `en.lua` — the resolver falls back to it before it ever reaches an inline
  fallback.

These three sit inside the `if prefix:` block. A **full-key** call such as
`tr("app.msp.unsupported_title", "Unsupported MSP API")` or `i18n.t("some.key")` is rewritten after
it, with no prefix and no particular name — renaming one of those to `t` would break a call that
already works.

The house form that satisfies all three, and the one every other help sheet already uses:

```lua
local t = Common and Common.pageT("<page_prefix>") or function(_, _, fb) return fb end
local someText = t(i18n, "some_key", "The English fallback.")
```

`keyPrefix` is for a module that has no page of its own and borrows another page's block -- it takes
the full form, `keyPrefix = "app.pages.<page_prefix>"`, and the precompiler strips the leading
`app.pages.` back off. Name the block the translation is really in, not the caller's, or the string
resolves for one page and falls through for the rest.

**What a single literal costs:** a long help text joined up with `..` is a few lines under the
140 that `.luacheckrc` names, and flat it is one line of roughly 280. `luacheck src` already reports 992
lines over 140 (the longest 870) and CI does not enforce the line length, so the trade falls on
correctness.
German is not the only language this is about: it is the only one where a pilot can see the
difference without reading English.



## Style

`.luacheckrc` is the style reference: `std = "lua54"`, `max_line_length = 140`,
`unused_args = false`, plus the globals the EdgeTX Lua environment provides. CI runs
`luacheck src --only 111 112 113` (the *Undeclared globals* job): a global that is neither in that
list, nor in the `lua54` standard library, nor declared `local` fails the pull request. An EdgeTX name
goes into the list only if EdgeTX really publishes it -- one that it does not is nil on the radio and
is fixed where it is read. Two entries are not EdgeTX (`system`, `Rf2Runtime`, read only behind a type
guard), and the `lua54` standard names libraries the radio does not load (`os`, `debug`, `coroutine`),
so a pass is not proof that a name exists on the radio. The style warnings (line length, unused
values) are not enforced.

Follow the indentation of the file you are editing and avoid reformatting untouched lines — a
whitespace-only diff buries the change a reviewer is looking for.


## Continuous integration

| Workflow | Trigger | What it produces |
| --- | --- | --- |
| `pr.yml` | pull request | The per-locale installation archives as a build check, plus the instruction-budget gate (`bin/accounting/measure.lua --check`), the i18n precompiler test, the documentation-rule check (`bin/docs/verify_documentation_rule.py`), the translation-coverage report (`bin/i18n/check_translations.py`), the resolver self-test (`.vscode/scripts/resolve_i18n_tags.py --self-test`), the release-notes file check and the release-notes rule (`bin/release/verify_release_notes_rule.py`) |
| `checks.yml` | called by the workflows below | The gates, reusable: the instruction budget, the i18n precompiler test, the resolver self-test, the translation-coverage report, the erase confirmation and the release-notes file check. The **documentation rule is deliberately not one of them** — it can be satisfied by a `Documentation:` line in the pull request body, and a push or a tag has no such body, so running it here would have demanded a `docs/` change from a release tag. It lives in `pr.yml`, the only caller that has a body to offer. `push.yml`, `snapshot.yml` and `release.yml` run this as a `needs:` of the job that builds or publishes, so a red gate stops the release. `pr.yml` does not use it — rewriting the workflow that has been protecting master belongs in its own change — so a gate added to `checks.yml` has to be added to `pr.yml` as well |
| `push.yml` | push | The per-locale installation archives, behind the gates in `checks.yml` |
| `snapshot.yml` | tag `snapshot/*` | A snapshot release with the per-locale archives, behind the gates; stops first if a release note is still pending under `release-notes/` |
| `release.yml` | tag `release/*` | A GitHub release, with notes extracted from `Releases.md`, behind the gates; stops first if a release note is still pending under `release-notes/` |
| `testing.yml` | tag `testing/*` | A raw `src` artifact, then deletes the tag again. Ships no archive and runs no gate |
| `docs.yml` | pull request or push touching `docs/`, `mkdocs.yml` or `bin/docs/` | The documentation site, built with `mkdocs build --strict`; on master it is published with GitHub Pages |

The dashboard voltage-bounds regression check runs in both `pr.yml` and `checks.yml`:

```sh
lua5.3 bin/dashboard/verify_voltage_bounds.lua --verbose
```

It reloads the real dashboard runtime against the accounting firmware/FC stubs and checks
17 controlled cases: voltage encodings, held/configured cell-count priority, missing or invalid
configuration, absent or small pack voltage, the legacy session alias and saved voltage bounds.
To prove the check detects the original defect, pass a pre-fix runtime source with
`--runtime <file>`; the same expectations must fail. The check does not measure hardware or timing.

The dashboard fullscreen-key regression check also runs in both workflows:

```sh
lua5.3 bin/dashboard/verify_fullscreen_keys.lua --self-test
lua5.3 bin/dashboard/verify_fullscreen_keys.lua
```

It loads the real key resolver and view router, then checks the PAGE, SYS and TELE defaults (the
page keys on Urban, on a base layer that binds nothing as Default's, and without a base layer), that a key on Theme does only what the
theme binds, the PAGE navigation over open views, radio-wide choices on top of a view, Nothing
consumption and operation before a theme base exists. It loads the real Urban, Grid and Deck
layouts and checks that a stored PAGE choice is what they bind. It loads the real Keys page and
checks that it shows the defaults and stores only the choices that differ from them. It also loads
the real runtime and checks that leaving fullscreen cancels pending fullscreen builds and splashes
before their job step can run. The self-test changes the radio-wide branch, drops the SYS and the
PAGE > default, makes each theme layout ignore the stored choice, makes the page store Theme as
absent and disables the early exit guard; each mutation must turn its own case red.

The Urban, Grid and Deck Keys page check runs beside it in both workflows:

```sh
lua5.3 bin/dashboard/verify_theme_global_keys.lua --self-test
lua5.3 bin/dashboard/verify_theme_global_keys.lua
```

It loads the real Urban, Grid and Deck configure, layout and init modules and the real key
resolver. Per theme it builds the Keys page over key choices an earlier version stored, and checks
that the page starts unbound, marks the keys the radio-wide page holds (PAGE, SYS and TELE as
the radio comes), saves a choice in radio and
model scope without touching the old fields, and that the layout binds only the new fields, which
act only while the radio-wide choice is Theme. The self-test makes the layout read the old fields,
gives the theme a SYS or PAGE default again, leaves an explicit PAGE Quick menu choice unbound,
and removes the held mark; each must turn a case red in all three themes. Both PAGE directions,
put on Theme radio-wide, start on Nothing and can save, reload and clear an explicit Quick menu binding in either scope.
Controls and preference-card writes are stubbed; native touch delivery is outside this offline check.

The SmartFuel validity check runs in both `pr.yml` and `checks.yml`:

```sh
lua5.3 bin/smartfuel/verify_invalid_max.lua
lua5.3 bin/smartfuel/verify_readers.lua
```

It checks local estimation against controlled sensor/configuration inputs, including loss and
recovery of a valid maximum cell voltage, stale-value suppression and known-count priority.
The reader checks exercise the dashboard, home screen and already-built diagnostic labels,
including recovery without a page rebuild. Both checks run offline with desktop Lua 5.3;
they do not measure radio timing or hardware behavior.

The flight-record absent-source check runs in both `pr.yml` and `checks.yml`:
`lua5.3 bin/telemetry/verify_flight_record_absent.lua`. It checks missing and late sensors,
session reset, the powered gate and the dashboard's armed statistic reader against the real
modules. Pass `--record <file>` or `--common <file>` to check a pre-fix source with the same
expectations. It runs offline with desktop Lua 5.3 and does not measure radio timing.

Release notes wait under `release-notes/`, one file per pull request, until the release is cut:
`python bin/release/collect_release_notes.py` files them under the version in
`src/rfsuite/lib/version.lua`, and the result is committed before the tag. The format is in
[release-notes/README.md](release-notes/README.md).

A release tag of the form `release/<x>.<y>.<z>-<suffix>` is published as a Release Candidate;
without the suffix it is published as a Release. The version baked into the package itself
comes from `src/rfsuite/lib/version.lua`.


The in-flight trim-routing check compares 12,288 switch masks against the original lookup
algorithm, including remapped/missing trims and navigation mode. It also exercises sliced discovery,
legacy migration, settings invalidation and disabled inputs. Run
`lua5.3 bin/dashboard/verify_inflight_trims.lua`. Pass `--drive <file>` with the previous drive
implementation to prove the repeated-lookup check goes red.

The grouped in-flight tuning check runs beside it:
`lua5.3 bin/dashboard/verify_inflight_groups.lua`. It checks Standard/Custom groups and hidden
addresses, missing flight-list ids, unread/unknown profile refusals and automatic return-to-read
resume, replaceable 700 ms speech, encoder callback deduplication/busy refusal and RTN level-back.
The companion profile verifier checks staged ground publication, crossed profiles, arming and per-profile delta caching.
Native LVGL focus/scroll delivery and physical callbacks per detent still require a bench run.

`lua5.3 bin/dashboard/verify_inflight_flightlist.lua` checks the real flight-list controls,
MCU-keyed save/refusal, missing IDs, all/subset round trips and both help sheets' length limits.

## Documentation

`docs/` holds the user-facing reference: one file per configuration page under `docs/pages/`,
mirroring the layout of `src/rfsuite/app/pages/`, plus the dashboard, audio, reference,
troubleshooting and developer sections. It is plain Markdown, versioned with the code, and it
is not part of the installation archive: the packager stages `src/` only, so nothing in
`docs/` reaches a radio.

Every change a pilot can observe is documented in the same pull request that makes it. The
rule is in [CONTRIBUTING.md](CONTRIBUTING.md) under *Documentation*, beside the rule for
`Releases.md`. The page
template is `docs/_template.md`, and `docs/pages/README.md` lists every page with whether its
file is written yet.

The same files are also published as a website with search and a navigation tree, built by
MkDocs from `mkdocs.yml` at the root. `bin/docs/mkdocs_hooks.py` points a link that leaves
`docs/` at the file on GitHub, lists the files under `docs/pages/` in the menus, order and
titles of `src/rfsuite/app/manifest.lua` (through `bin/docs/menu_structure.py`), and
orders every other section by `sidebar_position`. To preview it:

```
pip install -r bin/docs/requirements.txt
mkdocs serve
```

`mkdocs build --strict` is what the `docs.yml` workflow runs; it fails on a link the site
cannot resolve.


## Sensor tool

`bin/sensors/` holds a small GUI that feeds telemetry into the simulator, so dashboard themes
and telemetry pages can be worked on without a flight controller. It writes per-sensor Lua
files into the simulator target and supports fixed values, sliders, dropdowns and random
variance. Its own notes are in `bin/sensors/README.md`; rebuild it with the
`Sensors: Build Tool` task.

The multi-profile inflight verifier (`lua5.3 bin/dashboard/verify_inflight_profiles.lua`)
models ground-only selection/read/restore, sliced SD snapshots, FC identity refusal,
per-profile report ownership and original-pair return on aborts. It also checks actual
API read/modify/write field round trips. Native FC/SD acceptance remains a bench check.
