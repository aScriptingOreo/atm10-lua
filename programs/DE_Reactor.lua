-- Draconic Evolution reactor controller. One computer on a wired modem network with the reactor parts
-- (stabilizers, injector: any or all of them) and the flux gates: one feeding the injector, the rest draining
-- the stabilizers.
-- S / X on the computer (or the buttons, also on a monitor) start and stop it. On boot it carries on with
-- whatever the reactor is doing, so a server restart resumes by itself.
-- With a wireless or ender modem it also broadcasts its status and takes start/stop over rednet (Butler's
-- REACTOR tab). That link is only a remote: all control stays on this computer.
--
-- The numbers below are the reactor's own (TileReactorCore, Draconic Evolution 3.1.4.633), not tuning:
--   temperature settles where rise(saturation) = resist(temperature), so one saturation gives one temperature;
--   output drawn = generation at that saturation, which the core then converges to by itself (no overshoot);
--   field input = drain / (1 - field), the exact amount that holds the field where it is.
-- The field hitting 0 above 2000 C is the only thing that blows it up. Two builds do that faster than any
-- script can react, so they have to be right before the first start:
--   the injector losing power: a second or two. Feed the input gate from something that cannot run dry;
--   a stabilizer with anything but a flux gate (or nothing) behind it: while RUNNING every stabilizer pushes the
--   whole core into the block behind it, each tick. An unthrottled taker empties the core at once.
-- Whenever this script cannot see or steer everything, it shuts the reactor down: stopping ends all output,
-- the core fills, and the drain on the field falls to a hundredth.
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
local TARGET_FIELD = math.max(0.3, math.min(0.9, (tonumber(cfg.TargetField) or 50) / 100))
local STOP_AT = math.min(0.95, (tonumber(cfg.StopAt) or 90) / 100) -- past 97% it heats up even at full saturation
local CHARGE = tonumber(cfg.ChargeRate) or 5e6
local SCALE = tonumber(cfg.TextScale) or 1
local MAX_TEMP = 9000              -- shutdown above this (drain is already 3.5x there)
local MIN_FIELD = TARGET_FIELD / 2 -- shutdown below this
local OUTPUT_MULT = 1.0            -- reactorOutputMultiplier in the server's config/brandon3055/DraconicEvolution.cfg
local IN_FILE = "/.de_reactor_in"  -- the input gate found on the first charge; delete to find it again
-- ponytail: one fixed protocol; add a name to it (like reactor:<name>) if two reactors share modem range
local PROTO = "de_reactor"
local remote = false
peripheral.find("modem", function(name) rednet.open(name) remote = true end)

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
  -- three digits whatever the size, so the power line fits a small monitor
  local a = math.abs(n)
  return ((i == 1 or a >= 100) and "%.0f" or a >= 10 and "%.1f" or "%.2f"):format(n) .. u[i]
end
assert(fmt(999) == "999" and fmt(2.5e6) == "2.50M" and fmt(808370) == "808K" and fmt(23.9e6) == "23.9M")

local function dur(sec)
  return ("%.0fh%02.0fm"):format(math.floor(sec / 3600), math.floor(sec % 3600 / 60))
end

local logs = {}
local function log(s)
  if logs[1] and logs[1].s == s then return end -- a condition that persists is one line, not one per cycle
  table.insert(logs, 1, { s = s, t = os.date("%H:%M:%S") })
  logs[41] = nil
end

local pinned = cfg.InGate ~= "auto" and cfg.InGate ~= "" and cfg.InGate or nil -- set by hand: never second-guessed
local inName = pinned
if not inName and fs.exists(IN_FILE) then
  local f = fs.open(IN_FILE, "r")
  inName = f.readAll()
  f.close()
end

local parts, gates, enabled, mons = {}, {}, {}, {}
-- Every stabilizer and the injector is a door to the same core: ask whichever answers. One broken part or
-- pulled modem is then not the end of control.
local reactor = setmetatable({}, { __index = function(_, method)
  return function()
    for _, part in ipairs(parts) do
      local ok, v = pcall(part[method])
      if ok and v then return v end
    end
  end
end })

local function forgetInput(why)
  log(why)
  inName = nil
  fs.delete(IN_FILE)
end

