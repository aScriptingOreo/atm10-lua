-- Live ME network display on advanced monitor(s). Run the same program on every computer with a screen:
-- the one with an ME Bridge is the main (polls + broadcasts over rednet), the others just draw what it sends.
-- View auto: a short strip shows fill gauges, a big monitor the full dashboard.
-- Dashboard longer than the monitor: right-click the monitor for the next page.
-- @desc Live ME dashboard on a monitor: storage, energy, cells, crafting CPUs, top items/fluids
-- @deps cn_lib
-- @config TextScale|Monitor text scale (0.5 = most data)|0.5
-- @config Poll|Seconds between refreshes|2
-- @config ScanEvery|Seconds between full item/fluid/cell scans (0 = off)|30
-- @config View|What this computer's monitor shows (auto/dashboard/gauges)|auto
local cfg = dofile("/lib/cn.lua")
local SCALE = tonumber(cfg.TextScale) or 0.5
local POLL = tonumber(cfg.Poll) or 2
-- ponytail: getItems dumps the whole network (every pass of that crashed the server on RS).
-- Kept on a slow timer; raise ScanEvery or set 0 if the server stalls on a huge network.
local SCAN_EVERY = tonumber(cfg.ScanEvery) or 30

local VIEW = cfg.View or "auto"
-- ponytail: one fixed protocol; add a name to it (like reactor:<name>) if two ME setups share modem range
local PROTO = "me_monitor"

local bridge = peripheral.find("me_bridge")
local modem = peripheral.find("modem")
if modem then rednet.open(peripheral.getName(modem)) end
if not (bridge or modem) then error("need an me_bridge (main) or a modem (remote display)", 0) end
local mons = { peripheral.find("monitor") }
if #mons == 0 then error("no monitor", 0) end
for _, m in ipairs(mons) do m.setTextScale(SCALE) end
local function area(m) local w, h = m.getSize() return w * h end
table.sort(mons, function(a, b) return area(a) > area(b) end)

