-- Remote screens shared by Butler, DE_Monitor and Pocket: Draconic reactor, energy core, weather machine.
-- Usage: local V = dofile("/lib/de_view.lua")
-- It listens to what DE_Reactor, DE_Core, Weather and Butler broadcast and draws it into any region of any
-- terminal or monitor, laid out for the size it is given. Display and orders only: every machine is run by
-- its own computer and does not care whether anything is listening.
-- @name de_view
-- @desc reactor / energy core / weather screens for Butler, DE_Monitor and Pocket (auto-installed as a dependency)
local V = { RPROTO = "de_reactor", CPROTO = "de_core", WPROTO = "weather", BPROTO = "butler", DPROTO = "daylight", muted = false }

local rx, rxAt     -- last reactor status, os.clock() when it came in
local core, coreAt -- last energy core readout
local sky, skyAt   -- last weather machine status: { actions = { names }, last, keep, canKeep }
local dl, dlAt     -- last Daylight keeper status: { on, sky, last }
-- V.butler / V.butlerAt: Butler's own summary, kept for whoever draws it (Pocket)
local hist, chist = {}, {} -- { temp, field } / { level }, one every HIST_EVERY seconds, newest last
local HIST_EVERY, KEEP = 6, 400
local sampled, csampled = -math.huge, -math.huge
local tripAt, lastTop = -math.huge, nil -- when the reactor last shut itself down

local function fmt(n)
  local u, i = { "", "K", "M", "G", "T", "P", "E" }, 1
  while math.abs(n) >= 1000 and i < #u do n, i = n / 1000, i + 1 end
  local a = math.abs(n)
  return ((i == 1 or a >= 100) and "%.0f" or a >= 10 and "%.1f" or "%.2f"):format(n) .. u[i]
end
assert(fmt(999) == "999" and fmt(5430000) == "5.43M" and fmt(2.14e12) == "2.14T")

local function span(sec)
  return ("%.0fh%02.0fm"):format(math.floor(sec / 3600), math.floor(sec % 3600 / 60))
end
local function pct(v) return ("%.1f%%"):format((v or 0) * 100) end

-- rednet on every modem this computer has; false when it has none
function V.open()
  local any = false
  peripheral.find("modem", function(name) rednet.open(name) any = true end)
  return any
end

function V.send(cmd) rednet.broadcast({ cmd = cmd }, V.RPROTO) end

