"""Runs programs/SlicerFeeder.lua (the real file, via lupa) against simulated slicers.

    pip install lupa && python tools/test_slicer_feeder.py

Slicers: slot 1 insert-only input, slot 2 output; each round every one slices up to 2. Checks: the first
fill gives every slicer work and keeps each item within 1 across its slicers, nothing ever goes over Cap,
no pull lands on a full provider (9 return slots), and at the end every input is sliced and every print
reached the provider.
"""
import pathlib
import lupa

SCRIPT = (pathlib.Path(__file__).resolve().parent.parent / "programs" / "SlicerFeeder.lua").read_text(encoding="utf-8")

SIM = r"""
local CAP, ROUNDS = 32, 600
local P, products, rounds = {}, 0, 0
overfull = 0 -- pulls that hit a full provider (pcall in the script hides them, so count instead)
local function inv(t) return { type = t, slots = {} } end
P.barrel = inv("sophisticatedstorage:barrel")
P.provider = inv("ae2:pattern_provider")
for i = 1, 12 do P["slicer_" .. i] = inv("extendedae:circuit_cutter") end
P.slicer_1.slots[1] = { name = "gold_block", count = 5 } -- already busy when the feeder starts
P.barrel.slots = { { name = "gold_block", count = 300 }, { name = "silicon_block", count = 70 },
  { name = "gold_block", count = 200 }, { name = "diamond_block", count = 3 } }
local total = 5 + 300 + 70 + 200 + 3

local methods = {
  list = function(self)
    local out = {}
    for k, v in pairs(self.slots) do out[k] = { name = v.name, count = v.count } end
    return out
  end,
  pushItems = function(self, to, from, limit, toSlot)
    assert(toSlot == 1, "pushed into slot " .. tostring(toSlot))
    local s, d = self.slots[from], P[to].slots[1]
    if not s or (d and d.name ~= s.name) then return 0 end
    local k = math.min(limit, s.count, 64 - (d and d.count or 0))
    P[to].slots[1] = { name = s.name, count = (d and d.count or 0) + k }
    s.count = s.count - k
    if s.count == 0 then self.slots[from] = nil end
    return k
  end,
  size = function(self) return 9 end,
  pullItems = function(self, from, slot)  -- into the provider's 9 return slots, one stack per slot
    assert(slot ~= 1, "pulled from the insert-only input slot")
    local s = P[from].slots[slot]
    if not s then return 0 end
    if #self.slots >= 9 then overfull = overfull + 1 return 0 end -- fails silently in game, as here
    P[from].slots[slot] = nil
    self.slots[#self.slots + 1] = { name = s.name, count = s.count }
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

sleep = function()
  local lo, hi = {}, {}
  for name, m in pairs(P) do
    if m.type:find("circuit_cutter") then
      local s = m.slots[1]
      if s then
        assert(s.count <= CAP, name .. " over cap: " .. s.count)
        lo[s.name], hi[s.name] = math.min(lo[s.name] or s.count, s.count), math.max(hi[s.name] or 0, s.count)
      end
      if rounds == 0 then assert(s, name .. " left empty on the first fill") end
    end
  end
  if rounds == 0 then
    for item in pairs(lo) do assert(hi[item] - lo[item] <= 1, item .. " unbalanced: " .. lo[item] .. ".." .. hi[item]) end
  end
  rounds = rounds + 1
  for _, s in ipairs(P.provider.slots) do products = products + s.count end  -- AE empties it on its tick
  P.provider.slots = {}
  for _, m in pairs(P) do
    local s = m.type:find("circuit_cutter") and m.slots[1]
    if s then
      local k = math.min(2, s.count)
      s.count = s.count - k
      if s.count == 0 then m.slots[1] = nil end
      m.slots[2] = { name = "print", count = (m.slots[2] and m.slots[2].count or 0) + k }
    end
  end
  if rounds >= ROUNDS then error("done", 0) end
end

function result()
  local left = 0
  for _, m in pairs(P) do if m ~= P.provider then for _, s in pairs(m.slots) do left = left + s.count end end end
  return products, total, left
end
"""

lua = lupa.LuaRuntime(unpack_returned_tuples=True)
lua.execute(SIM)
try:
    lua.execute(SCRIPT)
except lupa.LuaError as e:
    if "done" not in str(e):
        raise
products, total, left = lua.globals().result()
assert lua.globals().overfull == 0, f"{lua.globals().overfull} pulls hit a full provider"
assert products == total and left == 0, f"sliced {products} of {total}, {left} left over"
print(f"ok: {products} sliced, every slicer busy from the first fill, balanced, never over cap")
