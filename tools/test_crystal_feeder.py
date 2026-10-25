"""Runs programs/CrystalFeeder.lua (the real file, via lupa) against simulated peripherals.

    pip install lupa && python tools/test_crystal_feeder.py

Assemblers: 9 insert-only input slots + slot 10 output; each round every one crafts up to 4 of whatever
whole set it holds. Checks after every round: no assembler holds two prints, no print is ahead of its
silicon or third ingredient, nothing over Cap; the first fill gives every assembler work, within one batch of 4 of the others on its recipe; every print count is a whole batch of 4. At the end every print is crafted and nothing is left over.
"""
import pathlib
import lupa

ROOT = pathlib.Path(__file__).resolve().parent.parent
SCRIPT = (ROOT / "programs" / "CrystalFeeder.lua").read_text(encoding="utf-8")

SIM = r"""
local CAP, N_ASM, ROUNDS = __CAP__, 10, 400
local REDSTONE, FLUIX, SIL = "minecraft:redstone", "ae2:fluix_dust", "ae2:printed_silicon"
local RECIPE = {
  ["ae2:printed_logic_processor"] = { REDSTONE, "ae2:logic_processor" },
  ["ae2:printed_calculation_processor"] = { REDSTONE, "ae2:calculation_processor" },
  ["megacells:printed_accumulation_processor"] = { FLUIX, "megacells:accumulation_processor" },
}
local P = {}   -- name -> { type, slots }
local products, rounds = 0, 0

local function inv(t, n) return { type = t, slots = {}, n = n } end
P.barrel = inv("sophisticatedstorage:barrel", 27)
P.provider = inv("ae2:pattern_provider", 0)
for i = 1, N_ASM do P["asm_" .. i] = inv("extendedae:crystal_assembler", 10) end
-- the barrel holds item stacks over 64 per slot (netherite upgrades); split some across slots on purpose
-- jobs come in whole batches of 4; asm_1 starts stuck at 3/3/3 (left there by an older feeder)
local seed = { { "ae2:printed_logic_processor", 297 }, { "ae2:printed_calculation_processor", 96 },
  { "megacells:printed_accumulation_processor", 52 }, { SIL, 200 }, { SIL, 245 },
  { REDSTONE, 393 }, { FLUIX, 52 } }
for i, s in ipairs(seed) do P.barrel.slots[i] = { name = s[1], count = s[2] } end
P.asm_1.slots = { { name = "ae2:printed_logic_processor", count = 3 }, { name = SIL, count = 3 },
  { name = REDSTONE, count = 3 } }
local total_prints = 300 + 96 + 52

local function insert(dst, name, n)  -- into input slots 1..9, 64 per stack
  local moved = 0
  for pass = 1, 2 do
    for slot = 1, 9 do
      local s = dst.slots[slot]
      if n > 0 and ((pass == 1 and s and s.name == name) or (pass == 2 and not s)) then
        local k = math.min(n, 64 - (s and s.count or 0))
        dst.slots[slot] = { name = name, count = (s and s.count or 0) + k }
        n, moved = n - k, moved + k
      end
    end
  end
  return moved
end

local methods = {
  list = function(self)
    local out = {}
    for k, v in pairs(self.slots) do out[k] = { name = v.name, count = v.count } end
    return out
  end,
  pushItems = function(self, to, from, limit)
    local s = self.slots[from]
    if not s then return 0 end
    local k = insert(P[to], s.name, math.min(limit or 64, s.count))
    s.count = s.count - k
    if s.count == 0 then self.slots[from] = nil end
    return k
  end,
  pullItems = function(self, from, slot)
    local src = P[from]
    assert(slot == 10, "pulled from an insert-only input slot " .. slot)
    local s = src.slots[slot]
    if not s then return 0 end
    src.slots[slot] = nil
    products = products + s.count
    return s.count
  end,
}

peripheral = {
  getNames = function() local t = {} for k in pairs(P) do t[#t + 1] = k end return t end,
  getType = function(n) return P[n] and P[n].type end,
  isPresent = function(n) return P[n] ~= nil end,
  call = function(n, m, ...) return methods[m](P[n], ...) end,
}
parallel = { waitForAll = function(...) for _, f in ipairs({ ... }) do f() end end }
term = { clear = function() end, setCursorPos = function() end }
print = function() end
dofile = function() return { Cap = tostring(CAP) } end

local function counts(a)
  local c = {}
  for slot = 1, 9 do local s = a.slots[slot] if s then c[s.name] = (c[s.name] or 0) + s.count end end
  return c
end

local function check()
  for name, a in pairs(P) do
    if a.type:find("crystal_assembler") then
      local c, print_ = counts(a), nil
      for item, n in pairs(c) do
        assert(n <= CAP, name .. " over cap: " .. item .. " " .. n)
        if RECIPE[item] then
          assert(n % 4 == 0, name .. " holds " .. n .. " " .. item .. ", not a whole batch of 4")
          assert(not print_, name .. " holds two prints: " .. tostring(print_) .. ", " .. item)
          print_ = item
          assert(n <= (c[SIL] or 0) and n <= (c[RECIPE[item][1]] or 0), name .. " print ahead of its partners")
        end
      end
    end
  end
end

local function craft(a)  -- exactly 4 crafts of the one recipe it holds, or nothing
  local c = counts(a)
  for p, r in pairs(RECIPE) do
    local n = 4
    if math.min(c[p] or 0, c[SIL] or 0, c[r[1]] or 0) >= n then
      for _, item in ipairs({ p, SIL, r[1] }) do
        local left = n
        for slot = 1, 9 do
          local s = a.slots[slot]
          if s and s.name == item and left > 0 then
            local k = math.min(left, s.count)
            s.count, left = s.count - k, left - k
            if s.count == 0 then a.slots[slot] = nil end
          end
        end
      end
      local out = a.slots[10]
      a.slots[10] = { name = r[2], count = (out and out.count or 0) + n }
    end
  end
end

sleep = function()
  check()
  if rounds == 0 then  -- load balance before saturating: every assembler gets work, even per recipe
    local lo, hi = {}, {}
    for name, a in pairs(P) do
      if a.type:find("crystal_assembler") then
        local c = counts(a)
        assert(next(c), name .. " left empty on the first fill")
        for p in pairs(RECIPE) do
          if c[p] then lo[p], hi[p] = math.min(lo[p] or c[p], c[p]), math.max(hi[p] or 0, c[p]) end
        end
      end
    end
    for p in pairs(lo) do assert(hi[p] - lo[p] <= 4, p .. " unbalanced: " .. lo[p] .. ".." .. hi[p]) end
  end
  rounds = rounds + 1
  for _, a in pairs(P) do if a.type:find("crystal_assembler") then craft(a) end end
  if rounds >= ROUNDS then error("done", 0) end
end

function result()
  local left = {}
  for _, s in pairs(P.barrel.slots) do left[#left + 1] = s.name .. " x" .. s.count end
  for name, a in pairs(P) do
    if a.type:find("crystal_assembler") then
      for slot, s in pairs(a.slots) do left[#left + 1] = name .. "[" .. slot .. "] " .. s.name .. " x" .. s.count end
    end
  end
  return products, total_prints, table.concat(left, ", ")
end
"""

for cap in (8, 64):
    lua = lupa.LuaRuntime(unpack_returned_tuples=True)
    lua.execute(SIM.replace("__CAP__", str(cap)))
    try:
        lua.execute(SCRIPT)
    except lupa.LuaError as e:
        if "done" not in str(e):
            raise
    products, total, left = lua.globals().result()
    assert products == total, f"Cap {cap}: crafted {products} of {total} processors; left: {left}"
    assert not left, f"Cap {cap}: left over: {left}"
    print(f"Cap {cap} ok: {products} crafted, spread over every assembler, never mixed, ahead or over cap")
