"""Runs programs/DE_Reactor.lua (the real file, via lupa) against a port of the reactor's tick.

    pip install lupa && python tools/test_de_reactor.py

The Reactor class is TileReactorCore from Draconic Evolution 3.1.4.633, read off the jar's bytecode
(updateOnlineState, updateOfflineState, initializeStartup, injectEnergy, can*). If DE changes its maths,
this is the thing to re-port.
"""
import pathlib, random, sys
import lupa

SCRIPT = (pathlib.Path(__file__).resolve().parent.parent / "programs" / "DE_Reactor.lua").read_text(encoding="utf-8")


class Reactor:
    def __init__(self, fuel=10368.0, conv=0.0, out_mult=1.0, fuel_mult=1.0):
        self.state = "cold"
        self.reactable, self.converted = fuel * (1 - conv), fuel * conv
        self.temp, self.shield, self.max_shield, self.sat, self.max_sat = 20.0, 0.0, 0.0, 0, 0
        self.gen = self.drain = self.fuel_rate = 0.0
        self.init = False
        self.out_mult, self.fuel_mult = out_mult, fuel_mult

    def tick(self):
        s = self.state
        if s in ("cold", "cooling"):
            self.offline()
            if s == "cooling" and self.temp <= 100: self.state = "cold"
        elif s == "warming_up":
            if not self.init:
                fuel = self.reactable + self.converted
                self.max_shield = fuel * 96.45061728395062 * 100
                self.max_sat = int(fuel * 96.45061728395062 * 1000)
                self.sat, self.shield = min(self.sat, self.max_sat), min(self.shield, self.max_shield)
                self.init = True
        elif s == "running":
            self.online()
        elif s == "stopping":
            self.online()
            if self.temp <= 2000: self.state = "cooling"

    def offline(self):
        if self.temp > 20: self.temp -= 0.5
        self.shield = max(0.0, self.shield - self.max_shield * 0.0005 * random.random())
        self.sat = max(0, self.sat - int(self.max_sat * 0.000002 * random.random()))

    def online(self):
        core_sat = self.sat / self.max_sat
        neg = (1 - core_sat) * 99
        t50 = min(self.temp / 10000 * 50, 99)
        conv = self.converted / (self.converted + self.reactable) * 1.3 - 0.3
        rise_expo = neg ** 3 / (100 - neg) + 444.7
        resist = t50 ** 4 / (100 - t50)
        rise = (rise_expo - resist * (1 - conv) + conv * 1000) / 10000
        if self.state == "stopping" and conv < 1:
            if self.temp <= 2001:
                self.state, self.init = "cooling", False
                return
            if self.sat >= self.max_sat * 0.99 and self.reactable > 0: self.temp -= 1 - conv
            else: self.temp += rise * 10
        else:
            self.temp += rise * 10
        base = int(self.max_sat / 1000 * self.out_mult * 1.5 * 10)
        self.gen = (1 - core_sat) * int(base * (1 + conv * 2))
        self.sat += int(self.gen)
        t = self.temp
        tdf = 1 + (t - 8000) ** 2 * 0.0000025 if t > 8000 else 1 if t > 2000 else (t - 1000) / 1000 if t > 1000 else 0
        self.drain = int(min(tdf * max(0.01, 1 - core_sat) * (base / 10.923556), 2147483647))
        self.shield -= min(self.drain, self.shield)
        self.fuel_rate = tdf * (1 - core_sat) * 0.001 * self.fuel_mult * 5
        if self.reactable > 0:
            self.converted += self.fuel_rate
            self.reactable -= self.fuel_rate
        if self.shield <= 0 and self.temp > 2000: self.state = "beyond_hope"

    def inject(self, energy):
        if self.state == "warming_up":
            if not self.init: return
            if self.shield < self.max_shield / 2:
                self.shield = min(self.shield + min(energy, int(self.max_shield / 2) - int(self.shield) + 1), self.max_shield / 2)
            elif self.sat < self.max_sat // 2:
                self.sat += min(energy, self.max_sat // 2 - self.sat)
            elif self.temp < 2000:
                self.temp = min(2500.0, self.temp + energy / (1000 + self.reactable * 10))
        elif self.state in ("running", "stopping"):
            f = 1 - min(1, (self.temp - 15000) / 10000) if self.temp > 15000 else 1
            self.shield += min(energy * (1 - self.shield / self.max_shield), self.max_shield - self.shield) * f
            self.shield = min(self.shield, self.max_shield)

    def extract(self, energy):
        if self.state != "running": return
        self.sat -= min(energy, self.sat)

    # what the peripheral hands to Lua
    def info(self):
        return {
            "temperature": round(self.temp, 2), "fieldStrength": round(self.shield, 2), "maxFieldStrength": round(self.max_shield, 2),
            "energySaturation": self.sat, "maxEnergySaturation": self.max_sat, "fuelConversion": round(self.converted, 3),
            "maxFuelConversion": self.reactable + self.converted, "generationRate": int(self.gen), "fieldDrainRate": self.drain,
            "fuelConversionRate": int(round(self.fuel_rate * 1e6)), "status": self.state, "failSafe": False,
        }

    def charge(self):
        if self.state in ("cold", "cooling") and self.reactable + self.converted >= 144: self.state = "warming_up"

    def activate(self):
        s = self.state
        if s in ("warming_up", "stopping") and self.temp >= 2000 and (
                (self.sat >= self.max_sat // 2 and self.shield >= self.max_shield / 2) or s == "stopping"):
            self.state = "running"

    def stop(self):
        if self.state in ("running", "warming_up"): self.state = "stopping"


PRELUDE = """
local cfgTable, gateNames, files = ...
colours = setmetatable({}, { __index = function() return 1 end })
keys = { s = "s", x = "x" }
local inputCo, inPar = nil, false
local function tick(n)
  for _ = 1, n do
    local ev = py_tick()
    if ev == "END" then error("Terminated", 0) end
    if ev then coroutine.resume(inputCo, "key", keys[ev]) end
  end
end
sleep = function(s) tick(math.max(1, math.floor(s * 20))) end
local reactor = {
  getReactorInfo = function() local i = py_info() tick(1) return i end,
  chargeReactor = function() py_cmd("charge") tick(1) end,
  activateReactor = function() py_cmd("activate") tick(1) end,
  stopReactor = function() py_cmd("stop") tick(1) end,
}
peripheral = {
  find = function(t) if t == "draconic_reactor" then return reactor end end,
  getNames = function() local t = { "left", "monitor_9" } for _, n in ipairs(gateNames) do t[#t + 1] = n end return t end,
  hasType = function(n, t) return t == "flow_gate" and n:find("^flux_gate") ~= nil end,
  call = function(n, m, v) py_gate(n, m, v) if not inPar then tick(1) end end,
}
parallel = {
  waitForAll = function(...) inPar = true for _, f in ipairs({ ... }) do f() end inPar = false tick(1) end,
  waitForAny = function(control, input) inputCo = coroutine.create(input) coroutine.resume(inputCo) control() end,
}
os.pullEvent = coroutine.yield
fs = {
  exists = function(p) return files[p] ~= nil end,
  open = function(p) return { readAll = function() return files[p] end, write = function(s) files[p] = s end, close = function() end } end,
}
dofile = function() return cfgTable end
local stub = setmetatable({ getSize = function() return 51, 19 end }, { __index = function() return function() end end })
term = { current = function() return stub end }
window = { create = function() return stub end }
"""


def run(ticks, reactor=None, gates=("flux_gate_0", "flux_gate_1"), cfg=None, events=None, power=1e12, saved_in="flux_gate_0",
        flow=None):
    """Gate 0 is the real input, the others drain. Returns (reactor, stats)."""
    r = reactor or Reactor()
    flow = flow or {g: {"flow": 0, "on": False} for g in gates}
    events = events or {}
    st = {"t": 0, "max_temp": 0.0, "min_field": 1.0, "min_sat": 1.0, "ran": 0, "settled": None}

    def py_tick():
        st["t"] += 1
        if st["t"] > ticks: return "END"
        for name, g in flow.items():
            f = g["flow"] if g["on"] else 0
            if name == gates[0]: r.inject(min(f, power))
            else: r.extract(f)
        r.tick()
        if r.state == "running":
            st["ran"] += 1
            st["max_temp"] = max(st["max_temp"], r.temp)
            st["min_field"] = min(st["min_field"], r.shield / r.max_shield)
            st["min_sat"] = min(st["min_sat"], r.sat / r.max_sat)
        assert r.state != "beyond_hope", f"exploded at tick {st['t']}: {r.info()}"
        return events.get(st["t"])

    def py_gate(name, method, v):
        if method == "setFlowOverride":
            assert v == int(v) and v >= 0, v
            flow[name]["flow"] = int(v)
        elif method == "setOverrideEnabled": flow[name]["on"] = bool(v)
        else: raise AssertionError(method)

    lua = lupa.LuaRuntime(unpack_returned_tuples=True)
    g = lua.globals()
    g.py_tick, g.py_gate = py_tick, py_gate
    g.py_info = lambda: lua.table_from(r.info())
    g.py_cmd = lambda c: getattr(r, c)()
    files = lua.table_from({"/.de_reactor_in": saved_in} if saved_in else {})
    lua.execute("local f = ... ; _G.__pre = load(f)", PRELUDE)
    g.__pre(lua.table_from(cfg or {}), lua.table_from(list(gates)), files)
    try:
        lua.execute(SCRIPT)
    except lupa.LuaError as e:
        assert "Terminated" in str(e), e
    st["files"], st["flow"] = dict(files), flow
    return r, st


def test_cold_start():
    r, st = run(8000, events={5: "s"})
    assert r.state == "running", r.state
    assert 7900 < r.temp < 8010, r.temp
    assert st["max_temp"] < 8050, st
    assert st["min_field"] > 0.45 and st["min_sat"] > 0.10, st
    assert abs(r.shield / r.max_shield - 0.5) < 0.01
    print(f"cold start: {r.temp:.0f} C, field {r.shield / r.max_shield:.1%}, sat {r.sat / r.max_sat:.1%}, "
          f"gen {r.gen / 1e6:.2f}M, in {st['flow']['flux_gate_0']['flow'] / 1e6:.2f}M RF/t, peak {st['max_temp']:.0f} C")


def test_stays_cold_until_asked():
    r, _ = run(200)
    assert r.state == "cold"


def test_stop_and_restart():
    r, st = run(16000, events={5: "s", 6000: "x"})
    assert r.state in ("cooling", "cold"), r.state
    r, st = run(9000, events={5: "s", 6000: "x", 6200: "s"})
    assert r.state == "running" and 7900 < r.temp < 8010, (r.state, r.temp)


def test_reboot_while_running():
    r, _ = run(6000, events={5: "s"})
    # fresh script, reactor already running: carries on. The gates start closed here (real ones keep their
    # flow), so this is also the worst takeover: nothing in or out until the first write.
    r, st = run(3000, reactor=r)
    assert r.state == "running" and 7900 < r.temp < 8010 and st["min_field"] > 0.48, (r.temp, st)


def test_finds_input_gate():
    r, st = run(8000, gates=("flux_gate_7", "flux_gate_2", "flux_gate_4"), events={5: "s"}, saved_in=None)
    assert st["files"]["/.de_reactor_in"] == "flux_gate_7", st["files"]
    assert r.state == "running" and 7900 < r.temp < 8010, (r.state, r.temp)
    assert st["flow"]["flux_gate_2"]["flow"] == st["flow"]["flux_gate_4"]["flow"] > 0


def test_unknown_gate_while_running_touches_nothing():
    r, st = run(6000, events={5: "s"})
    before = {k: dict(v) for k, v in st["flow"].items()}
    r, st = run(400, reactor=r, saved_in=None, flow=st["flow"])
    assert st["flow"] == before and r.state == "running", st["flow"]


def test_no_power_never_activates():
    r, st = run(600, events={5: "s"}, power=0, saved_in=None)
    assert r.state == "warming_up" and "/.de_reactor_in" not in st["files"]


def test_whole_fuel_load():
    # fuel burns 300x faster: 0 -> 90% in a few minutes of ticks, far harsher than the real 30 hours
    r, st = run(60000, reactor=Reactor(fuel_mult=300), events={5: "s"})
    used = r.converted / (r.converted + r.reactable)
    assert r.state in ("cooling", "cold") and 0.90 <= used < 0.92, (r.state, used)
    assert st["max_temp"] < 8100 and st["min_field"] > 0.4, st
    print(f"whole fuel load: stopped at {used:.1%}, peak {st['max_temp']:.0f} C, lowest field {st['min_field']:.1%}")


def test_spent_fuel_refuses_to_start():
    r, _ = run(300, reactor=Reactor(conv=0.93), events={5: "s"})
    assert r.state == "cold"


def test_other_sizes_and_targets():
    for fuel, cfg in ((1296, {}), (5000, {"TargetTemp": "6000", "TargetField": "30"}), (10368, {"TargetTemp": "7000"})):
        r, st = run(9000, reactor=Reactor(fuel=fuel, conv=0.4), cfg=cfg, events={5: "s"})
        target, field = float(cfg.get("TargetTemp", 8000)), float(cfg.get("TargetField", 50)) / 100
        assert r.state == "running" and target - 100 < r.temp < target + 10, (fuel, r.temp)
        assert st["max_temp"] < target + 50 and abs(r.shield / r.max_shield - field) < 0.01, (fuel, st)


def test_wrong_model_is_still_safe():
    # the server's output multiplier is not what the script assumes: the measured cap and the aim-lower rule hold it
    for mult in (0.8, 0.9, 1.1, 1.25):
        r, st = run(12000, reactor=Reactor(out_mult=mult), events={5: "s"})
        assert r.state == "running" and st["max_temp"] < 8300 and st["min_field"] > 0.4 and st["min_sat"] > 0.08, (mult, r.temp, st)
        print(f"output multiplier {mult}: settles at {r.temp:.0f} C, peak {st['max_temp']:.0f} C")


def test_weak_input():
    r, st = run(6000, events={5: "s"})
    need, flow = r.drain, st["flow"]
    # supply sags to 1.6x the drain: the field finds a lower level by itself (37%) and it keeps running
    r, st = run(6000, reactor=r, power=need * 1.6, flow=flow)
    assert r.state == "running" and 0.35 < st["min_field"] < 0.40, (r.state, st)
    # 1.2x the drain cannot hold 25%: it shuts down, and the drain falling as the core fills saves it
    r, st = run(12000, reactor=r, power=need * 1.2, flow=st["flow"])
    assert r.state in ("cooling", "cold"), r.state


if __name__ == "__main__":
    random.seed(1)
    tests = [v for k, v in list(globals().items()) if k.startswith("test_")]
    for t in tests:
        t()
        print("ok", t.__name__)
    print(f"{len(tests)} passed")
