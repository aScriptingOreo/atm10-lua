-- Daylight keeper: a daylight sensor on one side of this computer, Redstone Relays on its wired network (one
-- against each celestial manipulator, e.g. set to "clear" and "noon"). While the sensor reads low (night, or
-- rain/storm dimming it) every relay is pulsed, again every Cooldown seconds until the sky is bright.
-- On/off: T key, or rednet { set = true/false } on protocol "daylight" (status broadcast there too).
-- @desc Daylight sensor watch: pulses every redstone relay while it is night or raining, toggle over rednet
-- @deps cn_lib
-- @config InSide|Side the daylight sensor touches|back
-- @config DayAt|Sensor signal counted as clear day (15 = clear noon, rain knocks ~3 off)|13
-- @config Cooldown|Seconds between pulses while still dark (the manipulator takes a while)|30
local cfg = dofile("/lib/cn.lua")
local PROTO = "daylight"
local IN_SIDE = cfg.InSide or "back"
-- ponytail: one threshold for "day and clear"; the sensor can't tell dawn from rain, tune DayAt in game
local DAY_AT = tonumber(cfg.DayAt) or 13
local COOLDOWN = tonumber(cfg.Cooldown) or 30
local PULSE = 1 -- seconds the signal is held: the manipulator acts on the rising edge
local OFF_FILE = "/.daylight_off" -- exists = turned off

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

local enabled = not fs.exists(OFF_FILE)
local last = "nothing yet"
local nextFire, offAt = 0, nil

local function signal() return redstone.getAnalogInput(IN_SIDE) end

local function draw()
  term.clear()
  term.setCursorPos(1, 1)
  print("DAYLIGHT KEEPER")
  print(("sensor (%s): %d, day at %d+"):format(IN_SIDE, signal(), DAY_AT))
  print(("relays: %d"):format(#relays))
  print("last pulse: " .. last)
  print()
  print("T toggle: " .. (enabled and "ON" or "off"))
end

local function tell()
  if modem then rednet.broadcast({ on = enabled, signal = signal(), dayAt = DAY_AT, last = last }, PROTO) end
end

local function setEnabled(on)
  enabled = on
  if on then fs.delete(OFF_FILE) else fs.open(OFF_FILE, "w").close() end
  nextFire = 0
end

-- No sleep(): it eats other events. One 1 s heartbeat does the pulse end, the check and the status broadcast.
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
    if enabled and not offAt and now >= nextFire and signal() < DAY_AT then
      set(true)
      offAt, nextFire = now + PULSE, now + COOLDOWN
      last = ("signal %d at %s"):format(signal(), os.date("%H:%M:%S"))
    end
  else
    e = nil -- not ours: no redraw, no broadcast
  end
  if e then
    draw()
    tell()
  end
end
