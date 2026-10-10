-- ME Bridge + advanced monitor (next to the computer or on its wired network): live ME network dashboard.
-- @desc Live ME dashboard on a monitor: storage, energy, cells, crafting CPUs, top items/fluids
-- @deps cn_lib
-- @config TextScale|Monitor text scale (0.5 = most data)|0.5
-- @config Poll|Seconds between refreshes|2
-- @config ScanEvery|Seconds between full item/fluid/cell scans (0 = off)|30
local cfg = dofile("/lib/cn.lua")
local SCALE = tonumber(cfg.TextScale) or 0.5
local POLL = tonumber(cfg.Poll) or 2
-- ponytail: getItems dumps the whole network (every pass of that crashed the server on RS).
-- Kept on a slow timer; raise ScanEvery or set 0 if the server stalls on a huge network.
local SCAN_EVERY = tonumber(cfg.ScanEvery) or 30

local bridge = peripheral.find("me_bridge") or error("no me_bridge", 0)
local mon = peripheral.find("monitor") or error("no monitor", 0)
mon.setTextScale(SCALE)

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
local function put(x, y, s, fg, bg)
  if y < 1 or y > H then return end
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
  if not scan.getCells then return y end
  local kinds, order, full, used, max = {}, {}, 0, 0, 0
  for _, c in ipairs(scan.getCells) do
    local k = tostring(c.type or "?"):gsub("^.*:", "")
    k = ({ i = "item", f = "fluid" })[k] or k
    if not kinds[k] then kinds[k] = 0; order[#order + 1] = k end
    kinds[k] = kinds[k] + 1
    used, max = used + (c.usedBytes or 0), max + (c.maxBytes or 0)
    if (c.maxBytes or 0) > 0 and (c.usedBytes or 0) >= c.maxBytes * 0.99 then full = full + 1 end
  end
  y = header(x, y, w, "DRIVES & CELLS", #(scan.getDrives or {}) .. " drives  " .. #scan.getCells .. " cells")
  local parts = {}
  for _, k in ipairs(order) do parts[#parts + 1] = kinds[k] .. " " .. k end
  put(x, y, table.concat(parts, "  "))
  rput(x, y, w, full .. " full", full > 0 and colours.orange or colours.lightGrey)
  return y + 2
end

local function cpus(x, y, w)
  local list, busy = s.getCraftingCPUs or {}, 0
  for _, c in ipairs(list) do if c.isBusy then busy = busy + 1 end end
  y = header(x, y, w, "CRAFTING CPUS", busy .. " / " .. #list .. " busy")
  table.sort(list, function(a, b) return (a.isBusy and 1 or 0) > (b.isBusy and 1 or 0) end)
  for _, c in ipairs(list) do
    if y > H then break end
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

local function draw()
  W, H = mon.getSize()
  win = window.create(mon, 1, 1, W, H, false)
  win.setBackgroundColour(colours.black)
  win.clear()

  local online = s.isOnline
  put(1, 1, (" "):rep(W), nil, online and colours.blue or colours.red)
  put(2, 1, "ME NETWORK  " .. (online and "\7 ONLINE" or "\7 OFFLINE"), colours.white, online and colours.blue or colours.red)
  rput(1, 1, W - 1, os.date("%H:%M:%S"), colours.white, online and colours.blue or colours.red)

  local two = W >= 70 -- two columns when there is room, else one long stack
  local lw = two and math.floor(W / 2) - 1 or W
  local y = 3
  y = storage(1, y, lw)
  y = energy(1, y, lw)
  y = cells(1, y, lw)
  y = cpus(1, y, lw)

  local lists = {}
  for _, l in ipairs({ { "TOP ITEMS", scan.items, "" }, { "TOP FLUIDS", scan.fluids, " B" }, { "TOP CHEMICALS", scan.chemicals, " B" } }) do
    if l[2] and #l[2].rows > 0 then lists[#lists + 1] = l end
  end
  local x, w = 1, lw
  if two then x, y, w = lw + 3, 3, W - lw - 2 end
  -- fluids/chemicals take what they need (max a quarter of the space each), items get the rest;
  -- 2 lines per list go to header + gap
  local left, rows = H - y + 1, {}
  for i = #lists, 1, -1 do
    rows[i] = i == 1 and left - 2 or math.min(#lists[i][2].rows, math.floor((H - y + 1) / 4) - 2)
    left = left - rows[i] - 2
  end
  for i, l in ipairs(lists) do y = ranked(x, y, w, rows[i], l[1], l[2], l[3]) end
  if #lists == 0 and two then put(x, y, SCAN_EVERY > 0 and "scanning..." or "item scan off (ScanEvery=0)", colours.grey) end

  win.setVisible(true)
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
  return { rows = rows, total = total, types = #rows }
end

print("ME monitor running (" .. peripheral.getName(mon) .. ")")
local nextScan = 0
while true do
  local ok, err = pcall(function()
    s = poll(FAST)
    usage[#usage + 1] = s.getEnergyUsage or 0
    if #usage > 200 then table.remove(usage, 1) end
    if SCAN_EVERY > 0 and os.clock() >= nextScan then
      scan = poll(SLOW)
      scan.items = rank("items", scan.getItems, 1)
      scan.fluids = rank("fluids", scan.getFluids, 1000)       -- mB -> buckets
      scan.chemicals = rank("chemicals", scan.getChemicals, 1000)
      scan.getItems, scan.getFluids, scan.getChemicals = nil, nil, nil -- drop the raw dumps
      nextScan = os.clock() + SCAN_EVERY
    end
    draw()
  end)
  if not ok then
    if err == "Terminated" then error(err, 0) end
    print("error: " .. tostring(err)) -- bridge hiccups / monitor resize shouldn't kill the display
  end
  sleep(POLL)
end
