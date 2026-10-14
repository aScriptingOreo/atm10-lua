-- Weather machine: one computer, several Draconic Evolution celestial manipulators, each with a Redstone Relay
-- touching it, all relays on this computer's wired network.
-- A manipulator does the one thing its GUI redstone mode is set to, on a rising redstone edge; nothing about
-- it can be set from a computer. So: one manipulator per action, and this pulses the relay of the one wanted.
-- Which relay is which: relays are taken in the order they joined the network (redstone_relay_3 before _4),
-- and programs/Weather.json in this repo names them in that order. It is re-fetched while running: push an
-- edit, no reboot. Set each manipulator's redstone mode in its GUI to match its name.
-- Number keys or a click fire an action, K keeps the sky clear. With a wireless or ender modem it also takes
-- orders over rednet (Butler's SKY tab).
-- @desc Weather machine: fires DE celestial manipulators through redstone relays, local keys + Butler's SKY tab
-- @files programs/Weather.json
local PROTO = "weather"
local FILE = "/programs/Weather.json" -- shipped with the package, overwritten by every good fetch
-- ponytail: raw /main/ is CDN-cached for minutes, so a push takes up to ~5 min to land (same as Butler.json)
local URL = "https://raw.githubusercontent.com/aScriptingOreo/atm10-lua/main/programs/Weather.json"
local SYNC = 60       -- seconds between re-fetches
local KEEP_FILE = "/.weather_keep" -- exists = keep the sky clear
local PULSE = 1       -- seconds the signal is held
local KEEP_EVERY = 30 -- seconds between "stop rain" pulses while keeping clear: free when it is not raining
local STATE_EVERY = 5 -- seconds between status broadcasts

local function order(name) return tonumber(name:match("(%d+)$")) or 0 end
local relays = {}
for _, name in ipairs(peripheral.getNames()) do
  if peripheral.hasType(name, "redstone_relay") then relays[#relays + 1] = name end
end
table.sort(relays, function(a, b) return order(a) < order(b) end)
if #relays == 0 then error("no redstone relays: put one against each manipulator, a wired modem on each, right-click the modems", 0) end

local actions, clear = {}, nil -- { name, relay }; index of the one called "clear" (the keep-clear action)
local listed = 0 -- how many names the file has: fewer relays than that and every name sits one machine off
-- name the relays from { "actions": [ ... ] }; false when the text is not that, true when a name changed
local function name(json)
  local t = textutils.unserialiseJSON(json or "")
  local names = type(t) == "table" and type(t.actions) == "table" and t.actions
  if not names then return false end
  local changed = #names ~= listed
  listed = #names
  clear = nil
  for i, relay in ipairs(relays) do
    local n = tostring(names[i] or ("relay " .. i))
    changed = changed or not actions[i] or actions[i].name ~= n
    actions[i] = { name = n, relay = relay }
    if n == "clear" then clear = i end
  end
  return changed
end
do
  local f = fs.open(FILE, "r")
  local ok = name(f and f.readAll())
  if f then f.close() end
  if not ok then name('{"actions":[]}') end -- no file or bad json: "relay 1", "relay 2", ...
end

local modem = false
peripheral.find("modem", function(name) rednet.open(name) modem = true end)

-- the relay does not know which of its faces touches the manipulator: all of them. So a relay must touch
-- only its own manipulator.
local function set(relay, on)
  for _, side in ipairs(redstone.getSides()) do pcall(peripheral.call, relay, "setOutput", side, on) end
end
for _, a in ipairs(actions) do set(a.relay, false) end -- a reboot in mid-pulse leaves a line high: no edge next time

local keep = fs.exists(KEEP_FILE)
local last = "nothing yet"

local function draw()
  local W, H = term.getSize()
  term.setBackgroundColour(colours.black)
  term.clear()
  term.setCursorPos(1, 1)
  term.setBackgroundColour(colours.blue)
  term.setTextColour(colours.white)
  term.write((" WEATHER MACHINE" .. (" "):rep(W)):sub(1, W))
  term.setBackgroundColour(colours.black)
  if #relays < listed then
    -- the usual way to end up with rain on the "clear" key: one relay's modem is not connected
    term.setCursorPos(1, 2)
    term.setTextColour(colours.red)
    term.write(("%d names, only %d relays on the network!"):format(listed, #relays):sub(1, W))
  end
  for i, a in ipairs(actions) do
    if i + 2 >= H - 1 then break end
    term.setCursorPos(1, i + 2)
    term.setTextColour(colours.yellow)
    term.write(("%2d "):format(i))
    term.setTextColour(colours.white)
    term.write((a.name .. (" "):rep(16)):sub(1, 16))
    term.setTextColour(colours.grey)
    term.write(a.relay)
  end
  term.setCursorPos(1, H - 1)
  term.setTextColour(colours.lightGrey)
  term.write(("last: " .. last):sub(1, W))
  term.setCursorPos(1, H)
  term.write("number or click fires   ")
  term.setTextColour(not clear and colours.grey or keep and colours.lime or colours.lightGrey)
  term.write(clear and ("K keep clear: " .. (keep and "ON" or "off")) or "no action named clear")
end

local function tell()
  if not modem then return end
  local names = {}
  for i, a in ipairs(actions) do names[i] = a.name end
  rednet.broadcast({ actions = names, last = last, keep = keep, canKeep = clear ~= nil }, PROTO)
end

-- No sleep() anywhere in this program: it throws away every timer event but its own, and the heartbeat
-- below would die with them. A pulse is "line up now, down again when the heartbeat sees it is time".
local off = {} -- relay -> os.clock() at which its line goes low again
local function fire(i, quiet)
  local a = actions[i]
  if not a then return end
  set(a.relay, true)
  off[a.relay] = os.clock() + PULSE
  if not quiet then last = a.name .. " at " .. os.date("%H:%M:%S") end
end

local function setKeep(on)
  if not clear then return end
  keep = on
  if on then fs.open(KEEP_FILE, "w").close() else fs.delete(KEEP_FILE) end
end

draw()
tell()
local nextKeep, nextState, nextSync = os.clock() + 1, os.clock() + STATE_EVERY, os.clock() + 2
local beat = os.startTimer(0.5)
while true do
  local e, a, b, c = os.pullEvent()
  if e == "char" and tonumber(a) then
    fire(tonumber(a))
  elseif e == "char" and a:lower() == "k" then
    setKeep(not keep)
  elseif e == "mouse_click" then -- b = x, c = y; rows start on line 3
    fire(c - 2)
  elseif e == "rednet_message" and c == PROTO and type(b) == "table" then -- a = sender, b = message
    if b.fire then fire(tonumber(b.fire))
    elseif b.set ~= nil then setKeep(b.set == true) end
  elseif e == "timer" and a == beat then
    beat = os.startTimer(0.5)
    local now = os.clock()
    for relay, t in pairs(off) do
      if now >= t then
        set(relay, false)
        off[relay] = nil
      end
    end
    if keep and now >= nextKeep then
      fire(clear, true)
      nextKeep = now + KEEP_EVERY
    end
    -- http.get would wait here and swallow the heartbeat: ask, and take the answer as an event
    if now >= nextSync then
      nextSync = now + SYNC
      http.request(URL .. "?t=" .. os.epoch("utc"))
    end
    if now >= nextState then nextState = now + STATE_EVERY else e = nil end
  elseif e == "http_success" then -- a = url, b = response
    local body = b.readAll()
    b.close()
    if name(body) then
      local f = fs.open(FILE, "w")
      f.write(body)
      f.close()
      last = "names updated at " .. os.date("%H:%M:%S")
    else
      e = nil
    end
  else
    e = nil -- nothing of ours: no redraw, no broadcast
  end
  if e then
    draw()
    tell()
  end
end
