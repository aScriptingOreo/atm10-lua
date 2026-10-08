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

## Adding a package

1. Put files in the repo (programs under `programs/`).
2. Add an entry to `packages.json`: `files` (what to download), `main` (what to run on boot), optional `deps`
   (other packages) and `config` (`key`/`prompt`/`default` asked on `get`). Programs read config with
   `local cfg = dofile("/lib/cn.lua")` (depend on `cn_lib`).
3. Push. Machines get it on next `cookienet update`.
