-- Butler: ME system manager. Computer next to an ME Bridge, advanced monitor on any side (optional).
-- STOCK autocrafts anything below its keep count, TRASH exports anything above its keep count out TrashDir.
-- Set up by touching the monitor: ADD picks from the network, STOCK/TRASH edit the rules, HOME is the dashboard.
-- @desc ME system manager: keeps items stocked (autocraft), trashes overflow, touch dashboard on a monitor
-- @deps cn_lib
-- @config TrashDir|Bridge side facing the trash|down
-- @config Poll|Seconds between stock checks|10
-- @config TextScale|Monitor text scale|0.5
local cfg = dofile("/lib/cn.lua")
local POLL = tonumber(cfg.Poll) or 10
local SCALE = tonumber(cfg.TextScale) or 0.5
local TRASH_DIR = cfg.TrashDir or "down"
-- AP 0.8 target: "@<direction>" = side of the bridge, anything else = peripheral name on the network
local DIRS = { up = 1, down = 1, north = 1, south = 1, east = 1, west = 1, front = 1, back = 1, left = 1, right = 1, top = 1, bottom = 1 }
local TARGET = DIRS[TRASH_DIR] and "@" .. TRASH_DIR or TRASH_DIR
local DB = "/butler.json" -- local state, not shipped with the package: cookienet update never overwrites it
local RETRY = 60          -- seconds before re-requesting a craft that failed or never reached a CPU
local PER_PASS = 64       -- max items trashed per rule per second
local LOG_MAX = 40

local bridge = peripheral.find("me_bridge") or error("no me_bridge", 0)
local mon = peripheral.find("monitor")
if mon then mon.setTextScale(SCALE) end

local LIVE = { QUEUED = true, CRAFTING = true }
-- ae_crafting event status -> what we show. Anything else (MISSING_ITEMS, NOT_CRAFTABLE, ...) is shown as is, in red.
local EVENT = { CALCULATION_STARTED = "QUEUED", CRAFTING_STARTED = "CRAFTING", JOB_DONE = "DONE", JOB_CANCELED = "CANCELED" }
local COLOUR = {
  QUEUED = colours.lightGrey, CRAFTING = colours.yellow, DONE = colours.lime,
  TRASHED = colours.orange, CANCELED = colours.grey, REBOOTED = colours.grey,
}

