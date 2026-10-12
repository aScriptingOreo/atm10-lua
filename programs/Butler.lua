-- Butler: ME system manager. Computer next to an ME Bridge, advanced monitor on any side (optional).
-- Keeps items stocked: autocrafts anything below its keep count.
-- Monitor: HOME is the dashboard, STOCK edits rules (tap one), ADD picks craftable items from the network.
-- Rules in programs/Butler.json (this repo) are re-fetched while running: push an edit, no reboot.
-- @desc ME system manager: keeps items stocked (autocraft), touch dashboard on a monitor
-- @deps cn_lib
-- @config Poll|Seconds between stock checks|10
-- @config TextScale|Monitor text scale (0.5 small, 1 normal, up to 5)|1
-- @config Sync|Seconds between re-fetching Butler.json from the repo (0 = off)|60
local cfg = dofile("/lib/cn.lua")
local POLL = tonumber(cfg.Poll) or 10
local SCALE = tonumber(cfg.TextScale) or 1
local SYNC = tonumber(cfg.Sync) or 60
-- ponytail: raw /main/ is CDN-cached for minutes, so a push takes up to ~5 min to land.
-- Resolve the commit sha first (like cookienet does) if that ever matters.
local RULES_URL = "https://raw.githubusercontent.com/aScriptingOreo/atm10-lua/main/programs/Butler.json"
local DB = "/butler.json" -- local state, not shipped with the package: cookienet update never overwrites it
local RETRY = 60          -- seconds before re-requesting a craft that failed or never reached a CPU
local LOG_MAX = 40

local bridge = peripheral.find("me_bridge") or error("no me_bridge", 0)
local mon = peripheral.find("monitor")
if mon then mon.setTextScale(SCALE) end

local LIVE = { QUEUED = true, CRAFTING = true }
-- AP status -> what we show. Anything not listed (AE2 submit errors like CPU_BUSY) is shown as is, in red.
local SHOW = {
  CALCULATION_STARTED = "QUEUED", CRAFTING_STARTED = "CRAFTING", JOB_DONE = "DONE", JOB_CANCELED = "CANCELED",
  MISSING_ITEMS = "MISSING", NOT_CRAFTABLE = "NO PATTERN",
}
local COLOUR = {
  QUEUED = colours.cyan, CRAFTING = colours.yellow, DONE = colours.lime,
  CANCELED = colours.lightGrey, REBOOTED = colours.lightGrey,
}