local gateSet, gatesChanged -- the gates as last seen; true when a later look found a different set
local function attach()
  parts = { peripheral.find("draconic_reactor") }
  if #parts == 0 then error("no reactor: put a wired modem on a stabilizer or the injector and right-click it", 0) end
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
  if inName and not known then
    if pinned then error("input gate " .. inName .. " is not on the network (gates: " .. table.concat(gates, ", ") .. ")", 0) end
    forgetInput("input gate " .. inName .. " is gone from the network")
  end
  local set = table.concat(gates, ",")
  gatesChanged = gatesChanged or (gateSet ~= nil and gateSet ~= set)
  gateSet = set
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
local lastSt, lastSat = nil, 0
local holdUntil, holdSat = 0, 0 -- first second of running: outputs shut, see below
local low = 0                   -- cycles in a row the core sat under its goal without recovering
local chargeP, chargeAt         -- warm-up progress and when it last moved
local lastAt                    -- os.clock() of the previous cycle

local function trip(why)
  if want == "stop" then return end
  want = "stop"
  log("SHUTDOWN: " .. why)
  reactor.stopReactor()
end

local function step()
  if #parts == 0 then attach() end
  local i = reactor.getReactorInfo() or error("reactor core not found (structure incomplete?)", 0)
  local st = i.status
  local was = lastSt
  lastSt = st
  -- Corrections are spread over a second, or over 4 cycles when the computer is being starved and a cycle
  -- takes longer than its usual 2 ticks: a flow that stands for 2 s must not be sized for a tenth of that.
  local now = os.clock()
  local spread = math.max(20, (now - (lastAt or now)) * 20 * 4)
  lastAt = now
  if st ~= "warming_up" then chargeP = nil end
  local sat = ratio(i.energySaturation, i.maxEnergySaturation)
  local field = ratio(i.fieldStrength, i.maxFieldStrength)
  local fuel = ratio(i.fuelConversion, i.maxFuelConversion)
  want = want or ((st == "running" or st == "warming_up") and "run" or "stop")
  local inFlow, outFlow, alarm = 0, 0, nil

  -- a gate that dropped off the network is still in the world, passing its last flow where nothing steers it
  if gatesChanged then
    gatesChanged = false
    if st == "running" then trip("the flux gates on the network changed (" .. gateSet .. ")") end
  end
  if st == "running" and want == "run" then
    local why = field < MIN_FIELD and ("field at %.0f%%"):format(field * 100)
      or i.temperature > MAX_TEMP and ("temperature %.0f"):format(i.temperature)
      or fuel >= STOP_AT and ("fuel %.0f%% converted, refuel"):format(fuel * 100)
    if why then trip(why) end
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
      -- a remembered gate that moves nothing for 10 s is the wrong gate (rewired?) or has no power behind it
      local p = i.fieldStrength + i.energySaturation + i.temperature
      if p > (chargeP or -1) then chargeP, chargeAt = p, os.clock() end
      if os.clock() - chargeAt > 10 then
        if pinned then
          alarm = "nothing arrives through " .. inName .. ": no power behind it, or it is not the injector's gate"
        else
          forgetInput(inName .. " charges nothing, looking for the input gate again")
          chargeP = nil
        end
      end
      -- shield and saturation are at 50% by the time it reaches 2000; refused until then, so just ask again
      if i.temperature >= 2000 then reactor.activateReactor() end
    end
  elseif not inName then
    -- live, and no idea which gate is which: touching them blind could cut the field's supply, so the gates
    -- are left alone and the reactor is stopped. The gate is found on the next start.
    if st == "running" then trip("cannot tell which gate feeds the injector") end
    view = { info = i, sat = sat, field = field, fuel = fuel, inFlow = 0,
      alarm = "input gate unknown, gates left alone. It is found on the next start (S)." }
    return sleep(1)
  else -- running / stopping
    if st == "running" and want == "stop" then reactor.stopReactor() end
    if st == "stopping" and want == "run" and i.temperature >= 2000 then reactor.activateReactor() end
    -- the core adds input * (1 - field) to the field, so this covers the drain and closes the gap to the
    -- target over `spread` ticks (a tenth of that when it is low: too much field is harmless)
    local gap = TARGET_FIELD * i.maxFieldStrength - i.fieldStrength
    inFlow = math.max(0, i.fieldDrainRate + gap / (field < MIN_FIELD and spread / 10 or spread)) / math.max(0.01, 1 - field)
    if st == "running" then
      local conv = fuel * 1.3 - 0.3
      -- above target: aim lower by the same amount. Never aims above the target.
      local aim = math.max(2000, math.min(TARGET_TEMP, 2 * TARGET_TEMP - i.temperature))
      local goal = satFor(aim, conv)
      local base = math.floor(i.maxEnergySaturation / 1000 * OUTPUT_MULT * 1.5 * 10)
      outFlow = (1 - goal) * math.floor(base * (1 + conv * 2))
      -- and from what is measured, whatever the model says: never drain towards the goal faster than over
      -- `spread` ticks, never below it. An empty core heats by hundreds of degrees a tick.
      outFlow = math.max(0, math.min(outFlow, i.generationRate + (sat - goal) * i.maxEnergySaturation / spread))
      -- Is the output really behind the gates? With them shut for the first second the core can only fill
      -- (warm-up leaves it at exactly 50%), and later it can only sit under its goal while it is recovering.
      -- Anything else is a stabilizer feeding something that is not a gate.
      if was ~= "running" then holdUntil, holdSat, low = os.clock() + 1, was == "warming_up" and 0.5 or sat, 0 end
      local leak
      if os.clock() < holdUntil then
        outFlow = 0
        leak = sat < holdSat - 0.005
      else
        low = (sat < goal - 0.03 and sat <= lastSat) and low + 1 or 0
        leak = low >= 2
      end
      if leak then trip("core draining past the gates: a stabilizer has something that is not a flux gate behind it") end
    end
  end
  lastSat = sat

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
    local sep = W >= 34 and "  " or " "
    put(1, 10, ("Gen %s%sIn %s%sNet "):format(fmt(i.generationRate), sep, fmt(view.inFlow), sep), colours.lightGrey)
    win.setTextColour(net >= 0 and colours.lime or colours.red)
    win.write((net >= 0 and "+" or "") .. fmt(net) .. (W >= 34 and " RF/t" or ""))
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
  if remote then
    local i, l = view.info or {}, {}
    for n = 1, 8 do l[n] = logs[n] and logs[n].t .. " " .. logs[n].s end
    rednet.broadcast({
      status = i.status, temp = i.temperature, target = TARGET_TEMP, field = view.field, hold = TARGET_FIELD,
      sat = view.sat, fuel = view.fuel, stopAt = STOP_AT, gen = i.generationRate, inFlow = view.inFlow,
      alarm = view.alarm, want = want, log = l,
    }, PROTO)
  end
