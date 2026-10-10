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

`cookienet get ME_Monitor --boot` on a computer touching (or wired to) an ME Bridge and an advanced monitor.
Bigger monitor = more rows; 70+ characters wide gets a second column. `ScanEvery=0` turns off the item/fluid scan.
A second, smaller monitor on the same computer (wired modem if it isn't touching) becomes a row of fill gauges.

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
