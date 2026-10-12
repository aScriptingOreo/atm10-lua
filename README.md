# atm10-lua

ComputerCraft (CC:Tweaked) scripts for ATM10, installed with `cookienet`, a small package manager.
The registry is `packages.json` in this repo. Needs `http` enabled.

## Install (once per computer)

```
wget run https://raw.githubusercontent.com/aScriptingOreo/atm10-lua/main/install.lua
```

## Commands

```
cookienet list                    packages available (* = installed)
cookienet get <pkg>... [K=V...] [--boot]
                                  install; asks for any config it needs; --boot runs it on startup
cookienet config [K=V...]         show / set this computer's config
cookienet rm <pkg>...             uninstall
cookienet update [pkg...]         re-pull installed packages (all if none given)
cookienet boot <pkg|off>          set or clear the startup program
```

## Reactor setup

- Sensor computer: `cookienet get reactor_sensor ReactorName=main --boot`
- RS Bridge computer: `cookienet get reactor_rs ReactorName=main --boot`

`ReactorName` pairs a sensor with its RS computer (rednet protocol `reactor:<name>`). Use a different name per
reactor to run several setups side by side. Other prompts (sides, pellet id) have defaults; press Enter to accept.
Change later with `cookienet config InSide=left`, then `reboot`.

## ME monitor

`cookienet get ME_Monitor --boot` on every computer that has an advanced monitor; all of them need a modem.
The computer with the ME Bridge is the main: it polls and broadcasts (rednet `me_monitor`). The others just draw.
`View` auto shows fill gauges on a short strip and the full dashboard on a big monitor; force one with
`cookienet config View=dashboard` (or `gauges`). `ScanEvery=0` on the main turns off the item/fluid scan.
The activity feed lists what changed between two scans, so a lower `ScanEvery` makes it livelier (and costs the server more).
Right-click a dashboard monitor for the next page.

## Butler (ME system manager)

`cookienet get Butler --boot` on a computer touching an ME Bridge and an advanced monitor (any sides, 3x2 blocks
or bigger). It autocrafts every item that is below its `keep` count.

On the computer (Tab or a click switches tab):

- **LOG**: one line each time a rule changes state.
- **STOCK**: the rules. Arrows to pick one, then `Enter` edit keep (0 removes the rule), `O` on/off, `L` loop/bulk, `Del` twice to delete,
  `P` pause or resume all crafting. A refused craft shows what it was missing.
- **MANAGE**: type to search the craftable items ("unob temp" finds the Unobtainium template). Click a result, or
  arrows + Enter, then type how many to keep and press Enter. Picking an item that already has a rule edits it.

The monitor is a read-only crafting dashboard: busy CPUs, rules that are not satisfied, and what Butler crafted lately.

Monitor text size: `cookienet config TextScale=1` (0.5 to 5 in steps of 0.5), then reboot the computer.

### Rules

Rules come from two places:

- `programs/Butler.json` in this repo. Butler re-fetches it every `Sync` seconds (default 60; GitHub caches the
  file, so a push lands within about 5 minutes). No reboot. On a wide monitor the title bar shows the last fetch.
- The computer and the monitor. Edits are kept in `/butler.json` on the computer, with the log.

The repo only overrides a rule when the repo changed it: a new or edited rule is applied, a rule removed from the
file is deleted, and an untouched one keeps whatever was done to it in game.

```json
{ "stock": { "minecraft:glass": 256,
             "ae2:fluix_crystal": { "keep": 4096, "batch": 512 },
             "extendedae:entro_crystal": { "keep": 16384, "blocking": true } } }
```

- `keep`: minimum count in the network. A bare number is shorthand for `{ "keep": N }`.
- `batch`: most to request in one job.
- `blocking` (`LOOP` on the monitor): the recipe is a cycle, its ingredients are made from the item itself.
  Requests are sized from the current stock, at most double it per job.
- `off`: rule exists but does nothing.

### What happens when AE2 refuses a job

AE2 plans all or nothing, and it never uses stored copies of the item being requested as an ingredient.
So when a job comes back with missing items, Butler:

1. crafts the missing ingredient first if it has a pattern (status `PREP`), then asks for the item again. This is
   what makes a cycle work: asking for crystals fails on "missing dust" however many crystals are stored, but
   asking for the dust is a different job that is allowed to crush the crystals;
2. halves whatever still does not fit (N/2, N/4, ...) until a job is accepted, and doubles back up after a success;
3. gives up for a minute at 1 (`MISSING`, with the item it lacks).

Two things stop it: `SELF LOOP` means the recipe takes the item itself (1 smithing template -> 2), which AE2
cannot plan at any amount, so that needs a setup outside AE2 autocrafting. And if a trip round a cycle ends with no
more than it started with, Butler stops feeding it until the stock level changes.

## Adding a package

1. Put files in the repo (programs under `programs/`).
2. Put `-- @desc` (and `@deps`, `@config`) header lines at the top; `git commit` regenerates `packages.json`.
   Programs read config with `local cfg = dofile("/lib/cn.lua")` (add `-- @deps cn_lib`).
3. Push. Machines get it on next `cookienet update`.

## Registry is generated

`packages.json` is built from `-- @` header comments in each script (`@name`, `@desc`, `@deps`, `@config Key|prompt|default`)
by `tools/build.py`. Don't edit it by hand. Enable the commit hook once per clone so it stays current:

```
git config core.hooksPath tools/hooks
```