end

local function control()
  local n, failing = 0, nil
  while true do
    local ok, err = pcall(step) -- one cycle is 2 ticks: read, then write the gates
    if ok then
      failing = nil
    else
      if err == "Terminated" then error(err, 0) end
      -- a part was broken or the modem network changed: the gates keep their last flows (a steady reactor
      -- stays steady on fixed flows for a long while), so look for everything again and carry on.
      -- Still blind after 10 s: stop the reactor through whatever part still answers.
      failing = failing or os.clock()
      view = { alarm = tostring(err) }
      log(tostring(err))
      if os.clock() - failing > 10 and want ~= "stop" then
        want = "stop"
        log("SHUTDOWN: no control for 10 s")
        for _, part in ipairs({ peripheral.find("draconic_reactor") }) do
          local called, done = pcall(part.stopReactor)
          if called and done then break end
        end
      end
      parts = {}
      sleep(1)
    end
    n = n + 1
    if n % 3 == 0 or not ok then pcall(render) end
  end
end

local function input()
  while true do
    local e, a, x, y = os.pullEvent()
    local cmd
    if e == "key" then
      cmd = a == keys.s and "run" or a == keys.x and "stop"
    elseif e == "mouse_click" or e == "monitor_touch" then
      local t = e == "mouse_click" and term.current() or peripheral.wrap(a)
      if t then
        local W, H = t.getSize()
        cmd = y == H and (x <= math.floor(W / 2) and "run" or "stop")
      end
    elseif e == "rednet_message" and y == PROTO and type(x) == "table" then -- sender, message, protocol
      cmd = (x.cmd == "run" or x.cmd == "stop") and x.cmd
    end
    if cmd and cmd ~= want then
      want = cmd
      log(cmd == "run" and "start requested" or "stop requested")
    end
  end
end

-- nothing may end this program while the reactor is live: anything unexpected is logged and the loops start again
while true do
  local _, err = pcall(parallel.waitForAny, control, input)
  if err == "Terminated" then error(err, 0) end
  log("restarted after: " .. tostring(err))
  sleep(1)
end
