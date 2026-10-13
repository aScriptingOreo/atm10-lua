-- Draconic Evolution reactor controller. One computer on a wired modem network with a reactor part
-- (any stabilizer or the injector) and the flux gates: one feeding the injector, the rest draining the stabilizers.
-- S / X on the computer (or the buttons, also on a monitor) start and stop it. On boot it carries on with
-- whatever the reactor is doing, so a server restart resumes by itself.
--
-- The numbers below are the reactor's own (TileReactorCore, Draconic Evolution 3.1.4.633), not tuning:
--   temperature settles where rise(saturation) = resist(temperature), so one saturation gives one temperature;
--   output drawn = generation at that saturation, which the core then converges to by itself (no overshoot);
--   field input = drain / (1 - field), the exact amount that holds the field where it is.
-- The field hitting 0 above 2000 C is the only thing that blows it up. That happens within a second or two
-- of the injector losing power, and no script can save that: feed the input gate from something that cannot run dry.
-- @desc Draconic Evolution reactor control: holds temperature and field, auto start/stop, shuts down on trouble
-- @deps cn_lib
-- @config TargetTemp|Temperature to hold (8000 = most power before it wastes fuel)|8000
-- @config TargetField|Field % to hold (higher = safer, costs more input)|50
-- @config StopAt|Shut down at this fuel conversion %|90
-- @config ChargeRate|RF/t fed in while warming up|5000000
-- @config InGate|Flux gate feeding the injector (auto = found on the first charge)|auto
-- @config TextScale|Monitor text scale|1
local cfg = dofile("/lib/cn.lua")
local TARGET_TEMP = math.max(2500, math.min(8000, tonumber(cfg.TargetTemp) or 8000)) -- above 8000 drain and fuel use go up with the square
local TARGET_FIELD = math.max(0.2, math.min(0.9, (tonumber(cfg.TargetField) or 50) / 100))
local STOP_AT = math.min(0.95, (tonumber(cfg.StopAt) or 90) / 100) -- past 97% it heats up even at full saturation
local CHARGE = tonumber(cfg.ChargeRate) or 5e6
local SCALE = tonumber(cfg.TextScale) or 1
local MAX_TEMP = 9000              -- shutdown above this (drain is already 3.5x there)
local MIN_FIELD = TARGET_FIELD / 2 -- shutdown below this
local OUTPUT_MULT = 1.0            -- reactorOutputMultiplier in the server's config/brandon3055/DraconicEvolution.cfg
local IN_FILE = "/.de_reactor_in"  -- the input gate found on the first charge; delete to find it again

-- saturation (0..1) at which the temperature settles at `temp`, for conversion level `conv` (-0.3 fresh .. 1 spent)
local function satFor(temp, conv)
  local t50 = math.min(temp / 10000 * 50, 99)
  local rise = t50 ^ 4 / (100 - t50) * (1 - conv) - conv * 1000 - 444.7
  if rise <= 0 then return 1 end
  local lo, hi = 0, 99 -- neg^3 / (100 - neg) only goes up, so bisect
  for _ = 1, 40 do
    local m = (lo + hi) / 2
    if m ^ 3 / (100 - m) < rise then lo = m else hi = m end
  end
  return 1 - lo / 99
end
assert(math.abs(satFor(8000, -0.3) - 0.113) < 0.001 and satFor(2000, -0.3) > 0.99 and satFor(8000, 1) == 1)

local function ratio(a, b) return b and b > 0 and a / b or 0 end

local function fmt(n)
  local u, i = { "", "K", "M", "G", "T" }, 1
  while math.abs(n) >= 1000 and i < #u do n, i = n / 1000, i + 1 end
  return (i == 1 and "%.0f" or "%.2f"):format(n) .. u[i]
end
assert(fmt(999) == "999" and fmt(2.5e6) == "2.50M")

local function dur(sec)
  return ("%.0fh%02.0fm"):format(math.floor(sec / 3600), math.floor(sec % 3600 / 60))
end

