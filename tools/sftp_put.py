"""Upload files to the server root over SFTP, one connection per file, live per-connection table.

    python tools/sftp_put.py backups/parts/restore_part*.tar.gz

Creds from .env (SFTP_HOST/PORT/USER/PASS). Overwrites remote files of the same name.
Each file retries from scratch up to 3 times (the host truncates on reopen, so no byte-resume).
"""
import glob, os, sys, threading, time
import paramiko

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
env = {}
for l in open(os.path.join(ROOT, ".env")):
    if "=" in l and not l.startswith("#"):
        k, v = l.strip().split("=", 1)
        env[k.strip()] = v.strip().strip('"').strip("'")

files = [f for a in sys.argv[1:] for f in sorted(glob.glob(a))]  # PowerShell doesn't expand globs
if not files:
    sys.exit("usage: python tools/sftp_put.py FILE_OR_GLOB...")

rows = [{"name": os.path.basename(f), "size": os.path.getsize(f), "done": 0,
         "state": "queued", "t0": None, "t1": None} for f in files]

def connect():
    t = paramiko.Transport((env["SFTP_HOST"], int(env["SFTP_PORT"])))
    t.connect(username=env["SFTP_USER"], password=env["SFTP_PASS"])
    return paramiko.SFTPClient.from_transport(t)

def up(path, r):
    for attempt in range(1, 4):
        r["state"], r["done"], r["t0"] = f"connecting #{attempt}", 0, time.time()
        try:
            c = connect()
            r["state"] = f"uploading #{attempt}"
            c.put(path, r["name"], callback=lambda d, _: r.__setitem__("done", d))  # put() verifies size
            c.close()
            r["state"], r["t1"] = "OK", time.time()
            return
        except Exception as e:
            r["state"] = f"err #{attempt}: {e!r}"[:40]
            time.sleep(2)
    r["state"] = "FAILED " + r["state"]

def draw(first):
    out = []
    tot = sum(r["size"] for r in rows); dn = sum(r["done"] for r in rows)
    for r in rows:
        el = ((r["t1"] or time.time()) - r["t0"]) if r["t0"] else 0
        mbs = r["done"] / el / 1e6 if el else 0
        pct = 100 * r["done"] / r["size"] if r["size"] else 100
        out.append(f"{r['name']:<28} {r['done']/1e6:8.1f}/{r['size']/1e6:8.1f} MB {pct:5.1f}% {mbs:5.2f} MB/s  {r['state']:<40}\x1b[K")
    out.append(f"{'TOTAL':<28} {dn/1e6:8.1f}/{tot/1e6:8.1f} MB {100*dn/tot:5.1f}%\x1b[K")
    out.append("\x1b[K")
    up_ = "" if first else f"\x1b[{len(out)}F"  # cursor back up to redraw in place
    print(up_ + "\n".join(out), flush=True)

os.system("")  # enables ANSI escapes in the Windows console
ts = [threading.Thread(target=up, args=(f, r), daemon=True) for f, r in zip(files, rows)]
for t in ts: t.start()
draw(True)
while any(t.is_alive() for t in ts):
    time.sleep(1); draw(False)
draw(False)
bad = [r["name"] for r in rows if r["state"] != "OK"]
print(f"{len(rows) - len(bad)}/{len(rows)} OK" + (f", FAILED: {' '.join(bad)}" if bad else ""))
sys.exit(1 if bad else 0)
