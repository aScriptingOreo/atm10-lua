-- Crystal assembler feeder: keeps every ExtendedAE crystal assembler on the wired network topped up to Cap
-- sets of one processor recipe (print + printed silicon + redstone/fluix dust, 1:1:1) from the buffer barrel
-- the pattern providers fill, and sends finished processors to the pattern provider.
-- Each assembler is filled to its own level from its own contents, so the ratio holds per machine, and
-- different assemblers can run different recipes at once. Replaces sfm/CrystalAssembler.sfml (pull that disk).
-- Network: wired modems (right-click, red) on the barrel, the pattern provider and every assembler.
-- @desc Crystal assemblers: tops each one up to Cap whole sets from the buffer barrel, processors -> provider
-- @deps cn_lib
-- @config Barrel|Buffer barrel peripheral name (auto = the only barrel on the network)|auto
-- @config Provider|Pattern provider that takes the processors (auto = the only one on the network)|auto
-- @config Cap|Sets kept in each assembler (it crafts 4 at a time: 8 = one running + one queued)|8
local cfg = dofile("/lib/cn.lua")
local CAP = tonumber(cfg.Cap) or 8
local BATCH = 64 -- peripheral calls in flight at once: CC drops events past 256 queued, stay well under

local SILICON = "ae2:printed_silicon"
local RECIPES = { -- print -> third ingredient; each craft takes one of each with one printed silicon
  ["ae2:printed_logic_processor"] = "minecraft:redstone",
  ["ae2:printed_calculation_processor"] = "minecraft:redstone",
  ["ae2:printed_engineering_processor"] = "minecraft:redstone",
  ["extendedae:concurrent_processor_print"] = "minecraft:redstone",
  ["appflux:printed_energy_processor"] = "minecraft:redstone",
  ["advanced_ae:printed_quantum_processor"] = "minecraft:redstone",
  ["megacells:printed_accumulation_processor"] = "ae2:fluix_dust",
}
local PRODUCTS = {
  ["ae2:logic_processor"] = true, ["ae2:calculation_processor"] = true, ["ae2:engineering_processor"] = true,
  ["extendedae:concurrent_processor"] = true, ["appflux:energy_processor"] = true,
  ["advanced_ae:quantum_processor"] = true, ["megacells:accumulation_processor"] = true,
}

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

-- barrel.list() -> item -> { n = total, slots = { {slot, count}, ... } }
local function index(list)
  local stock = {}
  for slot, it in pairs(list or {}) do
    local s = stock[it.name] or { n = 0, slots = {} }
    s.n = s.n + it.count
    s.slots[#s.slots + 1] = { slot, it.count }
    stock[it.name] = s
  end
  return stock
end

local function avail(stock, item) return stock[item] and stock[item].n or 0 end

-- reserve n of item from the barrel for assembler a, as one move per barrel slot it comes from
local function take(stock, item, n, a, moves)
  local s = stock[item]
  for _, sl in ipairs(s and s.slots or {}) do
    if n <= 0 then break end
    local k = math.min(n, sl[2])
    if k > 0 then
      moves[#moves + 1] = { a, sl[1], k }
      sl[2], s.n, n = sl[2] - k, s.n - k, n - k
    end
  end
end

-- the print already in the assembler: nil = none, false = more than one kind (mixed, can't fix from here)
local function active(have)
  local p
  for item in pairs(have) do
    if RECIPES[item] then
      if p then return false end
      p = item
    end
  end
  return p
end

-- for an empty assembler: the recipe with the most whole sets in the barrel
local function pick(stock)
  local best, most = nil, 0
  for p, x in pairs(RECIPES) do
    local sets = math.min(avail(stock, p), avail(stock, SILICON), avail(stock, x))
    if sets > most or (sets == most and best and p < best) then best, most = p, sets end
  end
  return best
end

-- Every ingredient goes to the same level (at most CAP), the highest the barrel can cover for all three.
-- The print never ends up ahead of its partners, so nothing is ever stranded; spare silicon or redstone
-- already in the machine just means less is sent.
local function plan(a, p, have, stock, moves)
  local items = { p, SILICON, RECIPES[p] }
  local level = CAP
  for _, it in ipairs(items) do level = math.min(level, (have[it] or 0) + avail(stock, it)) end
  for _, it in ipairs(items) do take(stock, it, level - (have[it] or 0), a, moves) end
end

local function round()
  local asms = names("crystal_assembler")
  local inv, stock = {}, {}
  local jobs = { function() stock = index(select(2, pcall(peripheral.call, barrel, "list"))) end }
  for i, a in ipairs(asms) do
    jobs[#jobs + 1] = function()
      local ok, l = pcall(peripheral.call, a, "list")
      inv[i] = ok and l or nil
    end
  end
  run(jobs)

  local moves, pulls, mixed, fed = {}, {}, 0, 0
  for i, a in ipairs(asms) do
    local have = {}
    for slot, it in pairs(inv[i] or {}) do
      if PRODUCTS[it.name] then pulls[#pulls + 1] = { a, slot }
      else have[it.name] = (have[it.name] or 0) + it.count end
    end
    local p = active(have)
    if p == false then
      mixed = mixed + 1
    else
      p = p or pick(stock)
      local before = #moves
      if p then plan(a, p, have, stock, moves) end
      if #moves > before then fed = fed + 1 end
    end
  end

  jobs = {}
  for _, m in ipairs(pulls) do jobs[#jobs + 1] = function() pcall(peripheral.call, provider, "pullItems", m[1], m[2]) end end
  for _, m in ipairs(moves) do jobs[#jobs + 1] = function() pcall(peripheral.call, barrel, "pushItems", m[1], m[2], m[3]) end end
  run(jobs)
  return #asms, fed, #pulls, mixed
end

while true do
  local n, fed, pulled, mixed = round()
  term.clear()
  term.setCursorPos(1, 1)
  print(("crystal assemblers: %d"):format(n))
  print(("fed %d, emptied %d outputs"):format(fed, pulled))
  if mixed > 0 then print(("%d hold mixed prints: break and replace them"):format(mixed)) end
  sleep(0)
end
