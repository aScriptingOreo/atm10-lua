-- Daylight keeper: an Advanced Peripherals Environment Detector (touching this computer or on its wired
-- network) says whether it is day and the sky is clear. While it is on and the answer is no, every Redstone
-- Relay on the network is pulsed (one against each celestial manipulator, e.g. set to "clear" and "sunrise"),
-- again every Cooldown seconds until it is clear day.
-- On/off: T key, D in Butler's / Pocket's SKY tab, or rednet { set = true/false } on protocol "daylight".
-- @desc Keeps it clear day: Environment Detector says night/rain/storm -> pulses every redstone relay, toggle in SKY tab
-- @deps cn_lib
-- @config Cooldown|Seconds between pulses while still not clear day (the manipulator takes a while)|30
local cfg = dofile("/lib/cn.lua")
local PROTO = "daylight"
local COOLDOWN = tonumber(cfg.Cooldown) or 30
local PULSE = 1 -- seconds the signal is held: the manipulator acts on the rising edge
local OFF_FILE = "/.daylight_off" -- exists = turned off

local det = peripheral.find("environment_detector")
  or error("no Environment Detector: put one against this computer or on its wired network", 0)
local relays = {}
for _, name in ipairs(peripheral.getNames()) do
  if peripheral.hasType(name, "redstone_relay") then relays[#relays + 1] = name end
end
if #relays == 0 then error("no redstone relays: put one against each manipulator, wired modems, right-click them", 0) end

local modem = false
peripheral.find("modem", function(name) rednet.open(name) modem = true end)

-- a relay does not know which face touches the manipulator: drive them all
local function set(on)
  for _, relay in ipairs(relays) do
    for _, side in ipairs(redstone.getSides()) do pcall(peripheral.call, relay, "setOutput", side, on) end
  end
end
set(false) -- a reboot mid-pulse leaves lines high: no edge next time

-- what is wrong with the sky, nil when it is clear day
local function sky()
  if det.isThunder() then return "storm" end
  if det.isRaining() then return "rain" end
  -- ponytail: day = ticks 0-12000 (sunrise to sunset), % in case getTime is the total world time
  if det.getTime() % 24000 >= 12000 then return "night" end
end

local enabled = not fs.exists(OFF_FILE)
local now_sky, last = nil, "nothing yet"
local nextFire, offAt = 0, nil

local function draw()
  term.clear()
  term.setCursorPos(1, 1)
  print("DAYLIGHT KEEPER")
  print("sky: " .. (now_sky or "clear day"))
  print(("relays: %d"):format(#relays))
  print("last pulse: " .. last)
  print()
  print("T toggle: " .. (enabled and "ON" or "off"))
end

local function tell()
  if modem then rednet.broadcast({ on = enabled, sky = now_sky or "clear day", last = last }, PROTO) end
end

local function setEnabled(on)
  enabled = on
  if on then fs.delete(OFF_FILE) else fs.open(OFF_FILE, "w").close() end
  nextFire = 0
end

-- No sleep(): it eats other events. One 1 s heartbeat ends the pulse, checks the sky, broadcasts status.
local beat = os.startTimer(0)
while true do
  local e, a, b, c = os.pullEvent()
  if e == "char" and a:lower() == "t" then
    setEnabled(not enabled)
  elseif e == "rednet_message" and c == PROTO and type(b) == "table" and b.set ~= nil then
    setEnabled(b.set == true)
  elseif e == "timer" and a == beat then
    beat = os.startTimer(1)
    local now = os.clock()
    if offAt and now >= offAt then
      set(false)
      offAt = nil
    end
    now_sky = sky()
    if enabled and now_sky and not offAt and now >= nextFire then
      set(true)
      offAt, nextFire = now + PULSE, now + COOLDOWN
      last = now_sky .. " at " .. os.date("%H:%M:%S")
    end
  else
    e = nil -- not ours: no redraw, no broadcast
  end
  if e then
    draw()
    tell()
  end
end