-- cheap numbers, every POLL
local FAST = { "isOnline", "getStoredEnergy", "getEnergyCapacity", "getEnergyUsage", "getAverageEnergyInput", "getCraftingCPUs" }
for _, k in ipairs({ "Item", "Fluid", "Chemical" }) do
  for _, m in ipairs({ "getUsed%sStorage", "getMax%sStorage", "getUsedExternal%sStorage", "getMaxExternal%sStorage" }) do
    FAST[#FAST + 1] = m:format(k)
  end
end
FAST[#FAST + 1] = "getUsedExternalItemCount"
FAST[#FAST + 1] = "getMaxExternalItemCount"
-- full dumps, every SCAN_EVERY
local SLOW = { "getItems", "getFluids", "getChemicals", "getCells", "getDrives" }

-- all calls queued at once so they share a tick instead of one tick each (same trick as RS_Trash).
-- Missing methods (no Applied Mekanistics) and offline errors just leave the key nil.
local function poll(names)
  local out, jobs = {}, {}
  for i, n in ipairs(names) do
    jobs[i] = function()
      local ok, v = pcall(bridge[n])
      if ok then out[n] = v end
    end
  end
  parallel.waitForAll(table.unpack(jobs))
  return out
end

local function fmt(n)
  if not n then return "?" end
  local u, i = { "", "K", "M", "G", "T", "P" }, 1
  while math.abs(n) >= 1000 and i < #u do n, i = n / 1000, i + 1 end
  return (i == 1 and "%.0f" or "%.2f"):format(n) .. u[i]
end
assert(fmt(999) == "999" and fmt(1500) == "1.50K" and fmt(2.5e9) == "2.50G")

local function dur(sec)
  sec = math.floor(sec)
  if sec >= 3600 then return ("%dh%02dm"):format(math.floor(sec / 3600), math.floor(sec % 3600 / 60)) end
  return ("%dm%02ds"):format(math.floor(sec / 60), sec % 60)
end

-- ---- drawing (into an invisible window, flipped once per frame: no flicker) ----
local win, W, H
local top, oy = 1, 0       -- first drawable row, scroll offset (dashboard paging)
local page, pages = 0, 1
local function put(x, y, s, fg, bg)
  y = y - oy
  if y < top or y > H then return end
  win.setCursorPos(x, y)
  win.setTextColour(fg or colours.white)
  win.setBackgroundColour(bg or colours.black)
  win.write(s)
end
local function rput(x, y, w, s, fg, bg) put(x + w - #s, y, s, fg, bg) end
local function header(x, y, w, title, right)
  put(x, y, (" " .. title .. (" "):rep(w)):sub(1, w), colours.black, colours.lightBlue)
  if right then rput(x, y, w - 1, right, colours.black, colours.lightBlue) end
  return y + 1
end
local function bar(x, y, w, frac, col)
  local n = math.floor(w * math.max(0, math.min(1, frac)) + 0.5)
  put(x, y, (" "):rep(n), nil, col)
  put(x + n, y, (" "):rep(w - n), nil, colours.grey)
end
local function fullness(frac) return frac >= 0.9 and colours.red or frac >= 0.7 and colours.orange or colours.lime end

local s, scan = {}, {} -- latest FAST / SLOW results
local usage = {}       -- energy usage history, one sample per poll

local function storage(x, y, w)
  y = header(x, y, w, "STORAGE")
  local rows = {
    { "Items", s.getUsedItemStorage, s.getMaxItemStorage, " B" },
    { "Fluids", s.getUsedFluidStorage, s.getMaxFluidStorage, " B" },
    { "Chemicals", s.getUsedChemicalStorage, s.getMaxChemicalStorage, " B" },
    { "Ext. items", s.getUsedExternalItemCount, s.getMaxExternalItemCount, "" },
    { "Ext. fluids", s.getUsedExternalFluidStorage, s.getMaxExternalFluidStorage, " mB" },
    { "Ext. chem", s.getUsedExternalChemicalStorage, s.getMaxExternalChemicalStorage, " mB" },
  }
  for _, r in ipairs(rows) do
    local used, max = r[2], r[3]
    if used and max and max > 0 then
      local f = used / max
      put(x, y, r[1])
      rput(x, y, w, ("%s / %s%s  %s free  %5.1f%%"):format(fmt(used), fmt(max), r[4], fmt(max - used), f * 100), fullness(f))
      bar(x, y + 1, w, f, fullness(f))
      y = y + 3
    end
  end
  return y
end

local function energy(x, y, w)
  local have, cap, use, inp = s.getStoredEnergy, s.getEnergyCapacity, s.getEnergyUsage or 0, s.getAverageEnergyInput or 0
  y = header(x, y, w, "ENERGY", fmt(use) .. " AE/t")
  if have and cap and cap > 0 then
    local f = have / cap
    local col = f <= 0.1 and colours.red or f <= 0.3 and colours.orange or colours.yellow
    put(x, y, "Stored")
    rput(x, y, w, ("%s / %s AE  %5.1f%%"):format(fmt(have), fmt(cap), f * 100), col)
    bar(x, y + 1, w, f, col)
    y = y + 2
    local net = inp - use
    local io = ("In %s  Out %s  Net "):format(fmt(inp), fmt(use))
    put(x, y, io, colours.lightGrey)
    put(x + #io, y, (net >= 0 and "+" or "") .. fmt(net) .. " AE/t", net >= 0 and colours.lime or colours.red)
    -- AE/t * 20 ticks = per second
    if net < 0 then rput(x, y, w, "empty in " .. dur(have / (-net * 20)), colours.red) end
    y = y + 2
  end
  -- usage history: one column per poll, newest on the right
  local gh, max = 4, 1
  for i = math.max(1, #usage - w + 1), #usage do max = math.max(max, usage[i]) end
  put(x, y, "Usage history, peak " .. fmt(max) .. " AE/t", colours.lightGrey)
  y = y + 1
  for c = 0, w - 1 do
    local v = usage[#usage - w + 1 + c]
    local fill = v and math.max(v > 0 and 1 or 0, math.floor(v / max * gh + 0.5)) or 0
    for r = 0, gh - 1 do put(x + c, y + gh - 1 - r, " ", nil, r < fill and colours.yellow or colours.black) end
  end
  return y + gh + 1
end

local function cells(x, y, w)
  local c = scan.cells
  if not c then return y end
  y = header(x, y, w, "DRIVES & CELLS", c.drives .. " drives  " .. c.count .. " cells")
  put(x, y, c.kinds)
  rput(x, y, w, c.full .. " full", c.full > 0 and colours.orange or colours.lightGrey)
  return y + 2
end

local function cpus(x, y, w)
  local list, busy = s.getCraftingCPUs or {}, 0
  for _, c in ipairs(list) do if c.isBusy then busy = busy + 1 end end
  y = header(x, y, w, "CRAFTING CPUS", busy .. " / " .. #list .. " busy")
  table.sort(list, function(a, b) return (a.isBusy and 1 or 0) > (b.isBusy and 1 or 0) end)
  for _, c in ipairs(list) do
    local label = ("%s %s+%s"):format(c.name or "CPU", fmt(c.storage), tostring(c.coProcessors or 0))
    put(x, y, "\7 " .. label, c.isBusy and colours.lime or colours.grey)
    local job = c.isBusy and type(c.craftingJob) == "table" and c.craftingJob
    if job then
      local res = type(job.resource) == "table" and job.resource or {}
      local what = tostring(res.displayName or res.name or "?"):gsub("^%[(.*)%]$", "%1")
      local pct = ("%3d%%"):format(math.floor((job.completion or 0) * 100)) -- completion is 0..1
      local room = w - #label - 4 - #pct - 1
      local txt = (what .. " x" .. fmt(job.quantity)):sub(1, math.max(0, room))
      put(x + #label + 3, y, txt, colours.white)
      rput(x, y, w, pct, colours.yellow)
    elseif not c.isBusy then
      rput(x, y, w, "idle", colours.grey)
    end
    y = y + 1
  end
  return y + 1
end

-- one ranked list; returns next free y
local function ranked(x, y, w, rows, title, data, unit)
  y = header(x, y, w, title, data.types .. " types  " .. fmt(data.total) .. unit)
  for i = 1, math.min(#data.rows, rows) do
    local r = data.rows[i]
    put(x, y, ("%2d "):format(i), colours.grey)
    put(x + 3, y, r.name:sub(1, w - 3 - 20))
    rput(x, y, w - 9, fmt(r.count) .. unit, colours.cyan)
    if r.delta ~= 0 then
      rput(x, y, w, (r.delta > 0 and "+" or "-") .. fmt(math.abs(r.delta)), r.delta > 0 and colours.lime or colours.red)
    end
    y = y + 1
  end
  return y + 1
end

-- one fat gauge per resource: stacked left-to-right bars on a tall monitor,
-- side-by-side columns filling bottom-to-top on a short one
local function gauges()
  local g = {}
  local function add(label, used, max, unit, col)
    if used and max and max > 0 then
      local f = used / max
      g[#g + 1] = { label, f, col and col(f) or fullness(f), fmt(used) .. " / " .. fmt(max) .. unit, fmt(max - used) .. " free", fmt(max - used) }
    end
  end
  add("ITEMS", s.getUsedItemStorage, s.getMaxItemStorage, " B")
  add("FLUIDS", s.getUsedFluidStorage, s.getMaxFluidStorage, " B")
  add("CHEM", s.getUsedChemicalStorage, s.getMaxChemicalStorage, " B")
  add("EXT", s.getUsedExternalItemCount, s.getMaxExternalItemCount, "")
  add("ENERGY", s.getStoredEnergy, s.getEnergyCapacity, " AE", function(f)
    return f <= 0.1 and colours.red or f <= 0.3 and colours.orange or colours.yellow
  end)
  local busy = 0
  for _, c in ipairs(s.getCraftingCPUs or {}) do if c.isBusy then busy = busy + 1 end end
  add("CPUS", busy, #(s.getCraftingCPUs or {}), "", function() return colours.cyan end)
  if #g == 0 then return put(1, 1, s.noSignal and "NO SIGNAL" or s.isOnline and "no data" or "ME OFFLINE", colours.red) end

  local stacked = H >= #g * 4
  local cw, ch = stacked and W or math.floor(W / #g), stacked and math.floor(H / #g) or H
  local w = stacked and cw or cw - 1 -- 1 column gap between side-by-side gauges
  -- same detail lines on every gauge so the bars line up; narrow columns fall back to "free:" + number
  local function fits(k) for _, v in ipairs(g) do if #v[k] > w then return false end end return true end
  local detail = fits(5) and { fits(4) and 4 or nil, 5 } or { "free:", 6 }
  for i, v in ipairs(g) do
    local x, y = stacked and 1 or (i - 1) * cw + 1, stacked and (i - 1) * ch + 1 or 1
    local last = stacked and y + ch - 2 or H -- last bar row
    local pct = ("%.1f%%"):format(v[2] * 100)
    put(x, y, v[1]:sub(1, w))
    if #v[1] + 1 + #pct > w then y = y + 1 end -- narrow column: percentage on its own line
    rput(x, y, w, pct, v[3])
    y = y + 1
    for _, d in pairs(detail) do -- pairs: the list may have a hole at 1
      if last - y >= 3 then put(x, y, v[d] or d, colours.lightGrey); y = y + 1 end
    end
    if stacked then
      for r = y, last do bar(x, r, w, v[2], v[3]) end
    else
      local rows = last - y + 1
      local n = math.floor(rows * math.min(1, v[2]) + 0.5)
      for r = 0, rows - 1 do put(x, last - r, (" "):rep(w), nil, r < n and v[3] or colours.grey) end
    end
  end
end

local function frame(m, fn)
  W, H = m.getSize()
  win = window.create(m, 1, 1, W, H, false)
  win.setBackgroundColour(colours.black)
  win.clear()
  top, oy = 1, 0
  fn()
  win.setVisible(true)
end

local function draw()
  -- content first (rows 3..H, scrolled by whole pages), title bar last so it knows the page count
  if page >= pages then page = 0 end
  top, oy = 3, page * (H - 2)

  local two = W >= 70 -- two columns when there is room, else one long stack
  local lw = two and math.floor(W / 2) - 1 or W
  local y = 3
  y = storage(1, y, lw)
  y = energy(1, y, lw)
  y = cells(1, y, lw)
  y = cpus(1, y, lw)
  local bottom = y

  local lists = {}
  for _, l in ipairs({ { "TOP ITEMS", scan.items, "" }, { "TOP FLUIDS", scan.fluids, " B" }, { "TOP CHEMICALS", scan.chemicals, " B" } }) do
    if l[2] and #l[2].rows > 0 then lists[#lists + 1] = l end
  end
  local x, w = 1, lw
  if two then x, y, w = lw + 3, 3, W - lw - 2 end
  -- the lists share one page of rows: fluids/chemicals take what they need (max a quarter each),
  -- items get the rest; 2 lines per list go to header + gap
  local left, rows = H - 2, {}
  for i = #lists, 1, -1 do
    rows[i] = i == 1 and left - 2 or math.min(#lists[i][2].rows, math.floor((H - 2) / 4) - 2)
    left = left - rows[i] - 2
  end
  for i, l in ipairs(lists) do y = ranked(x, y, w, rows[i], l[1], l[2], l[3]) end
  if #lists == 0 and two then put(x, y, SCAN_EVERY > 0 and "scanning..." or "item scan off (ScanEvery=0)", colours.grey) end
  pages = math.max(1, math.ceil((math.max(bottom, y) - 4) / (H - 2)))

  top, oy = 1, 0
  local online = s.isOnline
  local bg = online and colours.blue or colours.red
  put(1, 1, (" "):rep(W), nil, bg)
  put(2, 1, "ME NETWORK  \7 " .. (s.noSignal and "NO SIGNAL" or online and "ONLINE" or "OFFLINE"), colours.white, bg)
  rput(1, 1, W - 1, (pages > 1 and ("tap: page %d/%d   "):format(page + 1, pages) or "") .. os.date("%H:%M:%S"), colours.white, bg)
end

-- sum NBT variants per id, sort by amount, diff against the previous scan
local prev = {}
local function rank(kind, list, div)
  if not list then return nil end
  local by, rows, total = {}, {}, 0
  for _, it in ipairs(list) do
    local r = by[it.name]
    if not r then
      r = { id = it.name, name = (tostring(it.displayName or it.name):gsub("^%[(.*)%]$", "%1")), count = 0 }
      by[it.name], rows[#rows + 1] = r, r
    end
    r.count = r.count + (it.count or 0) / div
    total = total + (it.count or 0) / div
  end
  table.sort(rows, function(a, b) return a.count > b.count end)
  local now, p = {}, prev[kind]
  for _, r in ipairs(rows) do
    r.delta = p and r.count - (p[r.id] or 0) or 0
    now[r.id] = r.count
  end
  prev[kind] = now
  local types = #rows
  for i = types, 101, -1 do rows[i] = nil end -- no monitor shows more; keeps the rednet message small
  return { rows = rows, total = total, types = types }
end

local function cellSummary(list, drives)
  if not list then return nil end
  local kinds, order, full = {}, {}, 0
  for _, c in ipairs(list) do
    local k = tostring(c.type or "?"):gsub("^.*:", "")
    k = ({ i = "item", f = "fluid" })[k] or k
    if not kinds[k] then kinds[k] = 0; order[#order + 1] = k end
    kinds[k] = kinds[k] + 1
    if (c.maxBytes or 0) > 0 and (c.usedBytes or 0) >= c.maxBytes * 0.99 then full = full + 1 end
  end
  for i, k in ipairs(order) do order[i] = kinds[k] .. " " .. k end
  return { drives = #(drives or {}), count = #list, full = full, kinds = table.concat(order, "  ") }
end

local nextScan = 0
local function update()
  if not bridge then
    local _, msg = rednet.receive(PROTO, 10)
    if type(msg) == "table" then s, scan = msg.s or {}, msg.scan or {} else s, scan = { noSignal = true }, {} end
    return
  end
  s = poll(FAST)
  -- keep only what gets drawn: job tables nest the whole CPU and the item's components
  for _, c in ipairs(s.getCraftingCPUs or {}) do
    local job = type(c.craftingJob) == "table" and c.craftingJob
    if job then
      local res = type(job.resource) == "table" and job.resource or {}
      c.craftingJob = { quantity = job.quantity, completion = job.completion, resource = { displayName = res.displayName or res.name } }
    end
  end
  if SCAN_EVERY > 0 and os.clock() >= nextScan then
    local raw = poll(SLOW)
    scan = {
      items = rank("items", raw.getItems, 1),
      fluids = rank("fluids", raw.getFluids, 1000), -- mB -> buckets
      chemicals = rank("chemicals", raw.getChemicals, 1000),
      cells = cellSummary(raw.getCells, raw.getDrives),
    }
    nextScan = os.clock() + SCAN_EVERY
  end
  if modem then rednet.broadcast({ s = s, scan = scan }, PROTO) end
end

local function render()
  for i, m in ipairs(mons) do
    local _, h = m.getSize()
    local v = VIEW
    -- auto: biggest monitor is the dashboard unless it is this computer's only one and just a strip
    if v == "auto" then v = (i == 1 and (#mons > 1 or h >= 20)) and "dashboard" or "gauges" end
    frame(m, v == "gauges" and gauges or draw)
  end
end

print(bridge and "main: polling ME bridge" or "remote display: waiting for main on rednet")
local function loop()
  while true do
    local ok, err = pcall(function()
      update()
      usage[#usage + 1] = s.getEnergyUsage or 0
      if #usage > 200 then table.remove(usage, 1) end
      render()
    end)
    if not ok then
      if err == "Terminated" then error(err, 0) end
      print("error: " .. tostring(err)) -- bridge hiccups / monitor resize shouldn't kill the display
    end
    sleep(bridge and POLL or 0) -- remote display is paced by rednet.receive
  end
end
-- right-click any monitor: next dashboard page, redrawn right away
local function touch()
  while true do
    os.pullEvent("monitor_touch")
    page = (page + 1) % pages
    pcall(render)
  end
end
parallel.waitForAny(loop, touch)
