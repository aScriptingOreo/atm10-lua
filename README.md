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
cookienet get <pkg>... [--boot]   install; --boot runs it on startup (auto-updates first)
cookienet rm <pkg>...             uninstall
cookienet update [pkg...]         re-pull installed packages (all if none given)
cookienet boot <pkg|off>          set or clear the startup program
```

## Reactor setup

- Sensor computer: `cookienet get reactor_sensor --boot`
- RS Bridge computer: `cookienet get reactor_rs --boot`

## Adding a package

1. Put files in the repo (programs under `programs/`).
2. Add an entry to `packages.json`: `files` (what to download) and `main` (what to run on boot).
3. Push. Machines get it on next `cookienet update`.
