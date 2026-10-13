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

## Draconic reactor

`cookienet get DE_Reactor --boot` on one advanced computer. Everything hangs off wired modems (right-click each
one so it turns red); peripherals cannot go over wireless.

- modems on the reactor parts: any or all of the stabilizers and the injector. Each is a door to the same core,
  so with all five on the network a broken part or a pulled modem does not cost control;
- a modem on **every flux gate**: one gate feeding the injector, one or more draining the stabilizers.
  The reactor parts cannot set any power flow themselves, the gates are the only controls;
- no other flux or fluid gates on that modem network: every gate that is not the input is treated as an output;
- optional advanced monitor, any size.

`S` or the START button charges it, starts it at 2000 C and brings it to `TargetTemp`. `X` / STOP shuts it down.
Which gate is the input is worked out on the first charge (it is the only one that can move power then) and kept
in `/.de_reactor_in`. After a reboot the script carries on with whatever the reactor was doing.

Settings (`cookienet config TargetTemp=7500`, then reboot): `TargetTemp` 8000, `TargetField` 50, `StopAt` 90,
`ChargeRate` 5000000, `InGate` auto, `TextScale` 1.

At 8000 C a full core (8 awakened blocks) makes about 5.4M RF/t fresh, rising to roughly 24M as the fuel converts,
and spends 1.6M to 2.4M of it on the field.

### What blows it up, and what the script does about it

The field reaching 0 above 2000 C is the only way it explodes, and the server has `disableLargeReactorBoom=false`,
so that is the big one. The script shuts the reactor down (stopping ends all output, the core fills, the drain on
the field drops to a hundredth) when:

- the field is under half of `TargetField`, the temperature is over 9000, or `StopAt` % of the fuel is converted;
- the core drains although the gates are throttled: a stabilizer is feeding something that is not a gate;
- a flux gate leaves or joins the network while it runs, or the input gate is unknown;
- it has had no control at all for 10 s (parts or gates unreachable).

Three things it cannot save. Get them right before the first start:

1. **Behind every stabilizer: a flux gate, or nothing.** While running, a stabilizer pushes the whole core into
   the block behind it every tick. A cable, pylon or energy cell there takes it all. Present at start-up this is
   caught at 2000 C and stopped; wired onto a hot reactor, an unlimited taker empties it in under a second.
2. **The injector's supply must not run dry.** With the field at 50% and the input gone, a full reactor has about
   two seconds. Feed the input gate from storage the reactor's own output refills. Half-second cuts are ridden out.
3. **Keep it all in force-loaded chunks, together:** core, stabilizers, injector, every gate, the computer and
   whatever powers the input gate (FTB Chunks: claim, then force-load). A reactor that unloads as a whole just
   freezes, which is safe. One that keeps ticking while its injector, a gate or its power source is unloaded is
   not. With only the computer gone the gates hold their last flows: fine for days, then it overheats as the fuel
   runs out.

The computer updates itself from this repo on every boot (`cookienet update`), reactor script included.

Remote: put a wireless or ender modem on the reactor computer and on the Butler computer. Butler gets a `REACTOR`
tab on its own screen: gauges, five minutes of temperature and field history, the reactor's last log line, and
`S` / `X` to start and stop it. Control stays on the reactor computer: if the link drops the tab says NO SIGNAL
and the reactor carries on.

Alarm: the `REACTOR` tab turns red from any tab, and a speaker on the Butler computer (any side, or on its wired
network) sounds. Fast two-tone = field under half its target, over 8500 C, or meltdown. One beep every 2 s = it
shut itself down (15 s), or the reactor computer went quiet while the reactor was live. `M` in the tab mutes
until the alarm clears.

`python tools/test_de_reactor.py` (needs `pip install lupa`) runs the script against a port of the reactor's tick.

## ME monitor

`cookienet get ME_Monitor --boot` on every computer that has an advanced monitor; all of them need a modem.
The computer with the ME Bridge is the main: it polls and broadcasts (rednet `me_monitor`). The others just draw.
`View` auto shows fill gauges on a short strip and the full dashboard on a big monitor; force one with
`cookienet config View=dashboard` (or `gauges`).
The top items/fluids lists and the activity feed need a full item scan, which runs on the server thread and can stall a
big network for minutes (it crashed the server once). So it is off by default: `cookienet config ScanEvery=300` turns it on.
Scans slow themselves down (about 1% of server time), and one that takes over 3 s switches the scan off for good by
writing `/.me_monitor_scan_off`; delete that file to try again.
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