-- ---- state ----
-- { paused, stock = { ["item:id"] = { keep, batch, blocking, off, label } }, trash = { same }, log = { newest first } }
-- stock keep = min count in ME, batch = max per craft request (AE2 refuses a job it can't fully afford).
-- blocking = one at a time, each job waits for the last: for cyclical recipes that eat their own output
-- (1 smithing template -> 2), which AE2 can't plan in bulk. Not blocking = the whole deficit in one job.
-- trash keep = max count in ME. Hand edits are fine while Butler is stopped; "item:id": 256 is shorthand.
local db = {}
do
  local f = fs.open(DB, "r")
  if f then
    db = textutils.unserialiseJSON(f.readAll()) or error("bad json in " .. DB, 0)
    f.close()
  end
  for _, k in ipairs({ "stock", "trash", "log" }) do db[k] = db[k] or {} end
  for _, k in ipairs({ "stock", "trash" }) do
    for id, e in pairs(db[k]) do
      if type(e) ~= "table" then e = { keep = e } end
      e.keep = tonumber(e.keep) or 0
      db[k][id] = e
    end
  end
  -- jobs from before a restart never report back
  for _, e in ipairs(db.log) do if LIVE[e.st] then e.st = "REBOOTED" end end
end

local dirty = false
local function save()
  local f = fs.open(DB, "w")
  f.write(textutils.serialiseJSON(db))
  f.close()
  dirty = false
end

-- runtime per rule: have, st (status text, nil = nothing to say), wait (no new craft before this clock)
local rt = { stock = {}, trash = {} }
local function rtOf(kind, id)
  local r = rt[kind][id] or {}
  rt[kind][id] = r
  return r
end
local jobs = {} -- AP craft job id -> { r = runtime, entry = log entry }
local cpus, online = {}, false

local function fmt(n)
  if not n then return "?" end
  local u, i = { "", "K", "M", "G", "T", "P" }, 1
  while math.abs(n) >= 1000 and i < #u do n, i = n / 1000, i + 1 end
  return (i == 1 and "%.0f" or "%.2f"):format(n) .. u[i]
end
assert(fmt(999) == "999" and fmt(1500) == "1.50K")

local function clean(s) return (tostring(s):gsub("^%[(.*)%]$", "%1")) end -- AP wraps display names in []

local function need(have, keep, batch)
  return math.min(math.max(keep - have, 0), batch or math.huge)
end
assert(need(10, 64) == 54 and need(64, 64) == 0 and need(0, 1000, 256) == 256)

-- One line per item and kind: a new entry replaces the item's last finished one and carries its total
-- (made = crafted or trashed so far), so the log shows what happened lately, not one line forty times.
local function logAdd(e)
  e.t = os.date("%H:%M")
  for i, o in ipairs(db.log) do
    if o.kind == e.kind and o.id == e.id and not LIVE[o.st] then
      e.made = (o.made or 0) + (e.made or 0)
      table.remove(db.log, i)
      break
    end
  end
  table.insert(db.log, 1, e)
  db.log[LOG_MAX + 1] = nil
  dirty = true
  return e
end

-- ---- the work ----
local function count(id, r, e)
  local ok, info = pcall(bridge.getItem, { name = id })
  if not ok then r.st = tostring(info) return false end -- offline / bad id
  info = type(info) == "table" and info or {}
  r.have = info.count or 0
  if info.displayName then e.label = clean(info.displayName) end
  return true
end

local function checkStock(id, e)
  local r = rtOf("stock", id)
  if not count(id, r, e) then return end
  local n = need(r.have, e.keep, e.blocking and 1 or e.batch)
  if n == 0 or e.off or db.paused then r.st = nil return end
  local _, busy = pcall(bridge.isCrafting, { name = id })
  if busy == true then r.st = "CRAFTING" return end
  if r.st == "CRAFTING" then r.st = nil end
  -- a request needs a moment to land on a CPU before isCrafting sees it; failures back off the same way
  if os.clock() < (r.wait or 0) then return end
  r.wait = os.clock() + RETRY
  local called, job, err = pcall(bridge.craftItem, { name = id, count = n })
  if not called then job, err = nil, job end
  local entry = logAdd({ kind = "craft", id = id, label = e.label, n = n, st = job and "QUEUED" or tostring(err) })
  r.st = entry.st
  print(entry.t, e.label or id, "x" .. n, entry.st)
  if job then
    local ok, jid = pcall(job.getId)
    if ok then jobs[jid] = { r = r, entry = entry } end
  end
end

local function checkTrash(id, e)
  local r = rtOf("trash", id)
  if not count(id, r, e) then return end
  -- name-only filter: have is the first NBT variant found, the next variant drains on a later pass
  local extra = math.min(r.have - e.keep, PER_PASS)
  r.st = nil
  if extra <= 0 or e.off or db.paused then return end
  -- ONE item per call: AP ignores max stack size on export, and the trash can crashes the
  -- server saving an oversized stack (576 spell books in one slot = crash loop). Never raise this.
  local total, errs, calls = 0, nil, {}
  for i = 1, extra do
    calls[i] = function()
      local ok, got, err = pcall(bridge.exportItem, TARGET, { name = id, count = 1 })
      if not ok then errs = got
      elseif type(got) == "number" and got > 0 then total = total + got
      elseif err then errs = err end
    end
  end
  parallel.waitForAll(table.unpack(calls))
  if total > 0 then
    logAdd({ kind = "trash", id = id, label = e.label, n = total, made = total, st = "TRASHED" })
  elseif errs then
    r.st = tostring(errs) -- no trash on that side, trash full, ...
  end
end

-- ---- drawing (into an invisible window, flipped once per frame: no flicker) ----
local win, W, H
local buttons = {}
local TABS = { "HOME", "STOCK", "TRASH", "ADD" }
local tab, page = "HOME", 1
local src, letter, pick = "stock", nil, {} -- ADD tab: target list, first-letter filter, loaded items
local confirm                              -- rule whose delete button was tapped once

local function put(x, y, s, fg, bg)
  win.setCursorPos(x, y)
  win.setTextColour(fg or colours.white)
  win.setBackgroundColour(bg or colours.black)
  win.write(s)
end
local function rput(x2, y, s, fg, bg) put(x2 - #s + 1, y, s, fg, bg) end
local function btn(x, y, s, fg, bg, fn)
  put(x, y, s, fg, bg)
  buttons[#buttons + 1] = { x, x + #s - 1, y, fn }
  return x + #s
end
local function sel(on) return on and colours.black or colours.white, on and colours.lightBlue or colours.grey end
local function header(x, y, w, title, right)
  put(x, y, (" " .. title .. (" "):rep(w)):sub(1, w), colours.black, colours.lightBlue)
  if right then rput(x + w - 2, y, right, colours.black, colours.lightBlue) end
  return y + 1
end

local function state(kind, e, r)
  if e.off then return "OFF", colours.grey end
  if r.st then return r.st, COLOUR[r.st] or colours.red end
  if not r.have then return "...", colours.grey end
  if kind == "stock" then
    if r.have < e.keep then return "LOW", colours.orange end
  elseif r.have > e.keep then
    return "OVER", colours.orange
  end
  return "OK", colours.lime
end

-- footer with paging; returns the index before the first row to show
local function pager(n, per)
  local pages = math.max(1, math.ceil(n / math.max(1, per)))
  page = math.min(page, pages)
  put(1, H, (" "):rep(W), nil, colours.grey)
  btn(1, H, " < PREV ", colours.white, colours.grey, function() page = math.max(1, page - 1) end)
  local s = page .. "/" .. pages
  put(math.floor((W - #s) / 2) + 1, H, s, colours.white, colours.grey)
  btn(W - 7, H, " NEXT > ", colours.white, colours.grey, function() page = math.min(pages, page + 1) end)
  return (page - 1) * per
end

local function home(y0)
  local split = W >= 70 -- wide monitor: recent activity gets its own column
  local w = split and math.floor(W / 2) - 1 or W
  local busy = 0
  for _, c in ipairs(cpus) do if c.isBusy then busy = busy + 1 end end
  local y = header(1, y0, w, "CRAFTING", busy .. "/" .. #cpus .. " cpus busy")
  for _, c in ipairs(cpus) do
    local job = c.isBusy and type(c.craftingJob) == "table" and c.craftingJob
    if job then
      local res = type(job.resource) == "table" and job.resource or {}
      local what = clean(res.displayName or res.name or "?") .. " x" .. fmt(job.quantity)
      put(2, y, what:sub(1, math.max(0, w - 7)), colours.yellow)
      rput(w, y, ("%d%%"):format(math.floor((job.completion or 0) * 100))) -- completion is 0..1
      y = y + 1
    end
  end
  if busy == 0 then put(2, y, "idle", colours.grey) y = y + 1 end

  local rows, ok, total = {}, 0, 0
  for id, e in pairs(db.stock) do
    local r = rtOf("stock", id)
    local st, col = state("stock", e, r)
    total = total + 1
    if st == "OK" then ok = ok + 1 else rows[#rows + 1] = { e.label or id, fmt(r.have) .. "/" .. fmt(e.keep), st, col } end
  end
  table.sort(rows, function(a, b) return a[1] < b[1] end)
  y = header(1, y + 1, w, "STOCK", ok .. "/" .. total .. " stocked")
  local last = split and H or y + 5
  for _, v in ipairs(rows) do
    if y > last then break end
    put(2, y, v[1]:sub(1, math.max(0, w - 28)))
    rput(w - 14, y, v[2], colours.lightGrey)
    rput(w, y, v[3]:sub(1, 13), v[4])
    y = y + 1
  end
  if #rows == 0 then put(2, y, total > 0 and "all stocked" or "no rules yet: ADD tab", colours.grey) y = y + 1 end

  local x, rw = 1, W
  if split then x, rw, y = w + 3, W - w - 2, y0 - 1 end
  y = header(x, y + 1, rw, "RECENT")
  for _, e in ipairs(db.log) do
    if y > H then break end
    local st = e.st or "?"
    -- finished lines show the running total, live and failed ones the request itself
    local n = (st == "DONE" or st == "TRASHED") and e.made or e.n
    put(x + 1, y, (e.t .. " " .. (e.label or e.id) .. " x" .. fmt(n)):sub(1, math.max(0, rw - #st - 2)))
    rput(x + rw - 1, y, st, COLOUR[st] or colours.red)
    y = y + 1
  end
  if #db.log == 0 then put(x + 1, y, "nothing yet", colours.grey) end
end

local function rules(kind)
  return function(y0)
    local ids = {}
    for id in pairs(db[kind]) do ids[#ids + 1] = id end
    table.sort(ids, function(a, b) return (db[kind][a].label or a) < (db[kind][b].label or b) end)
    put(2, y0, kind == "stock" and "autocraft while below keep  (1x1 = blocking, one job at a time)" or "trash what is above keep  -> " .. TARGET, colours.lightGrey)
    local per = H - 1 - y0
    local first = pager(#ids, per)
    for i = 1, per do
      local id = ids[first + i]
      if not id then break end
      local e, r, y, key = db[kind][id], rtOf(kind, id), y0 + i, kind .. id
      local st, col = state(kind, e, r)
      btn(1, y, e.off and " OFF" or " ON ", e.off and colours.lightGrey or colours.black, e.off and colours.grey or colours.lime,
        function() e.off = not e.off or nil save() end)
      local x = W - 11
      btn(x, y, " /2", colours.white, colours.grey, function() e.keep = math.floor(e.keep / 2) save() end)
      btn(x + 4, y, " x2", colours.white, colours.grey, function() e.keep = math.max(1, e.keep * 2) save() end)
      -- two taps to delete: anyone walking past can reach the monitor
      btn(x + 8, y, confirm == key and "DEL?" or " DEL", colours.white, confirm == key and colours.red or colours.grey,
        function(armed) if armed == key then db[kind][id] = nil save() else confirm = key end end)
      if kind == "stock" then
        x = x - 6
        btn(x, y, e.blocking and " 1x1 " or " BULK", colours.white, e.blocking and colours.purple or colours.grey,
          function() e.blocking = not e.blocking or nil save() end)
      end
      rput(x - 2, y, fmt(r.have) .. "/" .. fmt(e.keep), col)
      local nameEnd = x - 14 -- count column is 11 wide
      if nameEnd >= 40 then
        rput(nameEnd, y, st:sub(1, 13), col)
        nameEnd = nameEnd - 14
      end
      put(6, y, (e.label or id):sub(1, math.max(0, nameEnd - 6)), e.off and colours.grey or colours.white)
    end
    if #ids == 0 then put(2, y0 + 2, "no rules yet: ADD tab", colours.grey) end
  end
end

local function loadPick()
  pick = {}
  -- ponytail: dumps every pattern / stored item, but only when this tab is opened, never on a timer
  -- (getItems every pass stalled the server on RS). Add a search box if the letter bar gets too coarse.
  local ok, list = pcall(src == "stock" and bridge.getCraftableItems or bridge.getItems)
  local seen = {}
  for _, it in ipairs(ok and type(list) == "table" and list or {}) do
    if it.name and not seen[it.name] then -- one row per id, NBT variants collapse
      seen[it.name] = true
      pick[#pick + 1] = { id = it.name, label = clean(it.displayName or it.name), n = it.count or 0 }
    end
  end
  table.sort(pick, function(a, b) return a.label:lower() < b.label:lower() end)
end

local function add(y0)
  local function source(x, s, label)
    local fg, bg = sel(src == s)
    return btn(x, y0, label, fg, bg, function() src, page = s, 1 loadPick() end) + 1
  end
  source(source(1, "stock", " CRAFTABLE > STOCK "), "trash", " STORED > TRASH ")
  local fg, bg = sel(not letter)
  local x = btn(1, y0 + 1, "ALL", fg, bg, function() letter, page = nil, 1 end) + 1
  local gap = W >= 56 and 1 or 0
  for c in ("ABCDEFGHIJKLMNOPQRSTUVWXYZ"):gmatch(".") do
    fg, bg = sel(letter == c)
    x = btn(x, y0 + 1, c, fg, bg, function() letter, page = c, 1 end) + gap
  end
  local list = {}
  for _, p in ipairs(pick) do
    if not letter or p.label:sub(1, 1):upper() == letter then list[#list + 1] = p end
  end
  local per = H - 2 - y0
  local first = pager(#list, per)
  for i = 1, per do
    local p = list[first + i]
    if not p then break end
    local y, line = y0 + 1 + i, (p.label .. (" "):rep(W)):sub(1, math.max(0, W - 11))
    if db[src][p.id] then
      put(1, y, " * " .. line, colours.grey)
    else
      btn(1, y, " + " .. line, colours.white, colours.black, function()
        -- trash rules start OFF at the current count: nothing leaves until someone lowers keep and turns it on
        db[src][p.id] = src == "stock" and { keep = 64, label = p.label } or { keep = p.n, off = true, label = p.label }
        save()
      end)
    end
    rput(W, y, fmt(p.n), colours.lightGrey)
  end
  if #list == 0 then put(2, y0 + 3, #pick == 0 and "nothing found (bridge offline? no patterns?)" or "nothing under " .. letter, colours.grey) end
end

local VIEWS = { HOME = home, STOCK = rules("stock"), TRASH = rules("trash"), ADD = add }

local function draw()
  if not mon then return end
  local w, h = mon.getSize()
  if w ~= W or h ~= H then
    W, H = w, h
    win = window.create(mon, 1, 1, W, H, false)
  end
  win.setVisible(false)
  win.setBackgroundColour(colours.black)
  win.clear()
  buttons = {}
  put(1, 1, (" "):rep(W), nil, colours.blue)
  put(2, 1, "BUTLER", colours.white, colours.blue)
  put(10, 1, online and "ME online" or "ME OFFLINE", online and colours.lime or colours.red, colours.blue)
  btn(W - 7, 1, db.paused and " PAUSED " or " ACTIVE ", colours.black, db.paused and colours.orange or colours.lime,
    function() db.paused = not db.paused or nil save() end)
  put(1, 2, (" "):rep(W), nil, colours.grey)
  local x = 1
  for _, t in ipairs(TABS) do
    local fg, bg = sel(tab == t)
    x = btn(x, 2, " " .. t .. " ", fg, bg, function()
      tab, page = t, 1
      if t == "ADD" then loadPick() end
    end)
  end
  VIEWS[tab](3)
  win.setVisible(true)
end

-- ---- loops ----
-- Every entry's calls are queued at once so they share ticks instead of taking one tick each.
local function stockLoop()
  while true do
    local calls = {}
    for id, e in pairs(db.stock) do calls[#calls + 1] = function() checkStock(id, e) end end
    parallel.waitForAll(table.unpack(calls))
    if dirty then save() end
    draw()
    local t = os.startTimer(POLL)
    repeat local ev, a = os.pullEvent() until ev == "butler_poke" or (ev == "timer" and a == t)
  end
end

-- every second: trash rules, plus the two cheap calls the header and HOME need to follow jobs live
local function fastLoop()
  while true do
    local calls = {
      function() local ok, v = pcall(bridge.getCraftingCPUs) cpus = ok and type(v) == "table" and v or {} end,
      function() local ok, v = pcall(bridge.isOnline) online = ok and v == true end,
    }
    for id, e in pairs(db.trash) do calls[#calls + 1] = function() checkTrash(id, e) end end
    parallel.waitForAll(table.unpack(calls))
    draw()
    sleep(1)
  end
end

-- AP reports on jobs we started: ae_crafting, isError, jobId, status
local function jobLoop()
  while true do
    local _, _, jid, status = os.pullEvent("ae_crafting")
    local j = jobs[jid]
    if j then
      local st = EVENT[status] or tostring(status)
      j.entry.st = st
      if st == "DONE" then j.entry.made = (j.entry.made or 0) + j.entry.n end
      j.r.st = st ~= "DONE" and st or nil
      if not LIVE[st] then
        jobs[jid] = nil
        -- still short (batch cap, blocking)? don't sit out the poll, ask for the next one now
        if st == "DONE" then j.r.wait = nil os.queueEvent("butler_poke") end
        print(os.date("%H:%M"), j.entry.label or j.entry.id, "x" .. j.entry.n, st)
      end
      dirty = true
      draw()
    end
  end
end

local function uiLoop()
  while true do
    local ev, _, x, y = os.pullEvent()
    if ev == "monitor_touch" then
      local armed = confirm
      confirm = nil
      for _, b in ipairs(buttons) do
        if y == b[3] and x >= b[1] and x <= b[2] then b[4](armed) break end
      end
      draw()
    elseif ev == "monitor_resize" then
      draw()
    end
  end
end

print("butler: trash -> " .. TARGET .. (mon and "" or ", no monitor (headless)"))
draw()
parallel.waitForAny(stockLoop, fastLoop, jobLoop, uiLoop)
