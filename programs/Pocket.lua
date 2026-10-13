-- Butler away from home, on a pocket computer with an ender modem (a wireless one only reaches a few
-- hundred blocks). It shows what Butler, DE_Reactor, DE_Core and Weather broadcast, and sends the same
-- orders their own screens do. Nothing here controls anything directly: out of range just means old numbers.
-- Tab, the arrow keys or a tap on the top row switch screen.
-- @desc Butler on a pocket computer: ME status, reactor, energy core and weather from anywhere (ender modem)
-- @deps de_view
local V = dofile("/lib/de_view.lua")
if not V.open() then error("no modem: craft this pocket computer together with an ender modem", 0) end

local TABS = { "ME", "REACTOR", "CORE", "SKY" }
local view, note = "ME", nil

local function tput(x, y, s, fg, bg)
  term.setCursorPos(x, y)
  term.setTextColour(fg or colours.white)
  term.setBackgroundColour(bg or colours.black)
  term.write(s)
end

-- Butler's own summary: header numbers, the rules that are not OK, then the end of its log
local function drawButler(W, H)
  local b = V.butler
  if not b then return tput(1, 3, "waiting for Butler...", colours.lightGrey) end
  tput(1, 2, b.online and "ME online" or "ME OFFLINE", b.online and colours.lime or colours.red)
  local run = b.paused and "PAUSED" or "ACTIVE"
  tput(W - #run + 1, 2, run, colours.black, b.paused and colours.orange or colours.lime)
  tput(1, 3, ("crafting %d/%d  stock %d/%d ok"):format(b.busy or 0, b.cpus or 0, b.ok or 0, b.total or 0):sub(1, W), colours.lightGrey)
  local y = 4
  if os.clock() - V.butlerAt > 10 then
    tput(1, y, ("NO SIGNAL (old numbers)" .. (" "):rep(W)):sub(1, W), colours.white, colours.red)
    y = y + 1
  end
  local rows = type(b.rows) == "table" and b.rows or {}
  local room = math.max(2, H - y - 5) -- keep a few rows for the log
  for i = 1, math.min(#rows, room) do
    local r = rows[i]
    local st = tostring(r.st):sub(1, 9)
    tput(1, y, tostring(r.name):sub(1, W - #st - 1))
    tput(W - #st + 1, y, st, tonumber(r.col) or colours.red)
    y = y + 1
  end
  if #rows > room then tput(1, y, ("+ %d more"):format(#rows - room), colours.grey) y = y + 1 end
  if #rows == 0 then tput(1, y, "all stocked", colours.lime) y = y + 1 end
  local log = type(b.log) == "table" and b.log or {}
  for i = math.max(1, #log - (H - 1 - y)), #log do
    y = y + 1
    if y < H then tput(1, y, tostring(log[i]):sub(1, W), colours.grey) end
  end
end

local HELP = { ME = "P pause/resume", REACTOR = "S start  X stop", CORE = "" }

local function draw()
  local W, H = term.getSize()
  term.setBackgroundColour(colours.black)
  term.clear()
  term.setCursorBlink(false)
  tput(1, 1, (" "):rep(W), nil, colours.grey)
  local x = 1
  for _, v in ipairs(TABS) do
    local fg, bg = colours.white, colours.grey
    if v == view then fg, bg = colours.black, colours.lightBlue end
    if v == "REACTOR" and V.alarm() then fg, bg = colours.white, colours.red end -- seen from any screen
    tput(x, 1, " " .. v .. " ", fg, bg)
    x = x + #v + 2
  end
  if view == "ME" then drawButler(W, H)
  else ({ REACTOR = V.reactor, CORE = V.core, SKY = V.sky })[view](term.current(), 1, 2, W, H - 2) end
  local help = view == "SKY" and V.skyHelp(W) or HELP[view]
  tput(1, H, (note or help):sub(1, W), note and colours.lime or colours.lightGrey)
end
local function redraw() pcall(draw) end

local function step(d)
  for i, v in ipairs(TABS) do
    if v == view then view = TABS[(i - 1 + d) % #TABS + 1] return end
  end
end

local function input()
  while true do
    local e, a, b, c = os.pullEvent()
    if e == "key" then
      note = nil
      if a == keys.tab or a == keys.right then step(1) elseif a == keys.left then step(-1) end
    elseif e == "char" then
      local ch = a:lower()
      if view == "ME" and ch == "p" then
        rednet.broadcast({ cmd = "pause" }, "butler_cmd")
        note = "sent: pause / resume"
      elseif view == "REACTOR" and (ch == "s" or ch == "x") then
        V.send(ch == "s" and "run" or "stop")
        note = "sent: " .. (ch == "s" and "start" or "stop")
      elseif view == "SKY" then
        note = V.skyKey(a) or note
      end
    elseif e == "mouse_click" then -- b = x, c = y
      note = nil
      if c == 1 then
        local at = 1
        for _, v in ipairs(TABS) do
          if b >= at and b < at + #v + 2 then view = v end
          at = at + #v + 2
        end
      elseif view == "SKY" then
        note = V.skyFire(c - 2) -- actions start on screen row 3
      end
    end
    if e == "key" or e == "char" or e == "mouse_click" or e == "term_resize" then redraw() end
  end
end

redraw()
parallel.waitForAny(function() V.listen(redraw) end, function() V.alarmLoop(nil, redraw) end, input)
