-- Circuit slicer feeder: spreads whatever the pattern providers put in the buffer barrel over every ExtendedAE
-- circuit slicer on the wired network, then fills them to Cap, and sends the prints to the pattern provider.
-- Slot 1 is the slicer's input, everything else is output. Empty slicers are split over the items in the
-- barrel by stock; each item is water-filled lowest first, so every slicer gets work before any saturates.
-- Replaces the SFM "barrel -> circuit slicers -> pattern provider" program (pull that disk).
-- @desc Circuit slicers: load-balances the buffer barrel over every slicer, then fills to Cap; prints -> provider
-- @deps cn_lib
-- @config Barrel|Buffer barrel peripheral name (auto = the only barrel on the network)|auto
-- @config Provider|Pattern provider that takes the prints (auto = the only one on the network)|auto
-- @config Kind|Peripheral type of the slicers (matched as part of the name)|circuit_cutter
-- @config Cap|Most items per slicer, reached only once every slicer has its share|32
local cfg = dofile("/lib/cn.lua")
local CAP = tonumber(cfg.Cap) or 32
local KIND = cfg.Kind or "circuit_cutter"
local BATCH = 64 -- peripheral calls in flight at once: CC drops events past 256 queued, stay well under

local function names(kind)
  local out = {}
  for _, n in ipairs(peripheral.getNames()) do
    if (peripheral.getType(n) or ""):find(kind, 1, true) then out[#out + 1] = n end
  end
  table.sort(out)
  return out
end

local function one(kind, name)
  if name and name ~= "auto" then
    return peripheral.isPresent(name) and name or error(name .. " is not on the network", 0)
  end
  local found = names(kind)
  if #found ~= 1 then error(("need exactly one %s on the network, found %d: set it with cookienet config"):format(kind, #found), 0) end
  return found[1]
end

local barrel = one("barrel", cfg.Barrel)
local provider = one("pattern_provider", cfg.Provider)

local function run(jobs)
  for i = 1, #jobs, BATCH do parallel.waitForAll(table.unpack(jobs, i, math.min(i + BATCH - 1, #jobs))) end
end

-- lowest first to the highest common level `avail` can reach (at most CAP), remainder +1 to some at that level
local function waterfill(hs, avail)
  local function need(l)
    local n = 0
    for _, h in ipairs(hs) do if h < l then n = n + l - h end end
    return n
  end
  local lo = 0
  while lo < CAP and need(lo + 1) <= avail do lo = lo + 1 end
  local spare, t = avail - need(lo), {}
  for i, h in ipairs(hs) do
    t[i] = math.max(h, lo)
    if lo < CAP and t[i] == lo and spare > 0 then t[i], spare = lo + 1, spare - 1 end
  end
  return t
end

local OUT = 2 -- slicer output slot
local machines = names(KIND) -- refreshed by the feed loop, read by the pull loop
local pulled, fed, rounds = 0, 0, 0

-- Its own loop, not a step of the feed round: a long feed (hundreds of pushes while the barrel is full)
-- meant outputs got pulled once a round, slicers stalled on full outputs, and only caught up once the
-- barrel ran dry. The provider has only a few return slots that AE empties on its own tick, so each pass
-- pulls from as many slicers as it has free slots (more failed silently), rotating through all of them.
local function pullLoop()
  local nxt = 1
  while true do
    local plist, psize = {}, 9
    run({
      function() local ok, l = pcall(peripheral.call, provider, "list") plist = ok and l or {} end,
      function() local ok, n = pcall(peripheral.call, provider, "size") psize = ok and n or 9 end,
    })
    local free, n, jobs = psize, #machines, {}
    for _ in pairs(plist) do free = free - 1 end
    for k = 1, math.min(math.max(free, 0), n) do
      local m = machines[(nxt + k - 2) % n + 1]
      jobs[k] = function()
        local ok, got = pcall(peripheral.call, provider, "pullItems", m, OUT)
        if ok and got then pulled = pulled + got end
      end
    end
    if n > 0 then nxt = (nxt + #jobs - 1) % n + 1 end
    run(jobs)
    sleep(0)
  end
end

local function feedLoop()
  while true do
    machines = names(KIND)
    if #machines == 0 then error("no " .. KIND .. " on the network: set Kind with cookienet config", 0) end
    local inv, blist = {}, {}
    local jobs = { function() local ok, l = pcall(peripheral.call, barrel, "list") blist = ok and l or {} end }
    for i, m in ipairs(machines) do
      jobs[#jobs + 1] = function() local ok, l = pcall(peripheral.call, m, "list") inv[i] = ok and l or {} end
    end
    run(jobs)

    local stock = {} -- item -> { n = total, slots = { {slot, count}, ... } }
    for slot, it in pairs(blist) do
      local s = stock[it.name] or { n = 0, slots = {} }
      s.n, s.slots[#s.slots + 1] = s.n + it.count, { slot, it.count }
      stock[it.name] = s
    end

    -- who slices what: busy slicers keep their item, empty ones go to the item with the most stock per slicer
    local item, h, count = {}, {}, {}
    for i in ipairs(machines) do
      local s = inv[i][1]
      if s then item[i], h[i], count[s.name] = s.name, s.count, (count[s.name] or 0) + 1 end
    end
    for i in ipairs(machines) do
      if not item[i] then
        local best, most = nil, 0
        for name, s in pairs(stock) do
          local per = s.n / ((count[name] or 0) + 1)
          if per > most or (per == most and best and name < best) then best, most = name, per end
        end
        if best then item[i], h[i], count[best] = best, 0, (count[best] or 0) + 1 end
      end
    end

    local moves, n_fed = {}, 0
    for name, s in pairs(stock) do
      local idx, hs = {}, {}
      for i in ipairs(machines) do
        if item[i] == name then idx[#idx + 1], hs[#hs + 1] = i, h[i] end
      end
      for k, target in ipairs(waterfill(hs, s.n)) do
        local n = target - hs[k]
        if n > 0 then n_fed = n_fed + 1 end
        for _, sl in ipairs(s.slots) do
          if n <= 0 then break end
          local take = math.min(n, sl[2])
          if take > 0 then
            moves[#moves + 1] = { machines[idx[k]], sl[1], take }
            sl[2], n = sl[2] - take, n - take
          end
        end
      end
    end

    jobs = {}
    for _, m in ipairs(moves) do
      jobs[#jobs + 1] = function() pcall(peripheral.call, barrel, "pushItems", m[1], m[2], m[3], 1) end
    end
    run(jobs)
    fed, rounds = n_fed, rounds + 1
    term.clear()
    term.setCursorPos(1, 1)
    print(("circuit slicers: %d"):format(#machines))
    print(("feed round %d: fed %d slicers"):format(rounds, fed))
    print(("pulled %d prints so far"):format(pulled))
    sleep(0)
  end
end

parallel.waitForAny(pullLoop, feedLoop)