local logs = {}
local function log(s)
  if logs[1] and logs[1].s == s then return end -- a condition that persists is one line, not one per cycle
  table.insert(logs, 1, { s = s, t = os.date("%H:%M:%S") })
  logs[41] = nil
end

local inName = cfg.InGate ~= "auto" and cfg.InGate ~= "" and cfg.InGate or nil
if not inName and fs.exists(IN_FILE) then
  local f = fs.open(IN_FILE, "r")
  inName = f.readAll()
  f.close()
end

local reactor, gates, enabled, mons = nil, {}, {}, {}
local function attach()
  reactor = peripheral.find("draconic_reactor") or error("no reactor: put a wired modem on a stabilizer or the injector and right-click it", 0)
  gates, enabled = {}, {}
  local known = false
  for _, name in ipairs(peripheral.getNames()) do
    -- a flux gate shows up as flow_gate or flux_gate (DE registers both, CC takes the first)
    if peripheral.hasType(name, "flux_gate") or peripheral.hasType(name, "flow_gate") then
      gates[#gates + 1] = name
      known = known or name == inName
    end
  end
  table.sort(gates)
  if #gates < 2 then
    error(("found %d flux gates on the network, need 2 or more: one feeding the injector, the rest draining the stabilizers"):format(#gates), 0)
  end
  if inName and not known then error("input gate " .. inName .. " is not on the network (gates: " .. table.concat(gates, ", ") .. ")", 0) end
  mons = { peripheral.find("monitor") }
  for _, m in ipairs(mons) do m.setTextScale(SCALE) end
end

-- all gates in one tick. The flow is written before the override is switched on: a gate that was on
-- redstone control would otherwise drop to whatever its override happened to hold.
local function setFlows(flowOf)
  local jobs = {}
  for i, name in ipairs(gates) do
    jobs[i] = function()
      peripheral.call(name, "setFlowOverride", math.max(0, math.floor(flowOf(name))))
      if not enabled[name] then
        peripheral.call(name, "setOverrideEnabled", true)
        enabled[name] = true
      end
    end
  end
  parallel.waitForAll(table.unpack(jobs))
end

-- Stabilizers only give power while RUNNING, so during warm-up the one gate that moves anything is the input.
local function detect(before)
  for _, cand in ipairs(gates) do
    setFlows(function(n) return n == cand and CHARGE or 0 end)
    sleep(1)
    local now = reactor.getReactorInfo()
    if now and (now.fieldStrength > before.fieldStrength or now.energySaturation > before.energySaturation or now.temperature > before.temperature) then
      inName = cand
      local f = fs.open(IN_FILE, "w")
      f.write(cand)
      f.close()
      return log("input gate is " .. cand)
    end
  end
  setFlows(function() return 0 end)
  log("no gate charges the reactor: is there power behind the injector's gate?")
end

local want     -- "run" / "stop"; nil until the first reading
local view = {} -- what the screens show

local function step()
  if not reactor then attach() end
  local i = reactor.getReactorInfo() or error("reactor core not found (structure incomplete?)", 0)
  local st = i.status
  local sat = ratio(i.energySaturation, i.maxEnergySaturation)
  local field = ratio(i.fieldStrength, i.maxFieldStrength)
  local fuel = ratio(i.fuelConversion, i.maxFuelConversion)
  want = want or ((st == "running" or st == "warming_up") and "run" or "stop")
  local inFlow, outFlow, alarm = 0, 0, nil

  if st == "running" and want == "run" then
    local why = field < MIN_FIELD and ("field at %.0f%%"):format(field * 100)
      or i.temperature > MAX_TEMP and ("temperature %.0f"):format(i.temperature)
      or fuel >= STOP_AT and ("fuel %.0f%% converted, refuel"):format(fuel * 100)
    if why then
      want = "stop"
      log("SHUTDOWN: " .. why)
    end
  end

  if st == "invalid" then
    alarm = "reactor structure is invalid"
  elseif st == "beyond_hope" then
    alarm = "MELTDOWN. Nothing stops it now. Leave."
  elseif st == "cold" or st == "cooling" then
    if want == "run" then
      if i.maxFuelConversion < 144 then
        want = "stop"
        log("needs fuel: 144 mB (one ingot) or more")
      elseif fuel >= STOP_AT then
        want = "stop"
        log(("fuel %.0f%% converted, refuel"):format(fuel * 100))
      else
        reactor.chargeReactor()
      end
    end
  elseif st == "warming_up" then
    if want == "stop" then
      reactor.stopReactor()
    elseif not inName then
      view = { info = i, sat = sat, field = field, fuel = fuel, inFlow = 0, alarm = "finding the input gate..." }
      return detect(i)
    else
      inFlow = CHARGE
      -- shield and saturation are at 50% by the time it reaches 2000; refused until then, so just ask again
      if i.temperature >= 2000 then reactor.activateReactor() end
    end
  elseif not inName then
    -- running without knowing which gate is which: touching them blind could cut the field's supply
    view = { info = i, sat = sat, field = field, fuel = fuel, inFlow = 0,
      alarm = "which gate feeds the injector? cookienet config InGate=<name> (" .. table.concat(gates, ", ") .. ")" }
    return sleep(1)
  else -- running / stopping
    if st == "running" and want == "stop" then reactor.stopReactor() end
    if st == "stopping" and want == "run" and i.temperature >= 2000 then reactor.activateReactor() end
    -- the core adds input * (1 - field) to the field, so this covers the drain and closes the gap to the
    -- target over a second (a tenth of that when it is low)
    local gap = TARGET_FIELD * i.maxFieldStrength - i.fieldStrength
    inFlow = math.max(0, i.fieldDrainRate + gap / (field < MIN_FIELD and 2 or 20)) / math.max(0.01, 1 - field)
    if st == "running" then
      local conv = fuel * 1.3 - 0.3
      -- above target: aim lower by the same amount. Never aims above the target.
      local aim = math.max(2000, math.min(TARGET_TEMP, 2 * TARGET_TEMP - i.temperature))
      local goal = satFor(aim, conv)
      local base = math.floor(i.maxEnergySaturation / 1000 * OUTPUT_MULT * 1.5 * 10)
      outFlow = (1 - goal) * math.floor(base * (1 + conv * 2))
      -- and from what is measured, whatever the model says: never drain towards the goal faster than over a
      -- second, never below it. An empty core heats by hundreds of degrees a tick.
      outFlow = math.max(0, math.min(outFlow, i.generationRate + (sat - goal) * i.maxEnergySaturation / 20))
    end
  end

  view = { info = i, sat = sat, field = field, fuel = fuel, inFlow = inFlow, alarm = alarm }
  setFlows(function(n) return n == inName and inFlow or outFlow / (#gates - 1) end)
end

-- ---- screens: the computer and any monitor show the same thing ----
local STATUS = {
  cold = { "COLD", colours.lightGrey }, warming_up = { "CHARGING", colours.yellow }, running = { "RUNNING", colours.lime },
  stopping = { "STOPPING", colours.orange }, cooling = { "COOLING", colours.lightBlue },
  invalid = { "INVALID", colours.red }, beyond_hope = { "MELTDOWN", colours.red },
}

local function draw(t)
  local W, H = t.getSize()
  local win = window.create(t, 1, 1, W, H, false) -- drawn hidden, shown once: no flicker
  local function put(x, y, s, fg, bg)
    win.setCursorPos(x, y)
    win.setTextColour(fg or colours.white)
    win.setBackgroundColour(bg or colours.black)
    win.write(s)
  end
  local function gauge(y, label, text, frac, col)
    put(1, y, label)
    put(W - #text + 1, y, text, col)
    local n = math.floor(W * math.max(0, math.min(1, frac)) + 0.5)
    put(1, y + 1, (" "):rep(n), nil, col)
    put(1 + n, y + 1, (" "):rep(W - n), nil, colours.grey)
  end
  win.setBackgroundColour(colours.black)
  win.clear()

  local i = view.info
  local st = STATUS[i and i.status] or { "NO REACTOR", colours.red }
  local clock = os.date("%H:%M:%S")
  put(1, 1, (" "):rep(W), nil, colours.blue)
  put(2, 1, "DE REACTOR", colours.white, colours.blue)
  put(14, 1, st[1], st[2], colours.blue)
  put(W - #clock, 1, clock, colours.white, colours.blue)
  if i then
    local temp = i.temperature
    gauge(2, "Temperature", ("%.0f / %.0f C"):format(temp, TARGET_TEMP), temp / 10000,
      temp > 8500 and colours.red or temp > TARGET_TEMP + 100 and colours.orange or colours.lime)
    gauge(4, "Field", ("%.1f%%  hold %.0f%%"):format(view.field * 100, TARGET_FIELD * 100), view.field,
      view.field < MIN_FIELD and colours.red or view.field < TARGET_FIELD * 0.8 and colours.orange or colours.lightBlue)
    gauge(6, "Saturation", ("%.1f%%"):format(view.sat * 100), view.sat, colours.cyan)
    gauge(8, "Fuel used", ("%.1f%%  stop at %.0f%%"):format(view.fuel * 100, STOP_AT * 100), view.fuel,
      view.fuel >= STOP_AT and colours.red or colours.yellow)
    local net = i.generationRate - view.inFlow
    put(1, 10, ("Gen %s  In %s  Net "):format(fmt(i.generationRate), fmt(view.inFlow)), colours.lightGrey)
    win.setTextColour(net >= 0 and colours.lime or colours.red)
    win.write((net >= 0 and "+" or "") .. fmt(net) .. " RF/t")
    if i.status == "running" and i.fuelConversionRate > 0 then
      -- fuelConversionRate is millionths of a mB per tick
      local left = dur((STOP_AT * i.maxFuelConversion - i.fuelConversion) / i.fuelConversionRate * 1e6 / 20)
      put(1, 11, "Fuel lasts " .. left, colours.lightGrey)
    end
  end
  local y = 12
  if view.alarm then
    put(1, y, view.alarm:sub(1, W), colours.white, colours.red)
    put(1, y + 1, view.alarm:sub(W + 1, 2 * W), colours.white, colours.red)
    y = y + 2
  end
  for n = 1, H - y do
    local l = logs[n]
    if l then put(1, y + n - 1, (l.t .. " " .. l.s):sub(1, W), l.s:find("^SHUTDOWN") and colours.orange or colours.lightGrey) end
  end
  local half = math.floor(W / 2)
  local function button(x, w, label, on, col)
    local pad = math.max(0, math.floor((w - #label) / 2))
    put(x, H, ((" "):rep(pad) .. label .. (" "):rep(w)):sub(1, w), on and colours.black or colours.white, on and col or colours.grey)
  end
  button(1, half, "START (S)", want == "run", colours.lime)
  button(half + 1, W - half, "STOP (X)", want == "stop", colours.red)
  win.setVisible(true)
end

local function render()
  pcall(draw, term.current())
  for _, m in ipairs(mons) do pcall(draw, m) end -- a monitor broken mid-frame is not the reactor's problem
end

local function control()
  local n = 0
  while true do
    local ok, err = pcall(step) -- one cycle is 2 ticks: read, then write the gates
    if not ok then
      if err == "Terminated" then error(err, 0) end
      -- a part was broken or the modem network changed: the gates keep their last flows (a steady reactor
      -- stays steady on fixed flows), look for everything again and carry on
      view = { alarm = tostring(err) }
      log(tostring(err))
      reactor = nil
      sleep(1)
    end
    n = n + 1
    if n % 3 == 0 or not ok then render() end
  end
end

local function input()
  while true do
    local e, a, x, y = os.pullEvent()
    local cmd
    if e == "key" then
      cmd = a == keys.s and "run" or a == keys.x and "stop"
    elseif e == "mouse_click" or e == "monitor_touch" then
      local W, H = (e == "mouse_click" and term.current() or peripheral.wrap(a)).getSize()
      cmd = y == H and (x <= math.floor(W / 2) and "run" or "stop")
    end
    if cmd and cmd ~= want then
      want = cmd
      log(cmd == "run" and "start requested" or "stop requested")
    end
  end
end

parallel.waitForAny(control, input)