-- hand it every rednet message; true when it was a reactor or core broadcast
function V.feed(proto, msg)
  if type(msg) ~= "table" then return false end
  local now = os.clock()
  if proto == V.RPROTO and msg.status then
    rx, rxAt = msg, now
    local top = type(msg.log) == "table" and msg.log[1] or ""
    -- a new SHUTDOWN line = it just tripped. Not on the first message: that line may be hours old.
    if lastTop and top ~= lastTop and tostring(top):find("SHUTDOWN") then tripAt = now end
    lastTop = top
    if now - sampled >= HIST_EVERY then
      sampled = now
      hist[#hist + 1] = { temp = msg.temp or 0, field = msg.field or 0 }
      if #hist > KEEP then table.remove(hist, 1) end
    end
    return true
  elseif proto == V.CPROTO then
    core, coreAt = msg, now
    if now - csampled >= HIST_EVERY then
      csampled = now
      chist[#chist + 1] = { level = msg.stored or 0 }
      if #chist > KEEP then table.remove(chist, 1) end
    end
    return true
  elseif proto == V.WPROTO and type(msg.actions) == "table" then
    sky, skyAt = msg, now
    return true
  elseif proto == V.DPROTO and msg.on ~= nil then
    dl, dlAt = msg, now
    return true
  elseif proto == V.BPROTO then
    V.butler, V.butlerAt = msg, now
    return true
  end
  return false
end

-- "crit": it is about to be lost. "warn": it shut itself down, or went quiet while it was live.
function V.alarm()
  if not rx then return end
  local hot = rx.status == "running" or rx.status == "stopping"
  if os.clock() - rxAt > 5 then return (hot or rx.status == "warming_up") and "warn" or nil end
  if rx.status == "beyond_hope" then return "crit" end
  if hot and ((rx.field or 1) < (rx.hold or 0) / 2 or (rx.temp or 0) > 8500) then return "crit" end
  if os.clock() - tripAt < 15 then return "warn" end
end

-- loop: feeds itself from rednet and calls changed() at most twice a second, and on a 5 s timeout so a
-- dead link gets drawn as one
function V.listen(changed)
  local last = -math.huge
  while true do
    local _, msg, proto = rednet.receive(nil, 5)
    if (msg == nil or V.feed(proto, msg)) and os.clock() - last >= 0.5 then
      last = os.clock()
      changed()
    end
  end
end

-- loop: calls changed() when the alarm state flips; with a speaker, two-tone twice a second when it is
-- critical and one beep every 2 s otherwise. V.muted silences it until the alarm has cleared.
function V.alarmLoop(speaker, changed)
  local n, last = 0, nil
  while true do
    local a = V.alarm()
    if not a then V.muted = false end
    if a ~= last then
      last = a
      changed()
    end
    n = n + 1
    if speaker and a and not V.muted then
      if a == "crit" then pcall(speaker.playNote, "bit", 3, n % 2 == 0 and 18 or 12)
      elseif n % 4 == 0 then pcall(speaker.playNote, "bit", 2, 12) end
    end
    sleep(0.5)
  end
end

-- ---- drawing: everything goes through a painter clipped to its region ----
local function painter(win, x0, y0, W, H)
  return function(x, y, s, fg, bg)
    if y < 1 or y > H or x < 1 or x > W then return end
    win.setCursorPos(x0 + x - 1, y0 + y - 1)
    win.setTextColour(fg or colours.white)
    win.setBackgroundColour(bg or colours.black)
    win.write(s:sub(1, W - x + 1))
  end
end

local function bar(put, x, y, w, frac, col)
  local n = math.floor(w * math.max(0, math.min(1, frac or 0)) + 0.5)
  put(x, y, (" "):rep(n), nil, col)
  if n < w then put(x + n, y, (" "):rep(w - n), nil, colours.grey) end
end

-- teletext blocks: drawn black on colour they light the bottom third / bottom two thirds of a cell
local PART = { "\143", "\131" }
local function graph(put, y, rows, W, list, key, max, colOf)
  for c = 1, W do
    local h = list[#list - W + c]
    local v = h and h[key]
    local lit = v and math.max(1, math.floor(math.min(1, v / max) * rows * 3 + 0.5)) or 0
    for r = 0, rows - 1 do
      local n = math.min(3, lit - r * 3)
      if n == 3 then put(c, y + rows - 1 - r, " ", nil, colOf(v))
      elseif n > 0 then put(c, y + rows - 1 - r, PART[n], colours.black, colOf(v)) end
    end
  end
end
local function minutes(W) return ("last %.0f min"):format(W * HIST_EVERY / 60) end

local RSTATUS = {
  cold = colours.lightGrey, warming_up = colours.yellow, running = colours.lime, stopping = colours.orange,
  cooling = colours.lightBlue,
}

-- reactor screen in the region (x0, y0, W, H) of win. A tall region gets a full-width bar under each
-- gauge, a wide one a bar beside it, a small one just the numbers.
function V.reactor(win, x0, y0, W, H)
  local put = painter(win, x0, y0, W, H)
  if not rx then return put(1, 2, "waiting for the reactor computer...", colours.lightGrey) end
  local tall, wide = H >= 24, W >= 45
  local y = 1
  local function gauge(label, text, col, frac)
    put(1, y, label, colours.lightGrey)
    if tall then
      put(math.max(13, W - #text + 1), y, text, col)
      bar(put, 1, y + 1, W, frac, col)
      y = y + 3
    else
      put(13, y, wide and text:sub(1, 20) or text, col)
      if wide then bar(put, 34, y, W - 33, frac, col) end
      y = y + 1
    end
  end
  local temp, field, hold = rx.temp or 0, rx.field or 0, rx.hold or 0
  local function tempCol(t) return t > 8500 and colours.red or t > (rx.target or 8000) + 100 and colours.orange or colours.lime end
  local function fieldCol(f) return f < hold / 2 and colours.red or f < hold * 0.8 and colours.orange or colours.lightBlue end
  local st = tostring(rx.status or "?")
  put(1, y, "Status", colours.lightGrey)
  put(13, y, st:upper():gsub("_", " ") .. (rx.want and wide and "   (asked to " .. rx.want .. ")" or ""), RSTATUS[st] or colours.red)
  y = y + (tall and 2 or 1)
  gauge("Temperature", ("%.0f / %.0f C"):format(temp, rx.target or 0), tempCol(temp), temp / 10000)
  local roomy = W >= 30 -- a pocket computer is 26 wide
  gauge("Field", pct(field) .. (roomy and "  hold %.0f%%" or " of %.0f%%"):format(hold * 100), fieldCol(field), field)
  gauge("Saturation", pct(rx.sat), colours.cyan, rx.sat or 0)
  gauge("Fuel used", pct(rx.fuel) .. (roomy and "  stop %.0f%%" or " of %.0f%%"):format((rx.stopAt or 0) * 100), colours.yellow, rx.fuel or 0)
  local gen, inFlow = rx.gen or 0, rx.inFlow or 0
  local net = gen - inFlow
  local power = (net >= 0 and "net +" or "net ") .. fmt(net) .. (W >= 30 and " RF/t" or "/t")
  if wide then power = ("gen %s  in %s  "):format(fmt(gen), fmt(inFlow)) .. power end
  put(1, y, "Power", colours.lightGrey)
  put(13, y, power, net >= 0 and colours.lime or colours.red)
  y = y + 1
  if os.clock() - rxAt > 5 then
    put(1, y, ("NO SIGNAL from the reactor computer (old numbers)" .. (" "):rep(W)):sub(1, W), colours.white, colours.red)
  elseif rx.alarm then
    put(1, y, tostring(rx.alarm), colours.white, colours.red)
  end
  y = y + 1
  -- what is left: two graphs when they fit, the reactor's log under them
  local logs = tall and 5 or H >= 17 and 2 or 1
  local rows = H - y + 1 - logs - 2 -- graph rows, less the two titles
  if rows >= 4 then
    local tr = math.ceil(rows / 2)
    put(1, y, roomy and "Temperature, " .. minutes(W) .. " (top = 10000 C)" or "Temp, " .. minutes(W), colours.lightGrey)
    graph(put, y + 1, tr, W, hist, "temp", 10000, tempCol)
    y = y + 1 + tr
    put(1, y, roomy and "Field (top = 100%)" or "Field", colours.lightGrey)
    graph(put, y + 1, rows - tr, W, hist, "field", 1, fieldCol)
    y = y + 1 + rows - tr
  end
  for n = 1, H - y + 1 do
    local l = type(rx.log) == "table" and rx.log[n]
    if l then put(1, y + n - 1, tostring(l), tostring(l):find("SHUTDOWN") and colours.orange or colours.lightGrey) end
  end
end

-- energy core screen: level, flow, time until full or empty at that rate, level history
function V.core(win, x0, y0, W, H)
  local put = painter(win, x0, y0, W, H)
  if not core then return put(1, 2, "waiting for the core computer (DE_Core)...", colours.lightGrey) end
  local tall = H >= 24
  local have, max = core.stored or 0, core.max
  local inp, out = core.input or 0, core.output or 0
  local net = inp - out
  local frac = max and max > 0 and have / max or nil
  local col = frac and frac < 0.1 and colours.red or net < 0 and colours.orange or colours.yellow
  local y = 1
  local function row(label, text, c)
    put(1, y, label, colours.lightGrey)
    put(13, y, text, c)
    y = y + 1
  end
  if W >= 40 then
    row("Stored", fmt(have) .. (max and " / " .. fmt(max) or "") .. " RF" .. (frac and "   " .. pct(frac) or "  (no limit)"), col)
  else
    row("Stored", (frac and pct(frac) .. "  " or "") .. fmt(have), col)
  end
  if frac then
    for r = 0, tall and 1 or 0 do bar(put, 1, y + r, W, frac, col) end
    y = y + (tall and 3 or 1)
  end
  row("In", fmt(inp) .. " RF/t", colours.lime)
  row("Out", fmt(out) .. " RF/t", colours.orange)
  row("Net", (net >= 0 and "+" or "") .. fmt(net) .. " RF/t", net >= 0 and colours.lime or colours.red)
  if net > 0 and max then row("Full in", span((max - have) / net / 20))
  elseif net < 0 then row("Empty in", span(have / -net / 20), col)
  else y = y + 1 end
  if os.clock() - coreAt > 10 then
    put(1, y, ("NO SIGNAL from the core computer (old numbers)" .. (" "):rep(W)):sub(1, W), colours.white, colours.red)
  end
  y = y + 1
  local rows = H - y
  if rows >= 2 then
    local top = max
    if not top then -- no limit: scale to the highest level on screen
      top = 1
      for c = math.max(1, #chist - W + 1), #chist do top = math.max(top, chist[c].level) end
    end
    put(1, y, "Level, " .. minutes(W) .. (W >= 40 and " (top = " .. fmt(top) .. ")" or ""), colours.lightGrey)
    graph(put, y + 1, rows, W, chist, "level", top, function() return col end)
  end
end

-- weather machine: its actions on rows 2.., what it did last, and whether it is still there
-- and the Daylight keeper on the row above "last", when there is one
function V.sky(win, x0, y0, W, H)
  local put = painter(win, x0, y0, W, H)
  if dl then
    local gone = os.clock() - dlAt > 15
    put(1, H - 2, ("daylight keeper %s, sky: %s"):format(gone and "NO SIGNAL" or dl.on and "ON" or "off", tostring(dl.sky)),
      gone and colours.red or dl.on and colours.lime or colours.lightGrey)
  end
  if not sky then return put(1, 2, "waiting for the weather machine...", colours.lightGrey) end
  for i, name in ipairs(sky.actions) do
    if i + 1 > H - (dl and 3 or 2) then break end
    put(1, i + 1, ("%2.0f "):format(i), colours.yellow)
    put(4, i + 1, tostring(name))
  end
  put(1, H - 1, "last: " .. tostring(sky.last), colours.lightGrey)
  if os.clock() - skyAt > 15 then put(1, H, "NO SIGNAL from the weather machine", colours.white, colours.red) end
end
-- the keys V.skyKey understands, for a help line W characters wide
function V.skyHelp(W)
  local d = dl and (W < 40 and "  D day" or "   D daylight keeper") or ""
  if not sky then return d end
  local keep = sky.keep and "ON" or "off"
  if W < 40 then return "1-9 fire" .. (sky.canKeep and "  K clear: " .. keep or "") .. d end
  return "number or click fires" .. (sky.canKeep and "   K keep clear: " .. keep or "") .. d
end
-- fire action i (a click on region row r is action r - 1); returns what to tell the user, nil if there is none
function V.skyFire(i)
  if not (sky and sky.actions[i]) then return end
  rednet.broadcast({ fire = i }, V.WPROTO)
  return "sent: " .. tostring(sky.actions[i])
end
-- a typed character: a number fires, K toggles keep-clear, D the Daylight keeper; returns what to tell the user
function V.skyKey(s)
  if tonumber(s) then return V.skyFire(tonumber(s)) end
  if s:lower() == "d" and dl then
    rednet.broadcast({ set = not dl.on }, V.DPROTO)
    return "sent: daylight keeper " .. (dl.on and "off" or "on")
  end
  if s:lower() == "k" and sky and sky.canKeep then
    rednet.broadcast({ set = not sky.keep }, V.WPROTO)
    return "sent: keep clear " .. (sky.keep and "off" or "on")
  end
end

-- A short, wide monitor (a 1-block strip): one status line, then the gauges side by side as thick bars.
function V.strip(win, x0, y0, W, H)
  local put = painter(win, x0, y0, W, H)
  if not rx then return put(1, 1, "waiting for the reactor computer...", colours.lightGrey) end
  local stale = os.clock() - rxAt > 5
  local hold, net = rx.hold or 0, (rx.gen or 0) - (rx.inFlow or 0)
  local bg = (stale or V.alarm()) and colours.red or colours.blue
  local head = " REACTOR " .. (stale and "NO SIGNAL" or tostring(rx.status or "?"):upper():gsub("_", " "))
  head = head .. ("    gen %s  in %s  net %s%s RF/t"):format(fmt(rx.gen or 0), fmt(rx.inFlow or 0), net >= 0 and "+" or "", fmt(net))
  if rx.alarm then head = head .. "    " .. tostring(rx.alarm) end
  local clock = os.date("%H:%M:%S")
  put(1, 1, (head .. (" "):rep(W)):sub(1, W), colours.white, bg)
  put(W - #clock, 1, clock, colours.white, bg)
  local temp, field = rx.temp or 0, rx.field or 0
  local g = {
    { "Temperature", ("%.0f / %.0f C"):format(temp, rx.target or 0), temp / 10000,
      temp > 8500 and colours.red or temp > (rx.target or 8000) + 100 and colours.orange or colours.lime },
    { "Field", pct(field), field, field < hold / 2 and colours.red or field < hold * 0.8 and colours.orange or colours.lightBlue },
    { "Saturation", pct(rx.sat), rx.sat or 0, colours.cyan },
    { "Fuel used", pct(rx.fuel), rx.fuel or 0, colours.yellow },
  }
  if core and core.max and core.max > 0 and os.clock() - coreAt <= 10 then
    local f = (core.stored or 0) / core.max
    g[#g + 1] = { "Storage", fmt(core.stored or 0) .. "  " .. pct(f), f, f < 0.1 and colours.red or colours.yellow }
  end
  local cw = math.floor((W + 1) / #g) -- one column of gap between gauges
  for i, v in ipairs(g) do
    local x, w = (i - 1) * cw + 1, cw - 1
    put(x, 3, v[1], colours.lightGrey)
    put(x + math.max(#v[1] + 1, w - #v[2]), 3, v[2], v[4])
    for y = 4, H do bar(put, x, y, w, v[3], v[4]) end
  end
end

-- one row of equal touch buttons. REACTOR goes red while its alarm is up, whichever one is showing.
function V.tabs(win, y, W, names, active)
  local put = painter(win, 1, 1, W, y)
  local cw = math.floor(W / #names)
  for i, name in ipairs(names) do
    local x = (i - 1) * cw + 1
    local w = i == #names and W - x + 1 or cw
    local label = name:sub(1, w)
    local fg, bg = colours.white, colours.grey
    if name == active then fg, bg = colours.black, colours.lightBlue end
    if name == "REACTOR" and V.alarm() then fg, bg = colours.white, colours.red end
    put(x, y, ((" "):rep(math.floor((w - #label) / 2)) .. label .. (" "):rep(w)):sub(1, w), fg, bg)
  end
end
-- which button a touch at column x landed on
function V.tabAt(x, W, n) return math.min(n, math.floor((x - 1) / math.floor(W / n)) + 1) end
assert(V.tabAt(1, 29, 3) == 1 and V.tabAt(10, 29, 3) == 2 and V.tabAt(29, 29, 3) == 3)

return V
