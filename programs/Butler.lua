-- Butler: ME system manager. Computer next to an ME Bridge, advanced monitor on any side (optional).
-- Keeps items stocked: autocrafts anything below its keep count.
-- Computer screen: LOG, and ADD (type to search craftable items, pick one, type how many to keep).
-- Monitor: HOME is the dashboard, STOCK edits rules (tap one).
-- Rules in programs/Butler.json (this repo) are re-fetched while running: push an edit, no reboot.
-- @desc ME system manager: keeps items stocked (autocraft), search-to-add on the computer, dashboard on a monitor
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
local RETRY = 60          -- seconds before trying again a craft nothing could be done about
local JOB_TIMEOUT = 600   -- a job that never reported back is forgotten after this
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
  QUEUED = colours.cyan, CRAFTING = colours.yellow, PREP = colours.yellow, DONE = colours.lime,
  CANCELED = colours.lightGrey, REBOOTED = colours.lightGrey,
}

-- ---- state ----
-- { paused, stock = { ["item:id"] = { keep, batch, blocking, off, label } }, log = { newest first }, seed }
-- keep = min count in ME, batch = max per craft request.
-- blocking = cyclical recipe (its ingredients come from the item itself): never ask for more than the
-- current stock can turn into, see want().
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

-- runtime per rule:
--   have, st (status text, nil = nothing to say), missing (what the last refused job lacked)
--   job + deadline (our job in flight), done (finished job waiting for settle())
--   wait (no new request before this clock), cap (request ceiling, halved by a refusal)
--   sub = { id, label, n } (ingredient to craft before the item), subbed (did that this attempt),
--   goal + base (what was asked for and what was in stock when the ingredient detour started)
--   stuck (stock level at which the ingredient detour stopped paying off)
--   said (last thing logged, so the log only shows changes)
local rt = {}
local function rtOf(id)
  local r = rt[id] or {}
  rt[id] = r
  return r
end
local jobs = {} -- AP craft job id -> { r, entry (RECENT line), job, n = requested, sub = is an ingredient job }
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

-- how many to request for rule e
local function want(have, e, cap)
  local short = math.max(e.keep - have, 0)
  local n = math.min(short, e.batch or math.huge, cap or math.huge)
  -- cyclical: the stock is also the raw material, so at best a job doubles it (2 -> 4 -> 8 ...)
  if e.blocking and short > 0 then n = math.max(1, math.min(n, 2 * have)) end
  return n
end
assert(want(10, { keep = 64 }) == 54 and want(64, { keep = 64 }) == 0 and want(0, { keep = 1000, batch = 256 }) == 256)
assert(want(2, { keep = 1000, blocking = true }) == 4 and want(900, { keep = 1000, blocking = true }) == 100)
assert(want(0, { keep = 64, blocking = true }) == 1 and want(64, { keep = 64, blocking = true }) == 0)
assert(want(100, { keep = 1000 }, 50) == 50 and want(100, { keep = 1000, blocking = true }, 50) == 50)

