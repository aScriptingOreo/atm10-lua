"""Regenerate packages.json from `-- @` headers in cookienet.lua, lib/*.lua, programs/*.lua.

Header lines (first 20 lines of a file):
  -- @name <pkg>                      default: file name without .lua
  -- @desc <text>
  -- @deps <pkg> [<pkg>...]
  -- @config <Key>|<prompt>[|<default>]   repeatable
Files under programs/ get `main` set (run on boot).
"""
import json, pathlib

root = pathlib.Path(__file__).resolve().parent.parent
files = [root / "cookienet.lua", *sorted((root / "lib").glob("*.lua")), *sorted((root / "programs").glob("*.lua"))]

pkgs = {}
for f in files:
    rel = f.relative_to(root).as_posix()
    p = {"files": [rel]}
    name = f.stem
    for line in f.read_text(encoding="utf-8").splitlines()[:20]:
        if not line.startswith("-- @"):
            continue
        tag, _, val = line[4:].partition(" ")
        val = val.strip()
        if tag == "name": name = val
        elif tag == "desc": p["desc"] = val
        elif tag == "deps": p["deps"] = val.split()
        elif tag == "config":
            k, prompt, *d = val.split("|")
            p.setdefault("config", []).append({"key": k, "prompt": prompt, **({"default": d[0]} if d else {})})
    if rel.startswith("programs/"):
        p["main"] = rel
    if name in pkgs:
        raise SystemExit(f"duplicate package name {name!r} ({rel})")
    pkgs[name] = p

# stable key order so diffs stay small
order = ["desc", "deps", "config", "files", "main"]
out = {n: {k: p[k] for k in order if k in p} for n, p in sorted(pkgs.items())}
(root / "packages.json").write_text(json.dumps(out, indent=2) + "\n", encoding="utf-8", newline="\n")
print(f"packages.json: {len(out)} packages ({', '.join(out)})")
