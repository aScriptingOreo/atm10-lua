# atm10-lua

ComputerCraft (CC:Tweaked) scripts for ATM10.

## Install / update (in-game)

```
wget run https://raw.githubusercontent.com/aScriptingOreo/atm10-lua/main/update.lua
```

Re-run `update` any time to pull the latest. Needs `http` enabled on the server.

## Adding a program

1. Put the file under `programs/`.
2. Add its path to `manifest.txt` (one per line). Only listed files get downloaded.
3. Commit + push. Machines get it on next `update`.