-- One RECENT line per item: a new entry replaces the item's last finished one and carries its total (made),
-- so the list shows what happened lately, not the same line forty times.
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
  for _, it in ipairs(list) do
    if type(it) == "table" then t[#t + 1] = fmt(it.count or it.amount) .. " " .. clean(it.displayName or it.name or "?") end
  end
  return #t > 0 and table.concat(t, ", ") or nil
end

-- ---- computer screen: LOG / ADD (drawn further down, the work needs say()) ----
local TW, TH = term.getSize()
local view = "LOG"
local lines = {} -- log, oldest first, already wrapped to the screen width
local drawTerm

-- one line per rule per change, never the same thing twice in a row
local function say(r, name, what)
  if r.said == what then return end
  r.said = what
  local s = os.date("%H:%M") .. " " .. name .. ": " .. what
  for i = 1, #s, TW do lines[#lines + 1] = s:sub(i, i + TW - 1) end
  while #lines > 200 do table.remove(lines, 1) end
  drawTerm()
end

-- ---- the work ----
-- A finished job decides what happens next. Runs in the stock pass, not in jobLoop: getMissingItems may yield.
--
-- AE2 never feeds stored copies of the REQUESTED item into the plan, so for a cycle (crystal -> dust -> crystal)
-- a crystal job reports "missing dust" no matter how many crystals are stored. Requesting the dust is a
-- different job, and that one may eat the crystals. So on MISSING: craft the missing ingredient if it has a
-- pattern, then try the item again; whatever still does not fit gets halved (N/2, N/4, ...) until it does.
local function settle(id, r, name)
  local j = r.done
  r.done, r.st = nil, nil
  if j.st == "DONE" then
    j.entry.made = (j.entry.made or 0) + j.n
    if j.sub then r.sub, r.subbed = nil, true return end -- ingredient is in: now the item itself
    if r.subbed and r.have <= (r.base or -1) then
      -- went round the cycle and ended up with no more than before: stop burning the other ingredients.
      -- No more ingredient detours until the stock level moves; plain requests carry on.
      r.stuck = r.have
      say(r, name, "cycle makes no more than it eats, not feeding it")
    else
      say(r, name, "DONE")
    end
    r.cap = r.cap and r.cap * 2 -- it fit: grow back
    r.subbed, r.goal, r.base, r.missing = nil, nil, nil, nil
    return
  end
  if j.st ~= "MISSING" then -- cancelled, no free CPU, ...
    r.st, r.wait, r.sub = j.st, os.clock() + RETRY, nil
    return say(r, name, j.st)
  end
  local ok, list = pcall(j.job.getMissingItems)
  list = ok and type(list) == "table" and list or {}
  r.missing = missingText(list)
  local itself, sub -- the item is missing itself / first missing ingredient that has a pattern
  for _, it in ipairs(list) do
    if type(it) == "table" and it.name == id then
      itself = true
    elseif type(it) == "table" and it.name and not (sub or j.sub or r.subbed or r.stuck)
      and select(2, pcall(bridge.isCraftable, { name = it.name })) == true then
      sub = it
    end
  end
  if j.sub then
    -- that much of the ingredient is not affordable (in a cycle it is made out of the item): less, or none
    if j.n > 1 then r.sub.n = math.floor(j.n / 2) else r.sub, r.subbed = nil, true end
  elseif itself then
    -- the recipe takes the item itself (1 template -> 2): AE2 cannot plan that at any amount
    r.st, r.wait = "SELF LOOP", os.clock() + 10 * RETRY
    say(r, name, "recipe needs the item itself, AE2 cannot plan that")
  elseif sub then
    r.sub = { id = sub.name, label = clean(sub.displayName or sub.name), n = sub.count or sub.amount or 1 }
    r.goal, r.base = j.n, r.have
  elseif j.n > 1 then
    r.cap = math.floor(j.n / 2) -- maybe half is affordable
  else
    r.st, r.wait, r.subbed, r.goal, r.base = "MISSING", os.clock() + RETRY, nil, nil, nil
    say(r, name, "MISSING " .. (r.missing or "?"))
  end
end

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
  if r.done then settle(id, r, name) end
  if r.stuck ~= r.have then r.stuck = nil end -- something was used or added: detours are worth another go
  local n = want(r.have, e, r.cap)
  if n == 0 or e.off or db.paused then
    r.st, r.missing, r.said, r.wait, r.sub, r.subbed, r.goal, r.base = nil, nil, nil, nil, nil, nil, nil, nil
    return
  end
  if r.job and os.clock() < r.deadline then return end -- our job is still out
  local _, busy = pcall(bridge.isCrafting, { name = id })
  if busy == true then r.st = "CRAFTING" return end    -- somebody else's job
  if r.st == "CRAFTING" then r.st = nil end
  if os.clock() < (r.wait or 0) then return end
  local what, label = id, e.label
  if r.sub then
    what, label, n = r.sub.id, r.sub.label, r.sub.n
  elseif r.goal then
    -- back from the ingredient detour: the stock was just turned into ingredients, so size the job by
    -- what was asked for before, not by what is left in storage
    n = math.min(r.goal, r.cap or math.huge)
  end
  local called, job, err = pcall(bridge.craftItem, { name = what, count = n })
  if not called then job, err = nil, job end
  local st = job and "QUEUED" or SHOW[err] or tostring(err)
  local entry = logAdd({ id = what, label = label, n = n, st = st })
  local gotId, jid
  if job then gotId, jid = pcall(job.getId) end
  if not gotId then
    r.st, r.wait, r.sub = job and "?" or st, os.clock() + RETRY, nil
    return say(r, name, r.st)
  end
  r.st = r.sub and "PREP" or st -- PREP = crafting an ingredient first
  r.job, r.deadline = jid, os.clock() + JOB_TIMEOUT
  jobs[jid] = { r = r, entry = entry, job = job, n = n, sub = r.sub ~= nil }
end

-- Repo rules win only when the repo changed them: a new or edited rule is applied, a removed one is deleted,
-- an untouched one keeps whatever was done to it here. Returns true if anything changed.
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

-- ---- monitor (drawn into an invisible window, flipped once per frame: no flicker) ----
-- Laid out to still work on a 3x2 monitor at text scale 1 (29x12 characters).
local win, W, H
local buttons = {}
local TABS = { "HOME", "STOCK" }
local tab, page = "HOME", 1
local sel, confirm -- STOCK: selected rule id, its delete button was tapped once

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
  if #rows == 0 then put(2, y, total > 0 and "all stocked" or "no rules: ADD on the computer", colours.lightGrey) y = y + 1 end

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
  if #ids == 0 then put(2, y0 + 1, "no rules: ADD on the computer", colours.lightGrey) end

  local e = sel and db.stock[sel]
  if not e then return put(2, H - 2, "tap a rule to edit it", colours.lightGrey) end
  local r = rtOf(sel)
  local st, col = state(e, r)
  local detail = (st == "MISSING" or st == "PREP") and r.missing and " " .. r.missing or "  keep " .. e.keep
  put(2, H - 2, (st .. detail):sub(1, W - 2), col)
  local y = H - 1
  local x = btn(1, y, e.off and " OFF" or " ON ", colours.black, e.off and colours.lightGrey or colours.lime,
    function() e.off = not e.off or nil save() end) + 1
  -- LOOP = blocking (cyclical recipe, sized from the stock), BULK = whole deficit in one job
  x = btn(x, y, e.blocking and " LOOP" or " BULK", colours.white, e.blocking and colours.purple or colours.grey,
    function() e.blocking = not e.blocking or nil save() end) + 1
  x = btn(x, y, " /2", colours.white, colours.grey, function() e.keep = math.floor(e.keep / 2) save() end) + 1
  x = btn(x, y, " x2", colours.white, colours.grey, function() e.keep = math.max(1, e.keep * 2) save() end) + 1
  -- two taps to delete: anyone walking past can reach the monitor
  btn(x, y, confirm and "DEL?" or " DEL", colours.white, confirm and colours.red or colours.grey, function(armed)
    if armed then db.stock[sel] = nil save() else confirm = true end
  end)
end

local VIEWS = { HOME = home, STOCK = stock }

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
    x = btn(x, 2, " " .. t .. " ", fg, bg, function() tab, page = t, 1 end)
  end
  VIEWS[tab](3)
  win.setVisible(true)
end

-- ---- computer screen ----
local pick = {}                       -- craftable items: { id, label, key (lowercase haystack) }
local query, found, cur, top = "", {}, 1, 0 -- ADD: search text, matches, highlighted one, rows scrolled
local asking                          -- picked item, now typing its keep: { id, label, text }
local note                            -- last thing that happened on ADD
local LIST_Y = 5                      -- first result row

local function tput(x, y, s, fg, bg)
  term.setCursorPos(x, y)
  term.setTextColour(fg or colours.white)
  term.setBackgroundColour(bg or colours.black)
  term.write(s)
end

function drawTerm()
  term.setBackgroundColour(colours.black)
  term.clear()
  term.setCursorBlink(false)
  tput(1, 1, (" "):rep(TW), nil, colours.grey)
  local fg, bg = tabCol(view == "LOG")
  tput(1, 1, " LOG ", fg, bg)
  fg, bg = tabCol(view == "ADD")
  tput(6, 1, " ADD ", fg, bg)
  tput(TW - 16, 1, "Tab switches tab", colours.lightGrey, colours.grey)
  if view == "LOG" then
    local first = math.max(0, #lines - (TH - 1))
    for i = 1, TH - 1 do
      if lines[first + i] then tput(1, i + 1, lines[first + i]) end
    end
    return
  end
  local prompt, text = "Search: ", query
  if asking then
    prompt, text = "Keep at least: ", asking.text
    tput(1, 4, (asking.label .. "  -  Enter saves, Tab cancels"):sub(1, TW), colours.lightGrey)
  else
    tput(1, 4, (#found .. " craftable. Click one, or arrows + Enter."):sub(1, TW), colours.lightGrey)
  end
  tput(1, 3, prompt, colours.yellow)
  tput(#prompt + 1, 3, text)
  for i = 1, TH - LIST_Y do
    local p = found[top + i]
    if not p then break end
    local rule = db.stock[p.id]
    local on = top + i == cur
    tput(1, LIST_Y + i - 1, ((on and "> " or "  ") .. p.label .. (" "):rep(TW)):sub(1, TW),
      rule and colours.lime or colours.white, on and colours.grey or colours.black)
    if rule then tput(TW - 11, LIST_Y + i - 1, (" keep " .. fmt(rule.keep) .. "      "):sub(1, 12), colours.lime, on and colours.grey or colours.black) end
  end
  if note then tput(1, TH, note:sub(1, TW), colours.lime) end
  term.setCursorPos(#prompt + #text + 1, 3)
  term.setTextColour(colours.white)
  term.setCursorBlink(true)
end

-- every word typed must appear somewhere in the name or the id: "unob temp" finds the template
local function search()
  found, cur, top = {}, 1, 0
  local words = {}
  for w in query:lower():gmatch("%S+") do words[#words + 1] = w end
  for _, p in ipairs(pick) do
    local ok = true
    for _, w in ipairs(words) do
      if not p.key:find(w, 1, true) then ok = false break end
    end
    if ok then found[#found + 1] = p end
  end
end
do
  pick, query = { { key = "unobtainium smithing template a:unob" }, { key = "glass minecraft:glass" } }, "unob TEMP"
  search()
  assert(#found == 1)
  pick, query, found = {}, "", {}
end

local function loadPick()
  pick = {}
  -- ponytail: dumps every pattern, but only when ADD is opened, never on a timer (full dumps every pass
  -- stalled the server on RS).
  local ok, list = pcall(bridge.getCraftableItems)
  local seen = {}
  for _, it in ipairs(ok and type(list) == "table" and list or {}) do
    if it.name and not seen[it.name] then -- one row per id, NBT variants collapse
      seen[it.name] = true
      local label = clean(it.displayName or it.name)
      pick[#pick + 1] = { id = it.name, label = label, key = (label .. " " .. it.name):lower() }
    end
  end
  table.sort(pick, function(a, b) return a.key < b.key end)
end

local function openView(v)
  view, asking, note = v, nil, nil
  if v == "ADD" then
    loadPick()
    search()
    if #pick == 0 then note = "no patterns found (bridge offline?)" end
  end
end

local function move(d)
  local rows = TH - LIST_Y
  cur = math.max(1, math.min(#found, cur + d))
  if cur <= top then top = cur - 1 end
  if cur > top + rows then top = cur - rows end
end

local function choose(p)
  if not p then return end
  asking, note = { id = p.id, label = p.label, text = tostring(db.stock[p.id] and db.stock[p.id].keep or 64) }, nil
end

local function saveKeep()
  local n = tonumber(asking.text)
  if not n or n < 1 then note = "type a number above 0" return end
  local e = db.stock[asking.id] or { label = asking.label }
  e.keep = math.floor(n)
  db.stock[asking.id] = e
  sel = asking.id -- so STOCK on the monitor has it ready to edit
  save()
  note = asking.label .. ": keep " .. e.keep
  asking, query = nil, ""
  search()
  os.queueEvent("butler_poke")
end

local function typed(s)
  if view ~= "ADD" then return end
  if asking then
    asking.text = asking.text .. s:gsub("%D", "")
  else
    query = query .. s
    search()
  end
end

local function pressed(k)
  if k == keys.tab then
    if asking then asking = nil else openView(view == "LOG" and "ADD" or "LOG") end
  elseif view ~= "ADD" then
    return
  elseif k == keys.backspace then
    if asking then asking.text = asking.text:sub(1, -2) else query = query:sub(1, -2) search() end
  elseif k == keys.enter or k == keys.numPadEnter then
    if asking then saveKeep() else choose(found[cur]) end
  elseif k == keys.up then move(-1)
  elseif k == keys.down then move(1)
  elseif k == keys.pageUp then move(LIST_Y - TH)
  elseif k == keys.pageDown then move(TH - LIST_Y)
  end
end

local function clicked(x, y)
  if y == 1 and x <= 10 then
    openView(x <= 5 and "LOG" or "ADD")
  elseif view == "ADD" and not asking and y >= LIST_Y and found[top + y - LIST_Y + 1] then
    cur = top + y - LIST_Y + 1
    choose(found[cur])
  end
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

-- AP reports on jobs we started: ae_crafting, isError, jobId, status. Only records; settle() decides.
local function jobLoop()
  while true do
    local _, _, jid, status = os.pullEvent("ae_crafting")
    local j = jobs[jid]
    if j then
      local st = SHOW[status] or tostring(status)
      j.entry.st = st
      if LIVE[st] then
        j.r.st = j.sub and "PREP" or st
      else
        jobs[jid], j.st = nil, st
        j.r.job, j.r.done = nil, j
        os.queueEvent("butler_poke") -- next step now, not at the next poll
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
    local ev, a, b, c = os.pullEvent()
    if ev == "monitor_touch" then
      local armed = confirm
      confirm = nil
      for _, hit in ipairs(buttons) do
        if c == hit[3] and b >= hit[1] and b <= hit[2] then hit[4](armed) break end
      end
      draw()
    elseif ev == "monitor_resize" then
      draw()
    elseif ev == "char" or ev == "paste" or ev == "key" or ev == "mouse_click" or ev == "mouse_scroll" or ev == "term_resize" then
      if ev == "key" then pressed(a)
      elseif ev == "mouse_click" then clicked(b, c)
      elseif ev == "mouse_scroll" then if view == "ADD" and not asking then move(a * 3) end
      elseif ev == "term_resize" then TW, TH = term.getSize()
      else typed(a) end
      drawTerm()
      draw() -- a rule may have been added
    end
  end
end

lines[1] = "butler running" .. (mon and "" or ", no monitor") .. ". Only changes show up here."
drawTerm()
draw()
local loops = { stockLoop, cpuLoop, jobLoop, uiLoop }
if SYNC > 0 then loops[#loops + 1] = syncLoop end
local ok, err = pcall(parallel.waitForAny, table.unpack(loops))
-- leave a clean prompt behind on Ctrl+T or a crash
term.setBackgroundColour(colours.black)
term.setTextColour(colours.white)
term.setCursorBlink(false)
term.clear()
term.setCursorPos(1, 1)
if not ok then error(err, 0) end