-- ---- state ----
-- { paused, stock = { ["item:id"] = { keep, batch, blocking, off, label } }, log = { newest first }, seed }
-- keep = min count in ME, batch = max per craft request (AE2 refuses a job it can't fully afford).
-- blocking = one job at a time, sized to what the stock can feed: for cyclical recipes that eat their own
-- output (1 smithing template -> 2), which AE2 can't plan past what is in storage. See want().
-- seed = the repo rules as last seen, so a re-fetch only overrides a rule when the repo changed it.
local db = {}
do
  local f = fs.open(DB, "r")
  if f then
    db = textutils.unserialiseJSON(f.readAll()) or error("bad json in " .. DB, 0)
    f.close()
  end
  for _, k in ipairs({ "stock", "log", "seed" }) do db[k] = db[k] or {} end
  for id, e in pairs(db.stock) do
    if type(e) ~= "table" then e = { keep = e } end -- "item:id": 256 shorthand
    e.keep = tonumber(e.keep) or 0
    db.stock[id] = e
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

-- runtime per rule: have, st (status text, nil = nothing to say), wait (no new craft before this clock),
-- cap (blocking: request ceiling after a refused job), missing (what the last refused job lacked),
-- ask (refused job to query for that), said (last thing printed, so the terminal only shows changes)
local rt = {}
local function rtOf(id)
  local r = rt[id] or {}
  rt[id] = r
  return r
end
local jobs = {} -- AP craft job id -> { r, entry (log line), job, name, n = requested, net = stock gained, cyclic }
local cpus, online = {}, false
local synced -- "HH:MM" of the last good rules fetch, false = last one failed

local function fmt(n)
  if not n then return "?" end
  local u, i = { "", "K", "M", "G", "T", "P" }, 1
  while math.abs(n) >= 1000 and i < #u do n, i = n / 1000, i + 1 end
  return (i == 1 and "%.0f" or "%.2f"):format(n) .. u[i]
end
assert(fmt(999) == "999" and fmt(1500) == "1.50K")

local function clean(s) return (tostring(s):gsub("^%[(.*)%]$", "%1")) end -- AP wraps display names in []

-- terminal: one line per rule per change, never the same thing twice in a row
local function say(r, name, what)
  if r.said == what then return end
  r.said = what
  print(os.date("%H:%M") .. " " .. name .. ": " .. what)
end

-- how many to request for rule e
local function want(have, e, cap)
  local short = math.max(e.keep - have, 0)
  if not e.blocking then return math.min(short, e.batch or math.huge) end
  if short == 0 then return 0 end
  -- 1 in -> 2 out: a job can run at most `have` crafts (it eats the stock it starts with) and each craft
  -- nets +1. Asking for 2 per craft doubles the stock every job (2 -> 4 -> 8 ...) instead of +1 a job.
  return math.max(1, math.min(2 * short, 2 * have, cap or math.huge))
end
assert(want(10, { keep = 64 }) == 54 and want(64, { keep = 64 }) == 0 and want(0, { keep = 1000, batch = 256 }) == 256)
assert(want(2, { keep = 1000, blocking = true }) == 4 and want(512, { keep = 1000, blocking = true }) == 976)
assert(want(63, { keep = 64, blocking = true }) == 2 and want(0, { keep = 64, blocking = true }) == 1)
assert(want(100, { keep = 1000, blocking = true }, 50) == 50 and want(64, { keep = 64, blocking = true }) == 0)

-- One line per item: a new entry replaces the item's last finished one and carries its total (made),
-- so the log shows what happened lately, not the same line forty times.
local function logAdd(e)
  e.t = os.date("%H:%M")
  for i, o in ipairs(db.log) do
    if o.id == e.id and not LIVE[o.st] then
      e.made = o.made
      table.remove(db.log, i)
      break
    end
  end
  table.insert(db.log, 1, e)
  db.log[LOG_MAX + 1] = nil
  dirty = true
  return e
end

-- job.getMissingItems() -> "7 Vibranium Ingot, 1 End Stone"
local function missingText(list)
  local t = {}
  for _, it in ipairs(type(list) == "table" and list or {}) do
    if type(it) == "table" then t[#t + 1] = fmt(it.count or it.amount) .. " " .. clean(it.displayName or it.name or "?") end
  end
  return #t > 0 and table.concat(t, ", ") or nil
end

-- ---- the work ----
local function checkStock(id, e)
  local r = rtOf(id)
  local ok, info = pcall(bridge.getItem, { name = id })
  if not ok then -- offline / bad id
    r.st = tostring(info)
    return say(r, e.label or id, r.st)
  end
  info = type(info) == "table" and info or {}
  r.have = info.count or 0
  if info.displayName then e.label = clean(info.displayName) end
  local name = e.label or id
  if r.ask then -- a job came back MISSING: ask it what for (here, not in jobLoop: the call may yield)
    local asked, list = pcall(r.ask.getMissingItems)
    r.ask, r.missing = nil, asked and missingText(list) or nil
    say(r, name, "MISSING" .. (r.missing and " " .. r.missing or ""))
  end
  local n = want(r.have, e, r.cap)
  if n == 0 or e.off or db.paused then
    r.st, r.missing, r.said = nil, nil, nil
    return
  end
  local _, busy = pcall(bridge.isCrafting, { name = id })
  if busy == true then r.st = "CRAFTING" return end
  if r.st == "CRAFTING" then r.st = nil end
  -- a request needs a moment to land on a CPU before isCrafting sees it; failures back off the same way
  if os.clock() < (r.wait or 0) then return end
  r.wait = os.clock() + RETRY
  local called, job, err = pcall(bridge.craftItem, { name = id, count = n })
  if not called then job, err = nil, job end
  r.st = job and "QUEUED" or SHOW[err] or tostring(err)
  local entry = logAdd({ id = id, label = e.label, n = n, st = r.st })
  if not job then return say(r, name, r.st) end
  local gotId, jid = pcall(job.getId)
  if gotId then
    -- blocking jobs eat half of what they make: count the net gain, and let a refusal halve the next ask
    jobs[jid] = { r = r, entry = entry, job = job, name = name, n = n, net = e.blocking and math.ceil(n / 2) or n, cyclic = e.blocking }
  end
end

-- Repo rules win only when the repo changed them: a new or edited rule is applied, a removed one is deleted,
-- an untouched one keeps whatever the monitor did to it. Returns true if anything changed.
local function applyRules(remote)
  local list, seen, changed = type(remote.stock) == "table" and remote.stock or {}, db.seed, false
  for id, rule in pairs(list) do
    if type(rule) ~= "table" then rule = { keep = rule } end
    local sig = table.concat({ tostring(rule.keep), tostring(rule.batch), tostring(rule.blocking), tostring(rule.off) }, "|")
    if seen[id] ~= sig and tonumber(rule.keep) then
      seen[id] = sig
      db.stock[id] = {
        keep = tonumber(rule.keep), batch = tonumber(rule.batch), blocking = rule.blocking or nil,
        off = rule.off or nil, label = db.stock[id] and db.stock[id].label,
      }
      changed = true
    end
  end
  for id in pairs(seen) do
    if list[id] == nil then seen[id], db.stock[id], changed = nil, nil, true end
  end
  return changed
end

-- ---- drawing (into an invisible window, flipped once per frame: no flicker) ----
-- Laid out to still work on a 3x2 monitor at text scale 1 (29x12 characters).
local win, W, H
local buttons = {}
local TABS = { "HOME", "STOCK", "ADD" }
local tab, page = "HOME", 1
local sel, confirm      -- STOCK: selected rule id, its delete button was tapped once
local letter, pick = nil, {} -- ADD: first-letter filter, craftable items

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
local function tabCol(on) return on and colours.black or colours.white, on and colours.lightBlue or colours.grey end
local function header(x, y, w, title, right)
  put(x, y, (" " .. title .. (" "):rep(w)):sub(1, w), colours.black, colours.lightBlue)
  if right then rput(x + w - 2, y, right, colours.black, colours.lightBlue) end
  return y + 1
end

local function state(e, r)
  if e.off then return "OFF", colours.lightGrey end
  if r.st then return r.st, COLOUR[r.st] or colours.red end
  if not r.have then return "...", colours.lightGrey end
  if r.have < e.keep then return "LOW", colours.orange end
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
  local gap = H >= 20 and 1 or 0
  local busy = 0
  for _, c in ipairs(cpus) do if c.isBusy then busy = busy + 1 end end
  local y = header(1, y0, w, "CRAFTING", busy .. "/" .. #cpus .. " busy")
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
  if busy == 0 then put(2, y, "idle", colours.lightGrey) y = y + 1 end

  local rows, ok, total = {}, 0, 0
  for id, e in pairs(db.stock) do
    local r = rtOf(id)
    local st, col = state(e, r)
    total = total + 1
    if st == "OK" then ok = ok + 1 else rows[#rows + 1] = { e.label or id, fmt(r.have) .. "/" .. fmt(e.keep), st:sub(1, 10), col } end
  end
  table.sort(rows, function(a, b) return a[1] < b[1] end)
  y = header(1, y + gap, w, "STOCK", ok .. "/" .. total .. " ok")
  local last = split and H or y + math.max(0, math.floor((H - y) / 2) - 1)
  for _, v in ipairs(rows) do
    if y > last then break end
    local room = w - #v[3] - 3
    if w >= 45 then -- room for the count too
      rput(w - 11, y, v[2], colours.lightGrey)
      room = w - 13 - #v[2]
    end
    put(2, y, v[1]:sub(1, math.max(0, room)))
    rput(w, y, v[3], v[4])
    y = y + 1
  end
  if #rows == 0 then put(2, y, total > 0 and "all stocked" or "no rules: ADD tab", colours.lightGrey) y = y + 1 end

  local x, rw = 1, W
  if split then x, rw, y = w + 3, W - w - 2, y0 - gap end
  y = header(x, y + gap, rw, "RECENT")
  for _, e in ipairs(db.log) do
    if y > H then break end
    local st = (e.st or "?"):sub(1, 10)
    -- finished lines show the running total, live and failed ones the request itself
    local what = (e.label or e.id) .. " x" .. fmt(st == "DONE" and e.made or e.n)
    if rw >= 40 then what = e.t .. " " .. what end
    put(x + 1, y, what:sub(1, math.max(0, rw - #st - 2)))
    rput(x + rw - 1, y, st, COLOUR[st] or colours.red)
    y = y + 1
  end
  if #db.log == 0 then put(x + 1, y, "nothing yet", colours.lightGrey) end
end

-- rule list; tap one to get its buttons on the two rows above the pager
local function stock(y0)
  if sel and not db.stock[sel] then sel = nil end
  local ids = {}
  for id in pairs(db.stock) do ids[#ids + 1] = id end
  table.sort(ids, function(a, b) return (db.stock[a].label or a) < (db.stock[b].label or b) end)
  local per = H - 2 - y0
  local first = pager(#ids, per)
  for i = 1, per do
    local id = ids[first + i]
    if not id then break end
    local e, y = db.stock[id], y0 + i - 1
    local _, col = state(e, rtOf(id))
    local bg = id == sel and colours.grey or colours.black
    btn(1, y, (" " .. (e.label or id) .. (" "):rep(W)):sub(1, W), e.off and colours.lightGrey or colours.white, bg,
      function() sel = id ~= sel and id or nil end)
    rput(W, y, " " .. fmt(rtOf(id).have) .. "/" .. fmt(e.keep), col, bg)
  end
  if #ids == 0 then put(2, y0 + 1, "no rules yet: ADD tab", colours.lightGrey) end

  local e = sel and db.stock[sel]
  if not e then return put(2, H - 2, "tap a rule to edit it", colours.lightGrey) end
  local r = rtOf(sel)
  local st, col = state(e, r)
  put(2, H - 2, (st .. (st == "MISSING" and r.missing and " " .. r.missing or "  keep " .. e.keep)):sub(1, W - 2), col)
  local y = H - 1
  local x = btn(1, y, e.off and " OFF" or " ON ", colours.black, e.off and colours.lightGrey or colours.lime,
    function() e.off = not e.off or nil save() end) + 1
  -- LOOP = blocking (recipe eats its own output), BULK = whole deficit in one job
  x = btn(x, y, e.blocking and " LOOP" or " BULK", colours.white, e.blocking and colours.purple or colours.grey,
    function() e.blocking = not e.blocking or nil save() end) + 1
  x = btn(x, y, " /2", colours.white, colours.grey, function() e.keep = math.floor(e.keep / 2) save() end) + 1
  x = btn(x, y, " x2", colours.white, colours.grey, function() e.keep = math.max(1, e.keep * 2) save() end) + 1
  -- two taps to delete: anyone walking past can reach the monitor
  btn(x, y, confirm and "DEL?" or " DEL", colours.white, confirm and colours.red or colours.grey, function(armed)
    if armed then db.stock[sel] = nil save() else confirm = true end
  end)
end

local function loadPick()
  pick = {}
  -- ponytail: dumps every pattern, but only when this tab is opened, never on a timer (full dumps every
  -- pass stalled the server on RS). Add a search box if the letter bar gets too coarse.
  local ok, list = pcall(bridge.getCraftableItems)
  local seen = {}
  for _, it in ipairs(ok and type(list) == "table" and list or {}) do
    if it.name and not seen[it.name] then -- one row per id, NBT variants collapse
      seen[it.name] = true
      pick[#pick + 1] = { id = it.name, label = clean(it.displayName or it.name) }
    end
  end
  table.sort(pick, function(a, b) return a.label:lower() < b.label:lower() end)
end

local function add(y0)
  local gap = W >= 56 and 1 or 0
  local fg, bg = tabCol(not letter)
  local x = btn(1, y0, "*", fg, bg, function() letter, page = nil, 1 end) + gap
  for c in ("ABCDEFGHIJKLMNOPQRSTUVWXYZ"):gmatch(".") do
    fg, bg = tabCol(letter == c)
    x = btn(x, y0, c, fg, bg, function() letter, page = c, 1 end) + gap
  end
  local list = {}
  for _, p in ipairs(pick) do
    if not letter or p.label:sub(1, 1):upper() == letter then list[#list + 1] = p end
  end
  local per = H - 1 - y0
  local first = pager(#list, per)
  for i = 1, per do
    local p = list[first + i]
    if not p then break end
    local line = (p.label .. (" "):rep(W)):sub(1, math.max(0, W - 3))
    if db.stock[p.id] then
      put(1, y0 + i, " * " .. line, colours.grey)
    else
      btn(1, y0 + i, " + " .. line, colours.white, colours.black, function()
        db.stock[p.id] = { keep = 64, label = p.label }
        sel = p.id -- so STOCK opens with it ready to edit
        save()
      end)
    end
  end
  if #list == 0 then put(2, y0 + 2, #pick == 0 and "no patterns found" or "nothing under " .. letter, colours.lightGrey) end
end

local VIEWS = { HOME = home, STOCK = stock, ADD = add }

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
  if synced ~= nil and W >= 50 then
    put(22, 1, synced and "rules " .. synced or "rules FETCH FAILED", synced and colours.lightGrey or colours.red, colours.blue)
  end
  btn(W - 7, 1, db.paused and " PAUSED " or " ACTIVE ", colours.black, db.paused and colours.orange or colours.lime,
    function() db.paused = not db.paused or nil save() end)
  put(1, 2, (" "):rep(W), nil, colours.grey)
  local x = 1
  for _, t in ipairs(TABS) do
    local fg, bg = tabCol(tab == t)
    x = btn(x, 2, " " .. t .. " ", fg, bg, function()
      tab, page = t, 1
      if t == "ADD" then loadPick() end
    end)
  end
  VIEWS[tab](3)
  win.setVisible(true)
end

-- ---- loops ----
local function stockLoop()
  while true do
    -- every rule's calls queued at once so they share ticks instead of taking one tick each
    local calls = {}
    for id, e in pairs(db.stock) do calls[#calls + 1] = function() checkStock(id, e) end end
    parallel.waitForAll(table.unpack(calls))
    if dirty then save() end
    draw()
    local t = os.startTimer(POLL)
    repeat local ev, a = os.pullEvent() until ev == "butler_poke" or (ev == "timer" and a == t)
  end
end

-- the two cheap calls the header and HOME need to follow jobs live
local function cpuLoop()
  while true do
    parallel.waitForAll(
      function() local ok, v = pcall(bridge.getCraftingCPUs) cpus = ok and type(v) == "table" and v or {} end,
      function() local ok, v = pcall(bridge.isOnline) online = ok and v == true end)
    draw()
    sleep(2)
  end
end

-- AP reports on jobs we started: ae_crafting, isError, jobId, status
local function jobLoop()
  while true do
    local _, _, jid, status = os.pullEvent("ae_crafting")
    local j = jobs[jid]
    if j then
      local st, r = SHOW[status] or tostring(status), j.r
      j.entry.st, r.st = st, st ~= "DONE" and st or nil
      if not LIVE[st] then
        jobs[jid] = nil
        if st == "DONE" then
          j.entry.made = (j.entry.made or 0) + j.net
          if r.cap then r.cap = r.cap * 2 end -- it fit: grow back
          r.wait, r.missing = nil, nil -- still short (batch cap, blocking)? ask for the next one now
          say(r, j.name, "DONE")
        elseif st == "MISSING" and j.cyclic and j.n > 1 then
          -- too big for the other ingredients (ingots ran out before templates did): try half, now
          r.cap, r.wait = math.floor(j.n / 2), nil
        elseif st == "MISSING" then
          r.ask = j.job -- the stock pass asks the job what it lacked, and prints it
        else
          say(r, j.name, st)
        end
        os.queueEvent("butler_poke")
      end
      dirty = true
      draw()
    end
  end
end

local function syncLoop()
  while true do
    local r = http.get(RULES_URL .. "?t=" .. os.epoch("utc"))
    local remote = r and textutils.unserialiseJSON(r.readAll())
    if r then r.close() end
    if type(remote) == "table" then
      synced = os.date("%H:%M")
      if applyRules(remote) then
        save()
        os.queueEvent("butler_poke")
      end
    else
      synced = false -- github down or bad json pushed: keep running on what we have
    end
    draw()
    sleep(SYNC)
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

print("butler running" .. (mon and "" or ", no monitor (headless)") .. ". Only changes are printed here.")
draw()
local loops = { stockLoop, cpuLoop, jobLoop, uiLoop }
if SYNC > 0 then loops[#loops + 1] = syncLoop end
parallel.waitForAny(table.unpack(loops))
