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

`cookienet get Butler --boot` on a computer touching an ME Bridge and an advanced monitor (3x2 blocks or bigger;
any sides). Everything is set up by right-clicking the monitor:

- **HOME**: busy crafting CPUs, stock rules that are not satisfied, and what Butler crafted / trashed lately.
- **STOCK**: autocraft an item while it is below `keep`. `/2` `x2` change keep, `BULK`/`1x1` switches blocking.
- **TRASH**: export what is above `keep` out the bridge side `TrashDir`. New rules start `OFF` at the current count.
- **ADD**: pick from craftable items (-> stock) or stored items (-> trash), filtered by first letter.
- `ACTIVE`/`PAUSED` in the title bar stops all crafting and trashing.

Rules and the log live in `/butler.json` on the computer (not in this repo, updates never touch it). Stop Butler
before editing it by hand:

```json
{ "stock": { "minecraft:glass": 256,
             "ae2:fluix_crystal": { "keep": 1024, "batch": 256 },
             "minecraft:netherite_upgrade_smithing_template": { "keep": 16, "blocking": true } },
  "trash": { "minecraft:rotten_flesh": 0 } }
```

`blocking` crafts one at a time, each job waiting for the last: use it for cyclical recipes that consume their own
output (1 template -> 2), which AE2 cannot plan in bulk. `batch` caps one request for everything else.

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
